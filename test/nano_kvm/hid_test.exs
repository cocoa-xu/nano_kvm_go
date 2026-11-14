defmodule NanoKVM.HIDTest do
  use ExUnit.Case, async: true

  alias NanoKVM.HID

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    keyboard = Path.join(tmp_dir, "hidg0")
    mouse = Path.join(tmp_dir, "hidg1")
    File.write!(keyboard, "")
    File.write!(mouse, "")
    pid = start_supervised!({HID, keyboard: keyboard, mouse: mouse, name: nil})
    %{hid: pid, keyboard: keyboard, mouse: mouse}
  end

  test "keys make boot keyboard reports", %{hid: hid, keyboard: keyboard} do
    HID.key(hid, "ShiftLeft", :down)
    HID.key(hid, "KeyA", :down)
    HID.key(hid, "KeyA", :down)
    HID.key(hid, "KeyA", :up)
    HID.key(hid, 0xE1, :up)
    HID.key(hid, "NoSuchKey", :down)

    assert reports(keyboard, 8, 4) == [
             <<0x02, 0, 0, 0, 0, 0, 0, 0>>,
             <<0x02, 0, 0x04, 0, 0, 0, 0, 0>>,
             <<0x02, 0, 0, 0, 0, 0, 0, 0>>,
             <<0, 0, 0, 0, 0, 0, 0, 0>>
           ]

    assert %{keyboard: %{sent: 4, dropped: 0}} = HID.stats(hid)
  end

  test "the boot keyboard holds six keys at most", %{hid: hid, keyboard: keyboard} do
    for key <- ~w(KeyA KeyB KeyC KeyD KeyE KeyF KeyG), do: HID.key(hid, key, :down)
    assert List.last(reports(keyboard, 8, 6)) == <<0, 0, 4, 5, 6, 7, 8, 9>>
  end

  test "the pointer keeps what is not given", %{hid: hid, mouse: mouse} do
    HID.pointer(hid, x: 0.5, y: 1.0)
    HID.pointer(hid, buttons: [:left, :middle])
    HID.pointer(hid, x: 0.5)
    HID.pointer(hid, wheel: -3)
    HID.release_all(hid)

    assert reports(mouse, 6, 4) == [
             <<0, 16_384::little-16, 32_767::little-16, 0>>,
             <<5, 16_384::little-16, 32_767::little-16, 0>>,
             <<5, 16_384::little-16, 32_767::little-16, -3::signed>>,
             <<0, 16_384::little-16, 32_767::little-16, 0>>
           ]
  end

  test "without devices reports are dropped", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing")
    hid = start_supervised!({HID, keyboard: missing, mouse: missing, name: nil}, id: :missing)

    HID.key(hid, "KeyA", :down)
    HID.pointer(hid, x: 0.1)

    assert %{keyboard: %{device: nil, sent: 0, dropped: 1}, mouse: %{dropped: 1}} =
             HID.stats(hid)
  end

  # Waits for count reports of size bytes in the file.
  defp reports(path, size, count, tries \\ 100) do
    contents = File.read!(path)

    cond do
      byte_size(contents) >= size * count ->
        for <<report::binary-size(^size) <- contents>>, do: report

      tries == 0 ->
        flunk("#{count} reports expected in #{path}, got #{inspect(contents)}")

      true ->
        Process.sleep(10)
        reports(path, size, count, tries - 1)
    end
  end
end
