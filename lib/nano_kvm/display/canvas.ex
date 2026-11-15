defmodule NanoKVM.Display.Canvas do
  @moduledoc """
  Pictures for `NanoKVM.Display`: filled rectangles and text, drawn in the
  order given over a background, then rendered as RGB565.

      alias NanoKVM.Display.Canvas

      Canvas.new(240, 284, Canvas.rgb(0, 0, 0))
      |> Canvas.rect(0, 0, 240, 40, Canvas.rgb(0, 80, 160))
      |> Canvas.text(8, 4, "NanoKVM-Go", Canvas.rgb(255, 255, 255), scale: 2)
      |> Canvas.render()

  Text is in an 8 × 16 pixel font (Spleen) of printable ASCII, other
  characters shown as `?`, scaled by a whole factor.
  """

  alias NanoKVM.Display.Font

  defstruct [:width, :height, :background, items: []]

  @typedoc "A colour in RGB565, see `rgb/3`."
  @type color() :: 0..0xFFFF

  @type t() :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          background: color(),
          items: list()
        }

  @doc """
  An empty picture.
  """
  @spec new(pos_integer(), pos_integer(), color()) :: t()
  def new(width, height, background \\ 0),
    do: %__MODULE__{width: width, height: height, background: background}

  @doc """
  The RGB565 colour nearest to 8-bit red, green and blue.

      iex> NanoKVM.Display.Canvas.rgb(255, 255, 255)
      0xFFFF
      iex> NanoKVM.Display.Canvas.rgb(255, 0, 0)
      0xF800
  """
  @spec rgb(0..255, 0..255, 0..255) :: color()
  def rgb(r, g, b),
    do:
      Bitwise.bsl(div(r * 31 + 127, 255), 11) + Bitwise.bsl(div(g * 63 + 127, 255), 5) +
        div(b * 31 + 127, 255)

  @doc """
  Fills a rectangle; what falls outside the picture is left out.
  """
  @spec rect(t(), integer(), integer(), non_neg_integer(), non_neg_integer(), color()) :: t()
  def rect(canvas, x, y, width, height, color) do
    %{canvas | items: [{:rect, x, y, width, height, color} | canvas.items]}
  end

  @doc """
  Writes text from its top left corner; the background shows between the
  strokes.

  ## Options

    * `:scale` - the size, 1 for 8 × 16 pixels a character (the default)
  """
  @spec text(t(), integer(), integer(), String.t(), color(), keyword()) :: t()
  def text(canvas, x, y, string, color, opts \\ []) do
    scale = Keyword.get(opts, :scale, 1)
    %{canvas | items: [{:text, x, y, String.to_charlist(string), color, scale} | canvas.items]}
  end

  @doc """
  The width of text in pixels.

      iex> NanoKVM.Display.Canvas.text_width("NanoKVM", 2)
      112
  """
  @spec text_width(String.t(), pos_integer()) :: non_neg_integer()
  def text_width(string, scale \\ 1) when is_integer(scale) and scale > 0,
    do: String.length(string) * Font.width() * scale

  @doc """
  The picture as rows of little-endian RGB565 pixels, top to bottom, as a
  framebuffer takes them.

  ## Options

    * `:rotate` - 0 (the default) or 180 degrees, for a display mounted
      upside down
  """
  @spec render(t(), keyword()) :: binary()
  def render(%__MODULE__{} = canvas, opts \\ []) do
    items = Enum.reverse(canvas.items)
    blank = :binary.copy(<<canvas.background::little-16>>, canvas.width)

    rows =
      for y <- 0..(canvas.height - 1)//1 do
        Enum.reduce(items, blank, &paint(&1, &2, y, canvas.width))
      end

    case Keyword.get(opts, :rotate, 0) do
      0 -> IO.iodata_to_binary(rows)
      180 -> rows |> Enum.reverse() |> Enum.map(&reverse_pixels/1) |> IO.iodata_to_binary()
    end
  end

  defp reverse_pixels(row) do
    for <<pixel::binary-size(2) <- row>>, reduce: [], do: (pixels -> [pixel | pixels])
  end

  defp paint({:rect, x, top, width, height, color}, row, y, row_width)
       when y >= top and y < top + height do
    fill(row, row_width, x, width, color)
  end

  defp paint({:text, x, top, chars, color, scale}, row, y, row_width)
       when y >= top and y < top + 16 * scale do
    line = div(y - top, scale)

    chars
    |> Enum.with_index()
    |> Enum.reduce(row, fn {char, i}, row ->
      <<_::binary-size(^line), bits, _::binary>> = Font.glyph(char)
      strokes(bits, 7, row, row_width, x + i * 8 * scale, scale, color)
    end)
  end

  defp paint(_item, row, _y, _row_width), do: row

  # The runs of set bits, from the leftmost pixel.
  defp strokes(_bits, bit, row, _row_width, _x, _scale, _color) when bit < 0, do: row

  defp strokes(bits, bit, row, row_width, x, scale, color) do
    if Bitwise.band(Bitwise.bsr(bits, bit), 1) == 1 do
      run = run_length(bits, bit, 0)
      row = fill(row, row_width, x + (7 - bit) * scale, run * scale, color)
      strokes(bits, bit - run, row, row_width, x, scale, color)
    else
      strokes(bits, bit - 1, row, row_width, x, scale, color)
    end
  end

  defp run_length(bits, bit, n) do
    if bit >= 0 and Bitwise.band(Bitwise.bsr(bits, bit), 1) == 1,
      do: run_length(bits, bit - 1, n + 1),
      else: n
  end

  defp fill(row, row_width, x, width, color) do
    from = max(x, 0)
    to = min(x + width, row_width)

    if from < to do
      skip = from * 2
      take = (to - from) * 2
      <<before::binary-size(^skip), _::binary-size(^take), rest::binary>> = row
      [before, :binary.copy(<<color::little-16>>, to - from), rest] |> IO.iodata_to_binary()
    else
      row
    end
  end
end
