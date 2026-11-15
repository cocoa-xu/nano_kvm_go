defmodule NanoKVM.Display do
  @moduledoc """
  The NanoKVM-Go's LCD: 240 × 284 pixels in portrait, through the Linux
  framebuffer of its panel. The panel hides the last 14 rows: 240 × 270 of
  them show. Its light is `NanoKVM.Backlight`.

      alias NanoKVM.Display.Canvas

      {:ok, %{width: width, height: height}} = NanoKVM.Display.info()

      Canvas.new(width, height, Canvas.rgb(0, 0, 0))
      |> Canvas.text(8, 8, "Hello", Canvas.rgb(255, 255, 255), scale: 2)
      |> NanoKVM.Display.show()

      NanoKVM.Display.fill(100, 100, 8, 8, Canvas.rgb(255, 0, 0))

  The kernel sends what changed to the panel. Without the framebuffer (no
  panel, or a system without the driver) the calls return an error. The
  framebuffer is looked for when first needed, and again after a write
  fails: the display carries on when the panel's driver loads late or
  probes again.

  ## Options

    * `:name` - the name to register, `NanoKVM.Display` by default
    * `:framebuffer` - the framebuffer's sysfs directory, by default the one
      of the panel's driver (`panel-mipi-dbi`)
  """
  use GenServer

  alias NanoKVM.Display.Canvas

  @type info() :: %{width: pos_integer(), height: pos_integer(), stride: pos_integer()}

  @type option() ::
          {:name, GenServer.name()} | {:framebuffer, Path.t()}

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
  Fills a rectangle with a colour and leaves the rest of the picture: quicker
  than showing a whole one for a small change. What falls outside the
  display is left out.
  """
  @spec fill(
          GenServer.server(),
          integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          Canvas.color()
        ) :: :ok | {:error, term()}
  def fill(server \\ __MODULE__, x, y, width, height, color) do
    GenServer.call(server, {:fill, {x, y, width, height}, color})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      framebuffer: Keyword.get(opts, :framebuffer),
      # For tests: where framebuffers and device nodes are.
      graphics: Keyword.get(opts, :graphics, "/sys/class/graphics"),
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
         :ok <- check_size(pixels, state.info) do
      written(write_rows(state.device, pixels, state.info), state)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:fill, rect, color}, _from, state) do
    case open(state) do
      {:ok, state} -> written(fill_rect(state.device, state.info, rect, color), state)
      error -> {:reply, error, state}
    end
  end

  defp open(%{device: device} = state) when device != nil, do: {:ok, state}

  defp open(state) do
    with dir when is_binary(dir) <- state.framebuffer || find_framebuffer(state.graphics),
         {:ok, info} <- read_info(dir),
         {:ok, device} <-
           File.open(Path.join(state.dev, Path.basename(dir)), [:write, :raw, :binary]) do
      {:ok, %{state | device: device, info: info}}
    else
      nil -> {:error, :no_framebuffer}
      error -> error
    end
  end

  # A framebuffer that fails a write may be gone with its driver: the next
  # call opens one again.
  defp written(:ok, state), do: {:reply, :ok, state}

  defp written({:error, _reason} = error, state) do
    _ = File.close(state.device)
    {:reply, error, %{state | device: nil, info: nil}}
  end

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

  defp fill_rect(device, info, rect, color) do
    case clip(rect, info) do
      nil -> :ok
      clipped -> write_fill(device, info, clipped, color)
    end
  end

  defp clip({x, y, width, height}, info) do
    {x0, y0} = {max(x, 0), max(y, 0)}
    {x1, y1} = {min(x + width, info.width), min(y + height, info.height)}
    if x1 > x0 and y1 > y0, do: {x0, y0, x1, y1}
  end

  defp write_fill(device, info, {x0, y0, x1, y1}, color) do
    line = :binary.copy(<<color::little-16>>, x1 - x0)

    case :file.pwrite(device, for(row <- y0..(y1 - 1), do: {row * info.stride + x0 * 2, line})) do
      :ok -> :ok
      {:error, {_written, reason}} -> {:error, reason}
    end
  end

  # The framebuffer the panel's DRM driver emulates.
  defp find_framebuffer(graphics) do
    case File.ls(graphics) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, "fb"))
        |> Enum.sort()
        |> Enum.map(&Path.join(graphics, &1))
        |> Enum.find(fn dir ->
          match?({:ok, "panel-mipi-dbi" <> _}, File.read(Path.join(dir, "name")))
        end)

      {:error, _reason} ->
        nil
    end
  end
end
