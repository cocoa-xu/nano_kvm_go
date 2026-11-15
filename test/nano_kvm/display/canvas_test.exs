defmodule NanoKVM.Display.CanvasTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Display.Canvas

  doctest Canvas

  @white 0xFFFF

  defp pixel(frame, width, x, y) do
    skip = (y * width + x) * 2
    <<_::binary-size(^skip), p::little-16, _::binary>> = frame
    p
  end

  test "renders rows of RGB565 over the background" do
    frame = Canvas.new(4, 3, 0x1234) |> Canvas.render()
    assert frame == :binary.copy(<<0x1234::little-16>>, 12)
  end

  test "rectangles fill, clipped to the picture" do
    frame = Canvas.new(4, 3) |> Canvas.rect(2, 1, 10, 10, @white) |> Canvas.render()

    assert for(y <- 0..2, x <- 0..3, do: pixel(frame, 4, x, y)) ==
             [0, 0, 0, 0, 0, 0, @white, @white, 0, 0, @white, @white]
  end

  test "text strokes the glyph, scaled, with the background between" do
    # Row 2 of "A" is .#####.. in the font.
    frame = Canvas.new(20, 40) |> Canvas.text(2, 4, "A", @white, scale: 2) |> Canvas.render()

    row = for x <- 0..19, do: if(pixel(frame, 20, x, 4 + 2 * 2) == @white, do: 1, else: 0)
    assert row == [0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0]
    assert pixel(frame, 20, 4, 4 + 2 * 2 + 1) == @white
    assert pixel(frame, 20, 4, 3) == 0
  end

  test "turned upside down, the last pixel comes first" do
    canvas = Canvas.new(3, 2) |> Canvas.rect(0, 0, 1, 1, @white)
    upright = Canvas.render(canvas)
    turned = Canvas.render(canvas, rotate: 180)

    assert pixel(upright, 3, 0, 0) == @white
    assert pixel(turned, 3, 2, 1) == @white
    assert pixel(turned, 3, 0, 0) == 0
  end

  test "characters past ASCII show as ?" do
    a = Canvas.new(8, 16) |> Canvas.text(0, 0, "é", @white) |> Canvas.render()
    b = Canvas.new(8, 16) |> Canvas.text(0, 0, "?", @white) |> Canvas.render()
    assert a == b
  end
end
