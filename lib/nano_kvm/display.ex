defmodule NanoKVM.Display do
  @moduledoc """
  The NanoKVM-Go's LCD: 240 × 284 pixels in portrait, through the Linux
  framebuffer of its panel, and the panel's backlight.

      alias NanoKVM.Display.Canvas

      {:ok, %{width: width, height: height}} = NanoKVM.Display.info()

      Canvas.new(width, height, Canvas.rgb(0, 0, 0))
      |> Canvas.text(8, 8, "Hello", Canvas.rgb(255, 255, 255), scale: 2)
      |> NanoKVM.Display.show()

      NanoKVM.Display.backlight(false)

  The kernel sends what changed to the panel. Without the framebuffer (no
  panel, or a system without the driver) the calls return an error.

  ## Options

    * `:name` - the name to register, `NanoKVM.Display` by default
    * `:framebuffer` - the framebuffer's sysfs directory, by default the one
      of the panel's driver (`panel-mipi-dbi`)
    * `:backlight` - the backlight's sysfs directory,
      `/sys/class/backlight/backlight` by default
  """
  use GenServer

  alias NanoKVM.Display.Canvas

  @graphics "/sys/class/graphics"

  @type info() :: %{width: pos_integer(), height: pos_integer(), stride: pos_integer()}

  @type option() ::
          {:name, GenServer.name()} | {:framebuffer, Path.t()} | {:backlight, Path.t()}

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The size of the display in pixels, and of a row in bytes.
  """
  @spec info(GenServer.server()) :: {:ok, info()} | {:error, term()}
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  Shows a picture: a `NanoKVM.Display.Canvas` the size of the display, or
  rows of little-endian RGB565 pixels.
  """
  @spec show(GenServer.server(), Canvas.t() | binary()) :: :ok | {:error, term()}
  def show(server \\ __MODULE__, picture)

  def show(server, %Canvas{} = canvas), do: show(server, Canvas.render(canvas))
  def show(server, pixels) when is_binary(pixels), do: GenServer.call(server, {:show, pixels})

  @doc """
  Turns the backlight on or off.
  """
  @spec backlight(GenServer.server(), boolean()) :: :ok | {:error, term()}
  def backlight(server \\ __MODULE__, on) when is_boolean(on) do
    GenServer.call(server, {:backlight, on})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      framebuffer: Keyword.get_lazy(opts, :framebuffer, &find_framebuffer/0),
      backlight: Keyword.get(opts, :backlight, "/sys/class/backlight/backlight"),
      # For tests: where the device nodes are.
      dev: Keyword.get(opts, :dev, "/dev"),
      device: nil,
      info: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    case open(state) do
      {:ok, state} -> {:reply, {:ok, state.info}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:show, pixels}, _from, state) do
    with {:ok, state} <- open(state),
         :ok <- check_size(pixels, state.info),
         :ok <- write_rows(state.device, pixels, state.info) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:backlight, on}, _from, state) do
    # bl_power: 0 on, 4 off (FB_BLANK_POWERDOWN).
    {:reply, File.write(Path.join(state.backlight, "bl_power"), if(on, do: "0", else: "4")),
     state}
  end

  defp open(%{device: device} = state) when device != nil, do: {:ok, state}

  defp open(%{framebuffer: nil}), do: {:error, :no_framebuffer}

  defp open(state) do
    with {:ok, info} <- read_info(state.framebuffer),
         {:ok, device} <- File.open(device_path(state), [:write, :raw, :binary]) do
      {:ok, %{state | device: device, info: info}}
    end
  end

  defp device_path(state), do: Path.join(state.dev, Path.basename(state.framebuffer))

  defp read_info(dir) do
    with {:ok, size} <- File.read(Path.join(dir, "virtual_size")),
         [width, height] <- size |> String.trim() |> String.split(","),
         {:ok, stride} <- File.read(Path.join(dir, "stride")),
         {:ok, bits} <- File.read(Path.join(dir, "bits_per_pixel")),
         "16" <- String.trim(bits) do
      {:ok,
       %{
         width: String.to_integer(width),
         height: String.to_integer(height),
         stride: stride |> String.trim() |> String.to_integer()
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unsupported_framebuffer}
    end
  end

  defp check_size(pixels, info) do
    if byte_size(pixels) == info.width * info.height * 2,
      do: :ok,
      else: {:error, {:size, byte_size(pixels), info.width * info.height * 2}}
  end

  # Rows the framebuffer pads to its stride go one by one.
  defp write_rows(device, pixels, %{width: width, stride: stride}) when stride == width * 2 do
    :file.pwrite(device, 0, pixels)
  end

  defp write_rows(device, pixels, info) do
    row = info.width * 2

    for(<<line::binary-size(^row) <- pixels>>, do: line)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {line, y}, :ok ->
      case :file.pwrite(device, y * info.stride, line) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # The framebuffer the panel's DRM driver emulates.
  defp find_framebuffer do
    case File.ls(@graphics) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, "fb"))
        |> Enum.sort()
        |> Enum.map(&Path.join(@graphics, &1))
        |> Enum.find(fn dir ->
          match?({:ok, "panel-mipi-dbi" <> _}, File.read(Path.join(dir, "name")))
        end)

      {:error, _reason} ->
        nil
    end
  end
end
