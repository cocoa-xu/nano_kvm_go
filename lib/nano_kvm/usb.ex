defmodule NanoKVM.USB do
  @default_gadget "/sys/kernel/config/usb_gadget/nanokvm"

  @moduledoc """
  The USB functions the target computer sees.

  The NanoKVM-Go Nerves system sets up a USB gadget at boot with a network
  (NCM) function. This process adds the KVM functions to it:

    * `:keyboard` - a boot keyboard, for `NanoKVM.HID`
    * `:mouse` - an absolute pointer, for `NanoKVM.HID`; `{:mouse, mode:
      mode}` makes it an `:absolute` mouse (the default), a `:stylus` (a
      pen, for Android and iPadOS) or a `:touch` screen
    * `:relative_mouse` - a boot mouse that moves by steps, for
      `NanoKVM.HID`, which BIOS setups and games take
    * `:storage` - a removable drive or CD-ROM drive, for `NanoKVM.Storage`
    * `:microphone` - a microphone, for `NanoKVM.Microphone`
    * `:speaker` - a speaker, for `NanoKVM.Audio` with `source: :usb`

  The microphone and the speaker are the two directions of one USB Audio
  Class 2 function, which the NanoKVM-Go system shows as the ALSA card
  `UAC2Gadget`. Each takes its format as options, `{:microphone, options}`:

    * `:channels` - 1 (mono) to 8, 2 (stereo) by default
    * `:rates` - the sample rates the target computer can choose from, up to
      10, `[48_000]` by default. The target starts with the first and
      chooses (a Mac in Audio MIDI Setup, Windows in the device's
      properties); `NanoKVM.Microphone` and `NanoKVM.Audio` follow its
      choice.
    * `:sample_bits` - 16, 24 or 32, 16 by default

  The target's volume and mute controls act on the samples. The keyboard
  and mice may wake a target that sleeps, where it allows them. A format the
  USB controller cannot carry is refused: a packet each 125 µs at the
  most, of up to 832 bytes to the target and 682 from it. `audio/1` tells
  the formats the gadget has.

  Changing the functions disconnects the gadget and connects it again: the
  target computer sees the NanoKVM unplugged and plugged in, and the USB
  network goes down for a moment. With the functions already there nothing
  happens, so starting the process again is cheap.

  When the functions cannot be set up at start, the process logs the error
  and runs on, so that the rest of the application does not go down with
  it; `functions/1` tells what the gadget has. A change the USB controller
  refuses (it has seven endpoints for data to the computer: the network
  takes two, the audio two and each other function one) leaves the
  functions as they were.

      children = [
        {NanoKVM.USB,
         functions: [:keyboard, :mouse, {:microphone, channels: 1, rates: [44_100, 48_000]}]}
      ]

  ## The network

  The network function has two MAC addresses: the NanoKVM's, of its
  interface `usb0`, and the target computer's, of the network adapter the
  computer sees. The NanoKVM-Go system gives it the same ones at each boot,
  so that the computer keeps one network interface for the NanoKVM: those
  in the U-Boot environment's `usbnet_devaddr` and `usbnet_hostaddr`, else
  addresses made from the serial number (`default_network_addresses/1`).
  `network/1` tells them; `set_network_addresses/2` changes them at once
  and keeps them for the next boots.

  ## Options

    * `:functions` - the functions to have, none by default
    * `:name` - the name to register, `NanoKVM.USB` by default
    * `:gadget` - the gadget's configfs directory, `#{@default_gadget}` by
      default
  """
  use GenServer
  require Logger
  import Bitwise

  alias NanoKVM.HID.Descriptor

  @config "configs/c.1"
  @udc_class "/sys/class/udc"
  @dirs %{
    keyboard: "hid.keyboard",
    mouse: "hid.mouse",
    relative_mouse: "hid.relative_mouse",
    storage: "mass_storage.disk",
    microphone: "uac2.audio",
    speaker: "uac2.audio"
  }
  # The order they are added in: the keyboard comes before the mouse.
  @order [:keyboard, :mouse, :relative_mouse, :storage, :microphone, :speaker]
  @audio [:microphone, :speaker]
  # SCSI INQUIRY: vendor (8), product (16), revision (4).
  @inquiry "NanoKVM Virtual Media   0100"
  # The configfs attributes of the audio directions start with these.
  @prefix %{microphone: "p_", speaker: "c_"}
  # Channel positions: front left and right, center, LFE, back, side.
  @channel_masks %{
    1 => 0x1,
    2 => 0x3,
    3 => 0x7,
    4 => 0x33,
    5 => 0x37,
    6 => 0x3F,
    7 => 0x13F,
    8 => 0x63F
  }
  @max_rates 10
  # The device controller's states and speeds in sysfs (usb_state_string,
  # usb_speed_string).
  @states %{
    "not attached" => :not_attached,
    "attached" => :attached,
    "powered" => :powered,
    "reconnecting" => :reconnecting,
    "unauthenticated" => :unauthenticated,
    "default" => :default,
    "addressed" => :addressed,
    "configured" => :configured,
    "suspended" => :suspended
  }
  @speeds %{
    "low-speed" => :low_speed,
    "full-speed" => :full_speed,
    "high-speed" => :high_speed,
    "super-speed" => :super_speed,
    "super-speed-plus" => :super_speed_plus,
    "UNKNOWN" => :unknown
  }
  # The largest packets the USB controller (DWC3) takes: its smallest
  # transmit FIFO holds 832 bytes of one, and the receive FIFO three of 682.
  @max_packet %{microphone: 832, speaker: 682}
  # The network function the NanoKVM-Go system sets up, and the U-Boot
  # variables it takes the addresses from at boot (U-Boot's own names).
  @ncm "ncm.usb0"
  @address_variables %{device_address: "usbnet_devaddr", host_address: "usbnet_hostaddr"}
  # The network function's settings that a new one takes over.
  @ncm_kept [:qmult, :max_segment_size]

  @type function_name() ::
          :keyboard | :mouse | :relative_mouse | :storage | :microphone | :speaker

  @type audio_option() ::
          {:channels, 1..8} | {:rates, [pos_integer()]} | {:sample_bits, 16 | 24 | 32}

  @type function_spec() ::
          function_name()
          | {:microphone | :speaker, [audio_option()]}
          | {:mouse, [mode: NanoKVM.HID.pointer_mode()]}

  @typedoc "The state of the USB connection, see `connection/1`."
  @type connection_state() ::
          :not_attached
          | :attached
          | :powered
          | :reconnecting
          | :unauthenticated
          | :default
          | :addressed
          | :configured
          | :suspended
          | :unknown

  @type speed() ::
          :low_speed | :full_speed | :high_speed | :super_speed | :super_speed_plus | :unknown

  @type audio_format() :: %{
          channels: 1..8,
          rates: [pos_integer(), ...],
          sample_bits: 16 | 24 | 32
        }

  @typedoc "A MAC address, such as `\"02:12:34:56:78:9a\"`."
  @type mac_address() :: String.t()

  @type network_addresses() :: %{device_address: mac_address(), host_address: mac_address()}

  @typedoc "The USB network, see `network/1`."
  @type network() :: %{
          interface: String.t() | nil,
          device_address: mac_address(),
          host_address: mac_address(),
          default_addresses: network_addresses() | nil
        }

  @typedoc "What `set_network_addresses/2` takes."
  @type network_setting() ::
          {:device_address, mac_address() | :default}
          | {:host_address, mac_address() | :default}
          | {:persist, boolean()}

  @type option() ::
          {:functions, [function_spec()]} | {:name, GenServer.name()} | {:gadget, Path.t()}

  @doc """
  Starts the process and sets up the functions. See the module documentation
  for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sets up these functions and removes the other KVM functions.
  """
  @spec configure(GenServer.server(), [function_spec()]) :: :ok | {:error, term()}
  def configure(server \\ __MODULE__, functions) when is_list(functions) do
    GenServer.call(server, {:configure, functions})
  end

  @doc """
  Checks functions without setting them up: whether `configure/2` would
  take them.

      iex> NanoKVM.USB.validate([:keyboard, {:microphone, channels: 1, rates: [44_100]}])
      :ok
      iex> NanoKVM.USB.validate([{:speaker, sample_bits: 20}])
      {:error, {:invalid_sample_bits, :speaker, 20}}
  """
  @spec validate([function_spec()]) :: :ok | {:error, term()}
  def validate(functions) when is_list(functions) do
    with {:ok, _normalized} <- normalize(functions), do: :ok
  end

  @doc """
  The KVM functions the gadget has.
  """
  @spec functions(GenServer.server()) :: [function_name()]
  def functions(server \\ __MODULE__), do: GenServer.call(server, :functions)

  @doc """
  The formats of the audio directions the gadget has, such as
  `%{microphone: %{channels: 2, rates: [48_000], sample_bits: 16}}`.
  """
  @spec audio(GenServer.server()) :: %{optional(:microphone | :speaker) => audio_format()}
  def audio(server \\ __MODULE__), do: GenServer.call(server, :audio)

  @doc """
  The USB connection to the target computer: the state the target has put
  the NanoKVM in, the speed, and the device controller.

    * `:configured` - the target uses the functions
    * `:suspended` - the target sleeps, or has suspended the port
    * `:not_attached` - no computer at the other end of the cable
    * `:attached`, `:powered`, `:default`, `:addressed` - on the way to
      `:configured`

  ```
  NanoKVM.USB.connection()
  #=> {:ok, %{state: :configured, speed: :high_speed, controller: "8000000.usb"}}
  ```

  The speed is `:low_speed`, `:full_speed`, `:high_speed`, `:super_speed`
  or `:unknown`. Without a controller bound to the gadget the result is
  `{:error, :no_udc}`. Takes the `:gadget` option.
  """
  @spec connection(keyword()) ::
          {:ok, %{state: connection_state(), speed: speed(), controller: String.t()}}
          | {:error, term()}
  def connection(opts \\ []) do
    udc_class = Keyword.get(opts, :udc_class, @udc_class)

    with udc when udc != "" <- bound_udc(Keyword.get(opts, :gadget, @default_gadget)),
         dir = Path.join(udc_class, udc),
         {:ok, state} <- File.read(Path.join(dir, "state")) do
      speed =
        case File.read(Path.join(dir, "current_speed")) do
          {:ok, speed} -> Map.get(@speeds, String.trim(speed), :unknown)
          {:error, _reason} -> :unknown
        end

      {:ok,
       %{state: Map.get(@states, String.trim(state), :unknown), speed: speed, controller: udc}}
    else
      "" -> {:error, :no_udc}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The USB network: the NanoKVM's interface and its address, the address of
  the target computer's end, and the addresses both have by default.

  ```
  NanoKVM.USB.network()
  #=> {:ok,
  #=>  %{
  #=>    interface: "usb0",
  #=>    device_address: "ea:52:ab:b6:67:a7",
  #=>    host_address: "02:12:34:56:78:9a",
  #=>    default_addresses: %{device_address: "ea:52:ab:b6:67:a7", host_address: "2e:53:95:27:a5:9d"}
  #=>  }}
  ```

  The interface is `nil` before the gadget is first bound, and the default
  addresses `nil` without a serial number.
  """
  @spec network(GenServer.server()) :: {:ok, network()} | {:error, term()}
  def network(server \\ __MODULE__), do: GenServer.call(server, :network)

  @doc """
  Gives the USB network other addresses, MAC addresses or `:default`:

    * `:device_address` - the NanoKVM's
    * `:host_address` - the target computer's

  One left out stays as it is. The gadget connects again, as when the
  functions change, and the NanoKVM's interface goes away and comes back
  with its address. The NanoKVM-Go system gives the network the same
  addresses at the next boots, from the U-Boot environment
  (`Nerves.Runtime.KV`), unless `persist: false`.

  ```
  NanoKVM.USB.set_network_addresses(host_address: "02:12:34:56:78:9a")
  NanoKVM.USB.set_network_addresses(device_address: :default, host_address: :default)
  ```

  Refused: an address that is not one (`{:invalid_address, key, value}`)
  or is a multicast address (`{:multicast_address, key, value}`), and the
  same address at both ends (`:same_addresses`).
  """
  @spec set_network_addresses(GenServer.server(), [network_setting()]) :: :ok | {:error, term()}
  def set_network_addresses(server \\ __MODULE__, settings) when is_list(settings) do
    GenServer.call(server, {:set_network_addresses, settings}, 15_000)
  end

  @doc """
  Checks addresses without setting them: whether `set_network_addresses/2`
  would take them.
  """
  @spec validate_network_addresses(GenServer.server(), [network_setting()]) ::
          :ok | {:error, term()}
  def validate_network_addresses(server \\ __MODULE__, settings) when is_list(settings) do
    GenServer.call(server, {:validate_network_addresses, settings})
  end

  @doc """
  The addresses the NanoKVM-Go system gives the USB network when the U-Boot
  environment has none: the first six bytes of the SHA-256 of the serial
  number (`boardid`'s) for the NanoKVM's end and the next six for the
  computer's, as locally administered unicast addresses.

      iex> NanoKVM.USB.default_network_addresses("6a1a78455040f186")
      %{device_address: "ea:52:ab:b6:67:a7", host_address: "2e:53:95:27:a5:9d"}
  """
  @spec default_network_addresses(String.t()) :: network_addresses()
  def default_network_addresses(serial_number) when is_binary(serial_number) do
    <<device::binary-6, host::binary-6, _rest::binary>> = :crypto.hash(:sha256, serial_number)
    %{device_address: local_address(device), host_address: local_address(host)}
  end

  defp local_address(<<first, rest::binary-5>>),
    do: format_address(<<(first &&& 0xFC) ||| 0x02, rest::binary>>)

  @doc """
  The configfs directory of the gadget the NanoKVM-Go system sets up.
  """
  @spec default_gadget() :: Path.t()
  def default_gadget, do: @default_gadget

  @doc """
  The device of a HID function, such as `"/dev/hidg0"`.

  Takes the `:gadget` option.
  """
  @spec hid_device(:keyboard | :mouse | :relative_mouse, keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def hid_device(function, opts \\ []) when function in [:keyboard, :mouse, :relative_mouse] do
    dev = Path.join(function_dir(function, opts), "dev")

    with {:ok, text} <- File.read(dev),
         [major, minor] <- text |> String.trim() |> String.split(":"),
         {:ok, uevent} <- File.read("/sys/dev/char/#{major}:#{minor}/uevent"),
         [_line, name] <- Regex.run(~r/^DEVNAME=(.+)$/m, uevent) do
      {:ok, "/dev/" <> name}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_device}
    end
  end

  @doc false
  @spec function_dir(function_name(), keyword()) :: Path.t()
  def function_dir(function, opts) do
    Path.join([Keyword.get(opts, :gadget, @default_gadget), "functions", @dirs[function]])
  end

  @impl GenServer
  def init(opts) do
    functions = Keyword.get(opts, :functions, [])

    with {:error, reason} <- normalize(functions) do
      raise ArgumentError, "invalid USB functions: #{inspect(reason)}"
    end

    serial_number = Keyword.get_lazy(opts, :serial_number, &serial_number/0)

    state = %{
      gadget: Keyword.get(opts, :gadget, @default_gadget),
      default_addresses: serial_number && default_network_addresses(serial_number),
      # For tests: where the device controllers are listed, where the
      # addresses are kept, and how a function goes (configfs takes its
      # attributes with it, a plain directory does not).
      udc_class: Keyword.get(opts, :udc_class, @udc_class),
      kv: Keyword.get(opts, :kv, Nerves.Runtime.KV),
      rmdir: Keyword.get(opts, :rmdir, &File.rmdir/1)
    }

    with {:error, reason} <- apply_functions(state, functions) do
      Logger.error("nano_kvm: USB functions #{inspect(functions)} not set up: #{inspect(reason)}")
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:configure, functions}, _from, state) do
    {:reply, apply_functions(state, functions), state}
  end

  def handle_call(:functions, _from, state) do
    {:reply, Enum.map(present(state.gadget), &name/1), state}
  end

  def handle_call(:audio, _from, state) do
    present = present(state.gadget)

    {:reply,
     for(
       {function, format} when function in @audio <- present,
       into: %{},
       do: {function, format}
     ), state}
  end

  def handle_call(:network, _from, state), do: {:reply, read_network(state), state}

  def handle_call({:validate_network_addresses, settings}, _from, state) do
    reply =
      with {:ok, network} <- read_network(state),
           {:ok, _wanted} <- wanted_addresses(settings, network),
           do: :ok

    {:reply, reply, state}
  end

  def handle_call({:set_network_addresses, settings}, _from, state) do
    reply =
      with {:ok, network} <- read_network(state),
           {:ok, wanted} <- wanted_addresses(settings, network),
           :ok <- readdress(state, Map.take(network, [:device_address, :host_address]), wanted) do
        if Keyword.get(settings, :persist, true), do: persist(state, settings, wanted), else: :ok
      end

    {:reply, reply, state}
  end

  # The serial number the NanoKVM-Go system makes the default addresses
  # from, as its shell takes it: without the newlines at the end.
  defp serial_number do
    with {id, 0} <- System.cmd("boardid", []),
         id when id != "" <- String.trim_trailing(id, "\n") do
      id
    else
      _ -> nil
    end
  rescue
    # No boardid: not a Nerves device.
    ErlangError -> nil
  end

  defp read_network(state) do
    dir = Path.join([state.gadget, "functions", @ncm])

    with :ok <- check_gadget(state.gadget),
         {:ok, device} <- read_address(dir, "dev_addr"),
         {:ok, host} <- read_address(dir, "host_addr") do
      {:ok,
       %{
         interface: read_interface(dir),
         device_address: device,
         host_address: host,
         default_addresses: state.default_addresses
       }}
    end
  end

  # configfs shows an address with a NUL and a newline after it.
  defp read_address(dir, attribute) do
    with {:ok, text} <- File.read(Path.join(dir, attribute)),
         {:ok, bytes} <- parse_address(String.replace(text, ["\0", "\n"], "")) do
      {:ok, format_address(bytes)}
    else
      _ -> {:error, {:no_network_address, attribute}}
    end
  end

  # An interface not registered yet is "(unnamed net_device)".
  defp read_interface(dir) do
    case File.read(Path.join(dir, "ifname")) do
      {:ok, "(" <> _unnamed} -> nil
      {:ok, name} -> String.trim(name)
      {:error, _reason} -> nil
    end
  end

  # The addresses asked for, those left out as they are.
  defp wanted_addresses(settings, network) do
    with :ok <- check_network_settings(settings),
         {:ok, device} <- wanted_address(:device_address, settings, network),
         {:ok, host} <- wanted_address(:host_address, settings, network) do
      if device == host,
        do: {:error, :same_addresses},
        else: {:ok, %{device_address: device, host_address: host}}
    end
  end

  defp check_network_settings(settings) do
    cond do
      not Keyword.keyword?(settings) ->
        {:error, {:invalid_settings, settings}}

      (unknown = Keyword.keys(settings) -- [:device_address, :host_address, :persist]) != [] ->
        {:error, {:unknown_options, unknown}}

      Keyword.get(settings, :persist, true) not in [true, false] ->
        {:error, {:invalid_persist, settings[:persist]}}

      true ->
        :ok
    end
  end

  defp wanted_address(key, settings, network) do
    case Keyword.fetch(settings, key) do
      :error -> {:ok, network[key]}
      {:ok, :default} -> default_address(key, network.default_addresses)
      {:ok, text} -> unicast_address(key, text)
    end
  end

  defp default_address(_key, nil), do: {:error, :no_default_addresses}
  defp default_address(key, defaults), do: {:ok, defaults[key]}

  defp unicast_address(key, text) do
    case parse_address(text) do
      {:ok, <<first, _rest::binary>>} when (first &&& 1) == 1 ->
        {:error, {:multicast_address, key, text}}

      {:ok, <<0::48>>} ->
        {:error, {:invalid_address, key, text}}

      {:ok, bytes} ->
        {:ok, format_address(bytes)}

      :error ->
        {:error, {:invalid_address, key, text}}
    end
  end

  # Six bytes with colons or hyphens between them, in either case.
  defp parse_address(text) when is_binary(text) do
    with [_, _, _, _, _, _] = parts <- String.split(text, [":", "-"]),
         true <- Enum.all?(parts, &(byte_size(&1) == 2)),
         {:ok, bytes} <- Base.decode16(Enum.join(parts), case: :mixed) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp parse_address(_other), do: :error

  defp format_address(bytes) do
    Enum.map_join(:binary.bin_to_list(bytes), ":", &Base.encode16(<<&1>>, case: :lower))
  end

  defp readdress(_state, same, same), do: :ok

  defp readdress(state, current, wanted) do
    Logger.info("nano_kvm: USB network addresses #{inspect(wanted)}, reconnecting the gadget")
    gadget = state.gadget
    udc = bound_udc(gadget)
    links = links(gadget)

    result =
      with :ok <- unbind(gadget, udc),
           :ok <- each(links, &unlink(gadget, &1)) do
        write_addresses(state, current, wanted)
      end

    # The functions go back in their order and the gadget connects again,
    # also when the addresses did not take.
    with :ok <- each(links, &relink(gadget, &1)),
         :ok <- bind(state, udc),
         do: result
  end

  # The configuration's functions, in the order to link them again: the
  # network first, as the NanoKVM-Go system has it, then the KVM functions
  # and any others.
  defp links(gadget) do
    config = Path.join(gadget, @config)
    order = Enum.uniq([@ncm | Enum.map(@order, &@dirs[&1])])

    case File.ls(config) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&link_target(config, &1))
        |> Enum.sort_by(fn {name, _function} ->
          Enum.find_index(order, &(&1 == name)) || length(order)
        end)

      {:error, _reason} ->
        []
    end
  end

  # The kernel takes a relative target from the caller's directory.
  defp link_target(config, name) do
    case File.read_link(Path.join(config, name)) do
      {:ok, function} -> [{name, Path.expand(function, config)}]
      {:error, _not_a_link} -> []
    end
  end

  defp unlink(gadget, {name, _function}), do: File.rm(Path.join([gadget, @config, name]))

  defp relink(gadget, {name, function}) do
    case File.ln_s(function, Path.join([gadget, @config, name])) do
      {:error, :eexist} -> :ok
      result -> result
    end
  end

  # The NanoKVM's address is that of its interface, which the function makes
  # when it is first bound: another address takes a new function. The
  # computer's is read when the function is linked.
  defp write_addresses(state, current, wanted) do
    dir = Path.join([state.gadget, "functions", @ncm])

    if wanted.device_address == current.device_address do
      write_all(dir, host_addr: wanted.host_address)
    else
      kept =
        for name <- @ncm_kept,
            {:ok, value} <- [File.read(Path.join(dir, Atom.to_string(name)))],
            do: {name, String.trim(value)}

      with :ok <- state.rmdir.(dir),
           :ok <- File.mkdir(dir),
           :ok <- write_all(dir, kept) do
        write_all(dir, dev_addr: wanted.device_address, host_addr: wanted.host_address)
      end
    end
  end

  # The NanoKVM-Go system reads them at boot; empty is the default.
  defp persist(state, settings, wanted) do
    variables =
      for {key, variable} <- @address_variables, Keyword.has_key?(settings, key), into: %{} do
        {variable, if(settings[key] == :default, do: "", else: wanted[key])}
      end

    cond do
      variables == %{} ->
        :ok

      Code.ensure_loaded?(state.kv) ->
        with {:error, reason} <- state.kv.put(variables), do: {:error, {:not_kept, reason}}

      true ->
        {:error, {:not_kept, {:undefined, state.kv}}}
    end
  end

  defp apply_functions(state, functions) do
    with {:ok, wanted} <- normalize(functions),
         :ok <- check_gadget(state.gadget) do
      present = present(state.gadget)

      if wanted == present,
        do: :ok,
        else: change(state, present, wanted)
    end
  end

  defp change(state, present, wanted) do
    Logger.info("nano_kvm: USB functions #{inspect(wanted)}, reconnecting the gadget")
    udc = bound_udc(state.gadget)

    with {:error, reason} <- switch(state, udc, units(present), units(wanted)) do
      Logger.error("nano_kvm: USB functions #{inspect(wanted)} refused: #{inspect(reason)}")
      _ = switch(state, udc, units(present(state.gadget)), units(present))
      {:error, reason}
    end
  end

  defp switch(state, udc, from, to) do
    with :ok <- unbind(state.gadget, bound_udc(state.gadget)),
         :ok <- each(from -- to, &remove(state.gadget, &1)),
         :ok <- each(to -- from, &add(state.gadget, &1)),
         # Bus powered, and the keyboard and mice may wake the target.
         :ok <- write_existing(Path.join(state.gadget, @config), bmAttributes: "0xa0") do
      bind(state, udc)
    end
  end

  # The function directories: the microphone and the speaker share one, set
  # up for the directions and formats asked for. configfs only takes new
  # settings for a function that is not in use, so others mean a new
  # function.
  defp units(functions) do
    case for(
           {function, format} when function in @audio <- functions,
           into: %{},
           do: {function, format}
         ) do
      audio when audio == %{} -> functions
      audio -> Enum.reject(functions, &(name(&1) in @audio)) ++ [{:audio, audio}]
    end
  end

  # The functions in @order, the audio directions with their formats.
  defp present(gadget) do
    Enum.flat_map(@order, fn
      function when function in @audio ->
        case audio_direction(gadget, function) do
          {:ok, format} -> [{function, format}]
          :error -> []
        end

      function ->
        if match?({:ok, _stat}, File.lstat(link(gadget, function))),
          do: [with_options(gadget, function)],
          else: []
    end)
  end

  # The mouse's mode is in its report descriptor.
  defp with_options(gadget, :mouse) do
    path = Path.join(function_dir(:mouse, gadget: gadget), "report_desc")

    with {:ok, report_desc} <- File.read(path),
         mode when mode != nil <- Descriptor.pointer_mode(report_desc) do
      {:mouse, %{mode: mode}}
    else
      _ -> {:mouse, %{mode: nil}}
    end
  end

  defp with_options(_gadget, function), do: function

  defp audio_direction(gadget, function) do
    dir = function_dir(function, gadget: gadget)
    read = fn attribute -> File.read(Path.join(dir, @prefix[function] <> attribute)) end

    with {:ok, _stat} <- File.lstat(link(gadget, function)),
         {:ok, mask} <- read.("chmask"),
         {mask, _rest} when mask > 0 <- Integer.parse(mask),
         {:ok, rates} <- read.("srate"),
         {:ok, ssize} <- read.("ssize"),
         {ssize, _rest} <- Integer.parse(ssize) do
      rates = rates |> String.split([",", "\n"], trim: true) |> Enum.map(&String.to_integer/1)
      {:ok, %{channels: popcount(mask), rates: rates, sample_bits: ssize * 8}}
    else
      _ -> :error
    end
  end

  defp popcount(0), do: 0
  defp popcount(n), do: (n &&& 1) + popcount(n >>> 1)

  defp name({function, _format}), do: function
  defp name(function), do: function

  defp add(gadget, unit) do
    dir = function_dir(unit_function(unit), gadget: gadget)

    with :ok <- File.mkdir_p(dir),
         :ok <- setup(dir, unit) do
      File.ln_s(dir, link(gadget, unit_function(unit)))
    end
  end

  defp unit_function({:audio, audio}), do: if(audio[:microphone], do: :microphone, else: :speaker)
  defp unit_function({function, _options}), do: function
  defp unit_function(function), do: function

  defp setup(dir, :keyboard), do: setup_hid(dir, Descriptor.keyboard())
  defp setup(dir, {:mouse, %{mode: mode}}), do: setup_hid(dir, Descriptor.mouse(mode))
  defp setup(dir, :relative_mouse), do: setup_hid(dir, Descriptor.relative_mouse())

  # configfs makes lun.0 with the function; mkdir_p is for plain directories.
  defp setup(dir, :storage) do
    lun = Path.join(dir, "lun.0")

    with :ok <- File.mkdir_p(lun) do
      write_all(lun, removable: "1", cdrom: "0", ro: "0", nofua: "0", inquiry_string: @inquiry)
    end
  end

  defp setup(dir, {:audio, audio}) do
    with :ok <- write_all(dir, direction(:microphone, audio[:microphone])),
         :ok <- write_all(dir, direction(:speaker, audio[:speaker])),
         # No feedback endpoint: the speaker follows the computer's clock.
         :ok <- write_all(dir, c_sync: "adaptive") do
      # Where the kernel takes them: the names the computer shows, and no
      # interrupt endpoint, which the controls do without and the
      # functions need.
      write_existing(dir,
        int_ep_present: "0",
        function_name: "NanoKVM-Go Audio",
        c_alt0_name: "NanoKVM-Go Speaker",
        c_alt1_name: "NanoKVM-Go Speaker",
        p_alt0_name: "NanoKVM-Go Microphone",
        p_alt1_name: "NanoKVM-Go Microphone"
      )
    end
  end

  # A direction left out has no channels.
  defp direction(function, nil), do: [{attribute(function, "chmask"), "0"}]

  defp direction(function, format) do
    [
      {attribute(function, "chmask"), Integer.to_string(@channel_masks[format.channels])},
      {attribute(function, "srate"), Enum.map_join(format.rates, ",", &Integer.to_string/1)},
      {attribute(function, "ssize"), Integer.to_string(div(format.sample_bits, 8))},
      {attribute(function, "hs_bint"), Integer.to_string(interval(function, format))}
    ]
  end

  defp attribute(function, name), do: String.to_atom(@prefix[function] <> name)

  # No OUT endpoints, as with the stock firmware: the keyboard's LEDs come
  # through the control endpoint, and the functions need the endpoints.
  defp setup_hid(dir, descriptor) do
    with :ok <-
           write_all(dir,
             protocol: Integer.to_string(descriptor.protocol),
             subclass: Integer.to_string(descriptor.subclass),
             report_length: Integer.to_string(descriptor.report_length),
             report_desc: descriptor.report_desc
           ) do
      write_existing(dir, no_out_endpoint: "1")
    end
  end

  defp remove(gadget, unit) do
    function = unit_function(unit)

    with :ok <- File.rm(link(gadget, function)) do
      File.rmdir(function_dir(function, gadget: gadget))
    end
  end

  defp link(gadget, function), do: Path.join([gadget, @config, @dirs[function]])

  defp bound_udc(gadget) do
    case File.read(Path.join(gadget, "UDC")) do
      {:ok, name} -> String.trim(name)
      {:error, _reason} -> ""
    end
  end

  defp unbind(_gadget, ""), do: :ok
  defp unbind(gadget, _udc), do: File.write(Path.join(gadget, "UDC"), "\n")

  defp bind(state, "") do
    case File.ls(state.udc_class) do
      {:ok, [udc | _others]} -> bind(state, udc)
      _ -> {:error, :no_udc}
    end
  end

  defp bind(state, udc), do: File.write(Path.join(state.gadget, "UDC"), udc)

  defp write_all(dir, attributes) do
    each(attributes, fn {name, value} ->
      File.write(Path.join(dir, Atom.to_string(name)), value)
    end)
  end

  defp write_existing(dir, attributes) do
    attributes
    |> Enum.filter(fn {name, _value} -> File.exists?(Path.join(dir, Atom.to_string(name))) end)
    |> then(&write_all(dir, &1))
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {item, reason}}}
      end
    end)
  end

  # The functions asked for in @order, the audio directions with their
  # formats.
  defp normalize(specs) do
    with {:ok, entries} <- collect(specs, &entry/1),
         :ok <- unique(Enum.map(entries, &name/1)) do
      {:ok, Enum.sort_by(entries, &Enum.find_index(@order, fn f -> f == name(&1) end))}
    end
  end

  defp entry(function) when function in [:mouse | @audio], do: entry({function, []})
  defp entry(function) when function in @order, do: {:ok, function}

  defp entry({:mouse, opts}) when is_list(opts) do
    case Keyword.pop(opts, :mode, :absolute) do
      {mode, []} when mode in [:absolute, :stylus, :touch] -> {:ok, {:mouse, %{mode: mode}}}
      {mode, []} -> {:error, {:invalid_mode, :mouse, mode}}
      {_mode, rest} -> {:error, {:unknown_options, :mouse, Keyword.keys(rest)}}
    end
  end

  defp entry({function, opts}) when function in @audio and is_list(opts) do
    with {:ok, format} <- audio_format(function, opts), do: {:ok, {function, format}}
  end

  defp entry(other), do: {:error, {:unknown_function, other}}

  defp unique(names) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [function | _rest] -> {:error, {:duplicate_function, function}}
    end
  end

  defp audio_format(function, opts) do
    format = %{
      channels: Keyword.get(opts, :channels, 2),
      rates: opts |> Keyword.get(:rates, [48_000]) |> uniq_rates(),
      sample_bits: Keyword.get(opts, :sample_bits, 16)
    }

    cond do
      Keyword.keys(opts) -- [:channels, :rates, :sample_bits] != [] ->
        {:error, {:unknown_options, function, Keyword.keys(opts)}}

      not Map.has_key?(@channel_masks, format.channels) ->
        {:error, {:invalid_channels, function, format.channels}}

      not valid_rates?(format.rates) ->
        {:error, {:invalid_rates, function, Keyword.get(opts, :rates)}}

      format.sample_bits not in [16, 24, 32] ->
        {:error, {:invalid_sample_bits, function, format.sample_bits}}

      interval(function, format) == nil ->
        {:error, {:too_much_bandwidth, function, format}}

      true ->
        {:ok, format}
    end
  end

  defp uniq_rates(rates) when is_list(rates), do: Enum.uniq(rates)
  defp uniq_rates(rates), do: rates

  defp valid_rates?(rates) do
    is_list(rates) and length(rates) in 1..@max_rates and
      Enum.all?(rates, &(is_integer(&1) and &1 in 8_000..384_000))
  end

  # High speed sends a packet each 125 µs × 2^(interval - 1): the longest
  # interval whose packets the controller takes, nil for none.
  defp interval(function, format) do
    Enum.find(4..1//-1, &(packet(function, format, &1) <= @max_packet[function]))
  end

  # The bytes of a packet, as f_uac2 reckons them: the microphone may run
  # 0.5 % fast, and the speaker's packets have room for a frame more.
  defp packet(function, format, interval) do
    frame = format.channels * div(format.sample_bits, 8)
    per_second = div(8000, 1 <<< (interval - 1))
    rate = Enum.max(format.rates)

    case function do
      :microphone -> frame * ceil_div(div(rate * 1005, 1000), per_second)
      :speaker -> frame * (ceil_div(rate, per_second) + 1)
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp check_gadget(gadget) do
    if File.dir?(gadget), do: :ok, else: {:error, {:no_gadget, gadget}}
  end
end
