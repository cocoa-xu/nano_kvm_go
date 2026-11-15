defmodule NanoKVM.DisplayTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Display
  alias NanoKVM.Display.Canvas

  @moduletag :tmp_dir

  # A framebuffer's sysfs directory and its device, a plain file here.
  defp fake(tmp_dir, width, height, stride) do
    sysfs = Path.join(tmp_dir, "fb0")
    dev = Path.join(tmp_dir, "dev")
    File.mkdir_p!(sysfs)
    File.mkdir_p!(dev)
    File.write!(Path.join(sysfs, "virtual_size"), "#{width},#{height}\n")
    File.write!(Path.join(sysfs, "stride"), "#{stride}\n")
    File.write!(Path.join(sysfs, "bits_per_pixel"), "16\n")
    File.write!(Path.join(dev, "fb0"), "")
    backlight = Path.join(tmp_dir, "backlight")
    File.mkdir_p!(backlight)
    {sysfs, dev, backlight}
  end

  test "shows pictures and canvases", %{tmp_dir: tmp_dir} do
    {sysfs, dev, backlight} = fake(tmp_dir, 4, 2, 8)

    display =
      start_supervised!({Display, framebuffer: sysfs, dev: dev, backlight: backlight, name: nil})

    assert Display.info(display) == {:ok, %{width: 4, height: 2, stride: 8}}
    assert :ok = Display.show(display, Canvas.new(4, 2, 0xABCD))
    assert File.read!(Path.join(dev, "fb0")) == :binary.copy(<<0xABCD::little-16>>, 8)
    assert {:error, {:size, 2, 16}} = Display.show(display, <<0, 0>>)

    assert :ok = Display.backlight(display, false)
    assert File.read!(Path.join(backlight, "bl_power")) == "4"
  end

  test "rows go to their place in a padded framebuffer", %{tmp_dir: tmp_dir} do
    {sysfs, dev, backlight} = fake(tmp_dir, 2, 2, 8)

    display =
      start_supervised!({Display, framebuffer: sysfs, dev: dev, backlight: backlight, name: nil})

    assert :ok = Display.show(display, <<1::little-16, 2::little-16, 3::little-16, 4::little-16>>)

    assert File.read!(Path.join(dev, "fb0")) ==
             <<1::little-16, 2::little-16, 0::32, 3::little-16, 4::little-16>>
  end

  test "fills a rectangle, leaving out what falls outside", %{tmp_dir: tmp_dir} do
    {sysfs, dev, backlight} = fake(tmp_dir, 3, 3, 8)

    display =
      start_supervised!({Display, framebuffer: sysfs, dev: dev, backlight: backlight, name: nil})

    assert :ok = Display.show(display, Canvas.new(3, 3, 0))
    assert :ok = Display.fill(display, 1, 1, 5, 5, 0xABCD)
    assert :ok = Display.fill(display, 3, 0, 2, 2, 0xFFFF)
    assert :ok = Display.fill(display, -4, 0, 4, 1, 0xFFFF)

    filled = <<0::16, 0xABCD::little-16, 0xABCD::little-16>>
    assert File.read!(Path.join(dev, "fb0")) == <<0::48, 0::16>> <> filled <> <<0::16>> <> filled
  end

  test "sets and reads the brightness in percent of the backlight's levels",
       %{tmp_dir: tmp_dir} do
    {sysfs, dev, backlight} = fake(tmp_dir, 4, 2, 8)
    File.write!(Path.join(backlight, "max_brightness"), "200\n")
    File.write!(Path.join(backlight, "brightness"), "50\n")

    display =
      start_supervised!({Display, framebuffer: sysfs, dev: dev, backlight: backlight, name: nil})

    assert Display.brightness(display) == {:ok, 25}
    assert :ok = Display.set_brightness(display, 60)
    assert File.read!(Path.join(backlight, "brightness")) == "120"
    assert Display.brightness(display) == {:ok, 60}
  end

  test "without a framebuffer, errors", %{tmp_dir: tmp_dir} do
    display = start_supervised!({Display, framebuffer: nil, dev: tmp_dir, name: nil})
    assert Display.info(display) == {:error, :no_framebuffer}
  end
end
