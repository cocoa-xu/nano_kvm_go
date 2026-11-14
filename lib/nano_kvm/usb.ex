defmodule NanoKVM.USB do
  @default_gadget "/sys/kernel/config/usb_gadget/nanokvm"

  @moduledoc """
  The USB functions the target computer sees.

  The NanoKVM-Go Nerves system sets up a USB gadget at boot with a network
  (NCM) and a serial (ACM) function. This process adds the KVM functions to
  it:

    * `:keyboard` - a boot keyboard, for `NanoKVM.HID`
    * `:mouse` - an absolute mouse, for `NanoKVM.HID`
    * `:storage` - a removable drive or CD-ROM drive, for `NanoKVM.Storage`

  Changing the functions disconnects the gadget and connects it again: the
  target computer sees the NanoKVM unplugged and plugged in, and the USB
  network goes down for a moment. With the functions already there nothing
  happens, so starting the process again is cheap.

      children = [{NanoKVM.USB, functions: [:keyboard, :mouse, :storage]}]

  ## Options

    * `:functions` - the functions to have, none by default
    * `:name` - the name to register, `NanoKVM.USB` by default
    * `:gadget` - the gadget's configfs directory, `#{@default_gadget}` by
      default
  """
  use GenServer
  require Logger

  alias NanoKVM.HID.Descriptor

  @config "configs/c.1"
  @udc_class "/sys/class/udc"
  @dirs %{keyboard: "hid.keyboard", mouse: "hid.mouse", storage: "mass_storage.disk"}
  # The order they are added in: the keyboard comes before the mouse.
  @order [:keyboard, :mouse, :storage]
  # SCSI INQUIRY: vendor (8), product (16), revision (4).
  @inquiry "NanoKVM Virtual Media   0100"

  @type function_name() :: :keyboard | :mouse | :storage

  @type option() ::
          {:functions, [function_name()]} | {:name, GenServer.name()} | {:gadget, Path.t()}

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
  @spec configure(GenServer.server(), [function_name()]) :: :ok | {:error, term()}
  def configure(server \\ __MODULE__, functions) when is_list(functions) do
    GenServer.call(server, {:configure, functions})
  end

  @doc """
  The KVM functions the gadget has.
  """
  @spec functions(GenServer.server()) :: [function_name()]
  def functions(server \\ __MODULE__), do: GenServer.call(server, :functions)

  @doc """
  The configfs directory of the gadget the NanoKVM-Go system sets up.
  """
  @spec default_gadget() :: Path.t()
  def default_gadget, do: @default_gadget

  @doc """
  The device of a HID function, such as `"/dev/hidg0"`.

  Takes the `:gadget` option.
  """
  @spec hid_device(:keyboard | :mouse, keyword()) :: {:ok, Path.t()} | {:error, term()}
  def hid_device(function, opts \\ []) when function in [:keyboard, :mouse] do
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
    gadget = Keyword.get(opts, :gadget, @default_gadget)
    # For tests: where the device controllers are listed.
    udc_class = Keyword.get(opts, :udc_class, @udc_class)
    state = %{gadget: gadget, udc_class: udc_class}

    case apply_functions(state, Keyword.get(opts, :functions, [])) do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:configure, functions}, _from, state) do
    {:reply, apply_functions(state, functions), state}
  end

  def handle_call(:functions, _from, state), do: {:reply, present(state.gadget), state}

  defp apply_functions(state, functions) do
    with :ok <- validate(functions),
         :ok <- check_gadget(state.gadget) do
      wanted = Enum.filter(@order, &(&1 in functions))
      present = present(state.gadget)

      if wanted == present,
        do: :ok,
        else: change(state, present, wanted)
    end
  end

  defp change(state, present, wanted) do
    Logger.info("nano_kvm: USB functions #{inspect(wanted)}, reconnecting the gadget")
    udc = bound_udc(state.gadget)

    with :ok <- unbind(state.gadget, udc),
         :ok <- each(present -- wanted, &remove(state.gadget, &1)),
         :ok <- each(wanted -- present, &add(state.gadget, &1)) do
      bind(state, udc)
    end
  end

  defp present(gadget) do
    Enum.filter(@order, fn function ->
      match?({:ok, _stat}, File.lstat(link(gadget, function)))
    end)
  end

  defp add(gadget, function) do
    dir = function_dir(function, gadget: gadget)

    with :ok <- File.mkdir_p(dir),
         :ok <- setup(dir, function) do
      File.ln_s(dir, link(gadget, function))
    end
  end

  defp setup(dir, :keyboard), do: setup_hid(dir, Descriptor.keyboard())
  defp setup(dir, :mouse), do: setup_hid(dir, Descriptor.mouse())

  # configfs makes lun.0 with the function; mkdir_p is for plain directories.
  defp setup(dir, :storage) do
    lun = Path.join(dir, "lun.0")

    with :ok <- File.mkdir_p(lun) do
      write_all(lun, removable: "1", cdrom: "0", ro: "0", nofua: "0", inquiry_string: @inquiry)
    end
  end

  defp setup_hid(dir, descriptor) do
    write_all(dir,
      protocol: Integer.to_string(descriptor.protocol),
      subclass: Integer.to_string(descriptor.subclass),
      report_length: Integer.to_string(descriptor.report_length),
      report_desc: descriptor.report_desc
    )
  end

  defp remove(gadget, function) do
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

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {item, reason}}}
      end
    end)
  end

  defp validate(functions) do
    case functions -- @order do
      [] -> :ok
      unknown -> {:error, {:unknown_functions, unknown}}
    end
  end

  defp check_gadget(gadget) do
    if File.dir?(gadget), do: :ok, else: {:error, {:no_gadget, gadget}}
  end
end
