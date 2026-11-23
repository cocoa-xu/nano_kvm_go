defmodule NanoKVMGo.DisplayTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Display
  alias NanoKVMGo.Display.Canvas

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
    {sysfs, dev}
  end

  test "shows pictures and canvases", %{tmp_dir: tmp_dir} do
    {sysfs, dev} = fake(tmp_dir, 4, 2, 8)

    display =
      start_supervised!({Display, framebuffer: sysfs, dev: dev, name: nil})

    assert Display.info(display) == {:ok, %{width: 4, height: 2, stride: 8}}
    assert :ok = Display.show(display, Canvas.new(4, 2, 0xABCD))
    assert File.read!(Path.join(dev, "fb0")) == :binary.copy(<<0xABCD::little-16>>, 8)
    assert {:error, {:size, 2, 16}} = Display.show(display, <<0, 0>>)
  end

  test "keeps the framebuffer it opened for a picture of the wrong size", %{tmp_dir: tmp_dir} do
    {sysfs, dev} = fake(tmp_dir, 2, 1, 4)
    display = start_supervised!({Display, framebuffer: sysfs, dev: dev, name: nil})

    assert Display.show(display, <<0, 0>>) == {:error, {:size, 2, 4}}
    File.rm_rf!(sysfs)
    assert :ok = Display.show(display, <<1::little-16, 2::little-16>>)
    assert File.read!(Path.join(dev, "fb0")) == <<1::little-16, 2::little-16>>
  end

  test "rows go to their place in a padded framebuffer", %{tmp_dir: tmp_dir} do
    {sysfs, dev} = fake(tmp_dir, 2, 2, 8)

    display =
      start_supervised!({Display, framebuffer: sysfs, dev: dev, name: nil})

    assert :ok = Display.show(display, <<1::little-16, 2::little-16, 3::little-16, 4::little-16>>)

    assert File.read!(Path.join(dev, "fb0")) ==
             <<1::little-16, 2::little-16, 0::32, 3::little-16, 4::little-16>>
  end

  test "fills a rectangle, leaving out what falls outside", %{tmp_dir: tmp_dir} do
    {sysfs, dev} = fake(tmp_dir, 3, 3, 8)

    display =
      start_supervised!({Display, framebuffer: sysfs, dev: dev, name: nil})

    assert :ok = Display.show(display, Canvas.new(3, 3, 0))
    assert :ok = Display.fill(display, 1, 1, 5, 5, 0xABCD)
    assert :ok = Display.fill(display, 3, 0, 2, 2, 0xFFFF)
    assert :ok = Display.fill(display, -4, 0, 4, 1, 0xFFFF)

    filled = <<0::16, 0xABCD::little-16, 0xABCD::little-16>>
    assert File.read!(Path.join(dev, "fb0")) == <<0::48, 0::16>> <> filled <> <<0::16>> <> filled
  end

  test "puts back rows something else drew over, and writes what changed",
       %{tmp_dir: tmp_dir} do
    for stride <- [4, 6] do
      {sysfs, dev} = fake(Path.join(tmp_dir, "#{stride}"), 2, 3, stride)
      fb = Path.join(dev, "fb0")
      # A framebuffer holds whole strides, padding after the last row too.
      File.write!(fb, :binary.copy(<<0>>, 3 * stride))
      display = start_supervised!({Display, framebuffer: sysfs, dev: dev, name: nil}, id: stride)

      held = fn ->
        for <<line::binary-size(^stride) <- File.read!(fb)>>,
          into: <<>>,
          do: binary_part(line, 0, 4)
      end

      picture = for value <- 1..6, into: <<>>, do: <<value::little-16>>
      assert :ok = Display.show(display, picture)
      assert held.() == picture

      # A console draws over the last row; the same picture puts it back.
      File.write!(fb, binary_part(File.read!(fb), 0, 2 * stride) <> :binary.copy(<<9>>, stride))
      assert :ok = Display.show(display, picture)
      assert held.() == picture

      changed =
        binary_part(picture, 0, 4) <> <<7::little-16, 8::little-16>> <> binary_part(picture, 8, 4)

      assert :ok = Display.show(display, changed)
      assert held.() == changed
    end
  end

  test "without a framebuffer, errors", %{tmp_dir: tmp_dir} do
    display =
      start_supervised!(
        {Display, graphics: Path.join(tmp_dir, "graphics"), dev: tmp_dir, name: nil}
      )

    assert Display.info(display) == {:error, :no_framebuffer}
  end

  test "finds the panel's framebuffer once it comes, and again after a write fails",
       %{tmp_dir: tmp_dir} do
    graphics = Path.join(tmp_dir, "graphics")
    dev = Path.join(tmp_dir, "dev")
    File.mkdir_p!(dev)
    display = start_supervised!({Display, graphics: graphics, dev: dev, name: nil})

    assert Display.info(display) == {:error, :no_framebuffer}

    framebuffer(graphics, dev, "fb0", "simple")
    framebuffer(graphics, dev, "fb1", "panel-mipi-dbid")
    assert :ok = Display.show(display, <<1::little-16, 2::little-16>>)
    assert File.read!(Path.join(dev, "fb1")) == <<1::little-16, 2::little-16>>

    # The panel's driver probes again: the device open fails its writes, and
    # the framebuffer comes back under another number.
    :sys.replace_state(display, fn state ->
      :ok = File.close(state.device)
      state
    end)

    File.rm_rf!(Path.join(graphics, "fb1"))
    framebuffer(graphics, dev, "fb2", "panel-mipi-dbid")

    assert {:error, _reason} = Display.fill(display, 0, 0, 1, 1, 0xFFFF)
    assert :ok = Display.show(display, <<3::little-16, 4::little-16>>)
    assert File.read!(Path.join(dev, "fb2")) == <<3::little-16, 4::little-16>>
  end

  # A 2 × 1 framebuffer named as its driver names it, and its device.
  defp framebuffer(graphics, dev, fb, name) do
    sysfs = Path.join(graphics, fb)
    File.mkdir_p!(sysfs)

    for {file, value} <- [
          {"name", "#{name}\n"},
          {"virtual_size", "2,1\n"},
          {"stride", "4\n"},
          {"bits_per_pixel", "16\n"}
        ],
        do: File.write!(Path.join(sysfs, file), value)

    File.write!(Path.join(dev, fb), "")
  end
end
