defmodule NanoKVM.HID.KeymapTest do
  use ExUnit.Case, async: true

  alias NanoKVM.HID.Keymap

  doctest Keymap

  test "maps letters, digits, function and keypad keys" do
    assert Keymap.usage("KeyZ") == 0x1D
    assert Keymap.usage("Digit1") == 0x1E
    assert Keymap.usage("Digit0") == 0x27
    assert Keymap.usage("F12") == 0x45
    assert Keymap.usage("Numpad0") == 0x62
    assert Keymap.usage("ContextMenu") == 0x65
  end

  test "knows the eight modifiers and nothing else as one" do
    bits =
      for side <- ["Left", "Right"],
          key <- ["Control", "Shift", "Alt", "Meta"],
          do: Keymap.modifier(key <> side)

    assert Enum.sort(bits) == [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]
    assert Keymap.usage("ShiftLeft") == nil
    assert Keymap.usage("BrowserBack") == nil
  end
end
