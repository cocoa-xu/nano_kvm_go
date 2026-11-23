defmodule NanoKVMGo.Display.Canvas do
  @moduledoc """
  Pictures for `NanoKVMGo.Display`: filled rectangles and text, drawn in the
  order given over a background, then rendered as RGB565.

      alias NanoKVMGo.Display.Canvas

      Canvas.new(240, 284, Canvas.rgb(0, 0, 0))
      |> Canvas.rect(0, 0, 240, 40, Canvas.rgb(0, 80, 160))
      |> Canvas.text(8, 4, "NanoKVM-Go", Canvas.rgb(255, 255, 255), scale: 2)
      |> Canvas.render()

  Text is in an 8 × 16 pixel font (Spleen) of printable ASCII, other
  characters shown as `?`, scaled by a whole factor.
  """

  alias NanoKVMGo.Display.Font
  alias NanoKVMGo.Options

  @glyph_width Font.width()
  @glyph_height Font.height()

  defstruct [:width, :height, :background, items: []]

  @typedoc "A colour in RGB565, see `rgb/3`."
  @type color() :: 0..0xFFFF

  @type t() :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          background: color(),
          items: [item()]
        }

  @typep item() ::
           {:rect, integer(), integer(), non_neg_integer(), non_neg_integer(), color()}
           | {:text, integer(), integer(), charlist(), color(), pos_integer()}

  @doc """
  An empty picture.
  """
  @spec new(pos_integer(), pos_integer(), color()) :: t()
  def new(width, height, background \\ 0),
    do: %__MODULE__{width: width, height: height, background: background}

  @doc """
  The RGB565 colour nearest to 8-bit red, green and blue.

      iex> NanoKVMGo.Display.Canvas.rgb(255, 255, 255)
      0xFFFF
      iex> NanoKVMGo.Display.Canvas.rgb(255, 0, 0)
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
  @spec text(t(), integer(), integer(), String.t(), color(), [{:scale, pos_integer()}]) :: t()
  def text(canvas, x, y, string, color, opts \\ []) do
    scale = opts |> Options.validate!([scale: 1], &valid?/2) |> Keyword.fetch!(:scale)
    %{canvas | items: [{:text, x, y, String.to_charlist(string), color, scale} | canvas.items]}
  end

  @doc """
  The width of text in pixels, a character each Unicode code point, as
  `text/6` draws it.

      iex> NanoKVMGo.Display.Canvas.text_width("NanoKVM", 2)
      112
  """
  @spec text_width(String.t(), pos_integer()) :: non_neg_integer()
  def text_width(string, scale \\ 1) when is_integer(scale) and scale > 0,
    do: length(String.to_charlist(string)) * @glyph_width * scale

  @doc """
  The picture as rows of little-endian RGB565 pixels, top to bottom, as a
  framebuffer takes them.

  ## Options

    * `:rotate` - 0 (the default) or 180 degrees, for a display mounted
      upside down
  """
  @spec render(t(), [{:rotate, 0 | 180}]) :: binary()
  def render(%__MODULE__{} = canvas, opts \\ []) do
    rotate = opts |> Options.validate!([rotate: 0], &valid?/2) |> Keyword.fetch!(:rotate)
    items = Enum.reverse(canvas.items)
    blank = :binary.copy(<<canvas.background::little-16>>, canvas.width)

    rows =
      for y <- 0..(canvas.height - 1)//1 do
        Enum.reduce(items, blank, &paint(&1, &2, y, canvas.width))
      end

    case rotate do
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
       when y >= top and y < top + @glyph_height * scale do
    line = div(y - top, scale)

    chars
    |> Enum.with_index()
    |> Enum.reduce(row, fn {char, i}, row ->
      left = x + i * @glyph_width * scale

      Enum.reduce(Font.runs(char, line), row, fn {offset, length}, row ->
        fill(row, row_width, left + offset * scale, length * scale, color)
      end)
    end)
  end

  defp paint(_item, row, _y, _row_width), do: row

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

  defp valid?(:scale, scale), do: is_integer(scale) and scale > 0
  defp valid?(:rotate, rotate), do: rotate in [0, 180]
end
