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

    state = %{
      gadget: Keyword.get(opts, :gadget, @default_gadget),
      # For tests: where the device controllers are listed.
      udc_class: Keyword.get(opts, :udc_class, @udc_class)
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
