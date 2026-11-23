defmodule NanoKVMGo.Display do
  @moduledoc """
  The NanoKVM-Go's LCD: 240 × 284 pixels in portrait, through the Linux
  framebuffer of its panel. The panel hides the last 14 rows: 240 × 270 of
  them show. Its light is `NanoKVMGo.Backlight`.

      alias NanoKVMGo.Display.Canvas

      {:ok, %{width: width, height: height}} = NanoKVMGo.Display.info()

      Canvas.new(width, height, Canvas.rgb(0, 0, 0))
      |> Canvas.text(8, 8, "Hello", Canvas.rgb(255, 255, 255), scale: 2)
      |> NanoKVMGo.Display.show()

      NanoKVMGo.Display.fill(100, 100, 8, 8, Canvas.rgb(255, 0, 0))

  `show/2` writes only the rows that differ from what the framebuffer
  holds, and the kernel sends only those to the panel: showing the same
  picture again costs little, and puts back what something else drew over
  it, such as the kernel's console. Without the framebuffer (no panel, or a
  system without the driver) the calls return an error. The framebuffer is
  looked for when first needed, and again after a write fails: the display
  carries on when the panel's driver loads late or probes again.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Display` by default
    * `:framebuffer` - the framebuffer's sysfs directory, by default the one
      of the panel's driver (`panel-mipi-dbi`)
    * `:root` - the root of the file system with sysfs and the device
      nodes, `"/"` by default
  """
  use GenServer

  alias NanoKVMGo.Display.Canvas
  alias NanoKVMGo.Options

  @type info() :: %{width: pos_integer(), height: pos_integer(), stride: pos_integer()}

  @type option() ::
          {:name, GenServer.name()} | {:framebuffer, Path.t() | nil} | {:root, Path.t()}

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, [name: __MODULE__, framebuffer: nil, root: "/"], &valid?/2)
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  The size of the display in pixels, and of a row in bytes.
  """
  @spec info(GenServer.server()) :: {:ok, info()} | {:error, term()}
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  Shows a picture: a `NanoKVMGo.Display.Canvas` the size of the display, or
  rows of little-endian RGB565 pixels. Only the rows that differ from the
  framebuffer are written.
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
  def init(config), do: {:ok, Map.merge(config, %{device: nil, info: nil})}

  @impl GenServer
  def handle_call(:info, _from, state) do
    case open(state) do
      {:ok, state} -> {:reply, {:ok, state.info}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:show, pixels}, _from, state) do
    case open(state) do
      {:ok, state} -> show_pixels(state, pixels)
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
    with dir when is_binary(dir) <- state.framebuffer || find_framebuffer(state.root),
         {:ok, info} <- read_info(dir),
         node = Path.join([state.root, "dev", Path.basename(dir)]),
         {:ok, device} <- File.open(node, [:read, :write, :raw, :binary]) do
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
    with {:ok, {width, height}} <- read_size(dir),
         {:ok, stride} <- read_stride(dir),
         :ok <- check_depth(dir) do
      {:ok, %{width: width, height: height, stride: stride}}
    end
  end

  defp read_size(dir) do
    with {:ok, size} <- read_attribute(dir, "virtual_size") do
      case Enum.map(String.split(size, ","), &Integer.parse/1) do
        [{width, ""}, {height, ""}] -> {:ok, {width, height}}
        _other -> {:error, {:invalid_attribute, "virtual_size", size}}
      end
    end
  end

  defp read_stride(dir) do
    with {:ok, text} <- read_attribute(dir, "stride") do
      case Integer.parse(text) do
        {stride, ""} -> {:ok, stride}
        _other -> {:error, {:invalid_attribute, "stride", text}}
      end
    end
  end

  defp check_depth(dir) do
    case read_attribute(dir, "bits_per_pixel") do
      {:ok, "16"} -> :ok
      {:ok, _bits} -> {:error, :unsupported_framebuffer}
      error -> error
    end
  end

  defp read_attribute(dir, name) do
    with {:ok, text} <- File.read(Path.join(dir, name)), do: {:ok, String.trim(text)}
  end

  defp show_pixels(%{info: info} = state, pixels) do
    case info.width * info.height * 2 do
      size when byte_size(pixels) == size ->
        written(show_changes(state.device, pixels, info), state)

      size ->
        {:reply, {:error, {:size, byte_size(pixels), size}}, state}
    end
  end

  # Writes the rows from the first to the last that differ from what the
  # framebuffer holds.
  defp show_changes(device, pixels, info) do
    row = info.width * 2

    with {:ok, held} <- read_rows(device, info) do
      case changed_rows(held, pixels, row) do
        nil -> :ok
        rows -> pwrite(device, row_writes(pixels, rows, row, info.stride))
      end
    end
  end

  # The rows the framebuffer holds; rows past its end are missing.
  defp read_rows(device, %{width: width, height: height, stride: stride}) do
    case :file.pread(device, 0, stride * height) do
      {:ok, data} -> {:ok, unpad(data, width * 2, stride)}
      :eof -> {:ok, <<>>}
      error -> error
    end
  end

  defp unpad(data, row, row), do: data

  defp unpad(data, row, stride),
    do: for(<<line::binary-size(^stride) <- data>>, into: <<>>, do: binary_part(line, 0, row))

  defp changed_rows(same, same, _row), do: nil

  defp changed_rows(held, pixels, row) do
    differs? = fn y -> row_at(held, y, row) != row_at(pixels, y, row) end
    rows = div(byte_size(pixels), row)
    first = Enum.find(0..(rows - 1), differs?)
    last = Enum.find((rows - 1)..first//-1, differs?)
    first..last//1
  end

  defp row_at(data, y, row) when (y + 1) * row <= byte_size(data),
    do: binary_part(data, y * row, row)

  defp row_at(_data, _y, _row), do: nil

  # One write for the rows when the framebuffer packs them, one each when it
  # pads them to its stride.
  defp row_writes(pixels, first..last//1, row, row) do
    [{first * row, binary_part(pixels, first * row, (last - first + 1) * row)}]
  end

  defp row_writes(pixels, rows, row, stride) do
    for y <- rows, do: {y * stride, binary_part(pixels, y * row, row)}
  end

  defp pwrite(device, writes) do
    case :file.pwrite(device, writes) do
      :ok -> :ok
      {:error, {_written, reason}} -> {:error, reason}
    end
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
    pwrite(device, for(row <- y0..(y1 - 1), do: {row * info.stride + x0 * 2, line}))
  end

  # The framebuffer the panel's DRM driver emulates.
  defp find_framebuffer(root) do
    graphics = Path.join(root, "sys/class/graphics")

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

  defp valid?(:name, _name), do: true
  defp valid?(:framebuffer, framebuffer), do: is_binary(framebuffer) or is_nil(framebuffer)
  defp valid?(:root, root), do: is_binary(root)
end
