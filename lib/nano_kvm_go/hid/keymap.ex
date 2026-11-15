defmodule NanoKVMGo.HID.Keymap do
  @moduledoc """
  Key names to USB HID keyboard usages.

  Keys are named by their physical position, as the W3C UI Events
  `KeyboardEvent.code` values that browsers send ("KeyA", "Digit1",
  "ShiftLeft", "ArrowUp"): the target computer applies its own layout.
  The keyboard has the usages 0x04..0xDD and eight modifier keys.
  """

  @typedoc "A `KeyboardEvent.code` value."
  @type code() :: String.t()

  @typedoc "A modifier key as a bit of the boot keyboard report."
  @type modifier_bit() :: 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x80

  @modifiers %{
    "ControlLeft" => 0x01,
    "ShiftLeft" => 0x02,
    "AltLeft" => 0x04,
    "MetaLeft" => 0x08,
    "ControlRight" => 0x10,
    "ShiftRight" => 0x20,
    "AltRight" => 0x40,
    "MetaRight" => 0x80
  }

  @letters for {c, i} <- Enum.with_index(?A..?Z), into: %{}, do: {"Key" <> <<c>>, 0x04 + i}
  @digits for {c, i} <- Enum.with_index(?1..?9),
              into: %{"Digit0" => 0x27},
              do: {"Digit" <> <<c>>, 0x1E + i}
  @fkeys for(i <- 1..12, into: %{}, do: {"F#{i}", 0x39 + i})
         |> Map.merge(for i <- 13..24, into: %{}, do: {"F#{i}", 0x5B + i})
  @numpad for i <- 1..9, into: %{"Numpad0" => 0x62}, do: {"Numpad#{i}", 0x58 + i}

  @usages %{
            "Enter" => 0x28,
            "Escape" => 0x29,
            "Backspace" => 0x2A,
            "Tab" => 0x2B,
            "Space" => 0x2C,
            "Minus" => 0x2D,
            "Equal" => 0x2E,
            "BracketLeft" => 0x2F,
            "BracketRight" => 0x30,
            "Backslash" => 0x31,
            "Semicolon" => 0x33,
            "Quote" => 0x34,
            "Backquote" => 0x35,
            "Comma" => 0x36,
            "Period" => 0x37,
            "Slash" => 0x38,
            "CapsLock" => 0x39,
            "PrintScreen" => 0x46,
            "ScrollLock" => 0x47,
            "Pause" => 0x48,
            "Insert" => 0x49,
            "Home" => 0x4A,
            "PageUp" => 0x4B,
            "Delete" => 0x4C,
            "End" => 0x4D,
            "PageDown" => 0x4E,
            "ArrowRight" => 0x4F,
            "ArrowLeft" => 0x50,
            "ArrowDown" => 0x51,
            "ArrowUp" => 0x52,
            "NumLock" => 0x53,
            "NumpadDivide" => 0x54,
            "NumpadMultiply" => 0x55,
            "NumpadSubtract" => 0x56,
            "NumpadAdd" => 0x57,
            "NumpadEnter" => 0x58,
            "NumpadDecimal" => 0x63,
            "IntlBackslash" => 0x64,
            "ContextMenu" => 0x65,
            "Power" => 0x66,
            "NumpadEqual" => 0x67,
            "Help" => 0x75,
            "Select" => 0x77,
            "Again" => 0x79,
            "Undo" => 0x7A,
            "Cut" => 0x7B,
            "Copy" => 0x7C,
            "Paste" => 0x7D,
            "Find" => 0x7E,
            "AudioVolumeMute" => 0x7F,
            "AudioVolumeUp" => 0x80,
            "AudioVolumeDown" => 0x81,
            "NumpadComma" => 0x85,
            "IntlRo" => 0x87,
            "KanaMode" => 0x88,
            "IntlYen" => 0x89,
            "Convert" => 0x8A,
            "NonConvert" => 0x8B,
            "Lang1" => 0x90,
            "Lang2" => 0x91,
            "Lang3" => 0x92,
            "Lang4" => 0x93,
            "Lang5" => 0x94,
            "NumpadParenLeft" => 0xB6,
            "NumpadParenRight" => 0xB7,
            "NumpadBackspace" => 0xBB,
            "NumpadClear" => 0xD8,
            "NumpadClearEntry" => 0xD9
          }
          |> Map.merge(@letters)
          |> Map.merge(@digits)
          |> Map.merge(@fkeys)
          |> Map.merge(@numpad)

  # Characters on a US keyboard: the key, and whether with shift.
  @shifted_digits ~c")!@#$%^&*("
  @characters %{?\s => {"Space", false}, ?\n => {"Enter", false}, ?\t => {"Tab", false}}
              |> Map.merge(
                for c <- ?a..?z, into: %{}, do: {c, {"Key" <> String.upcase(<<c>>), false}}
              )
              |> Map.merge(for c <- ?A..?Z, into: %{}, do: {c, {"Key" <> <<c>>, true}})
              |> Map.merge(for c <- ?0..?9, into: %{}, do: {c, {"Digit" <> <<c>>, false}})
              |> Map.merge(
                for {c, i} <- Enum.with_index(@shifted_digits),
                    into: %{},
                    do: {c, {"Digit#{i}", true}}
              )
              |> Map.merge(
                for {plain, shifted, code} <- [
                      {?-, ?_, "Minus"},
                      {?=, ?+, "Equal"},
                      {?[, ?{, "BracketLeft"},
                      {?], ?}, "BracketRight"},
                      {?\\, ?|, "Backslash"},
                      {?;, ?:, "Semicolon"},
                      {?', ?", "Quote"},
                      {?`, ?~, "Backquote"},
                      {?,, ?<, "Comma"},
                      {?., ?>, "Period"},
                      {?/, ??, "Slash"}
                    ],
                    {char, shift} <- [{plain, false}, {shifted, true}],
                    into: %{},
                    do: {char, {code, shift}}
              )

  @doc """
  The key that types a character on a US keyboard, and whether with shift;
  `nil` for characters it has no key for.

      iex> NanoKVMGo.HID.Keymap.character(?A)
      {"KeyA", true}
      iex> NanoKVMGo.HID.Keymap.character(10)
      {"Enter", false}
      iex> NanoKVMGo.HID.Keymap.character(?é)
      nil
  """
  @spec character(char()) :: {code(), boolean()} | nil
  def character(char), do: Map.get(@characters, char)

  @doc """
  The report bit of a modifier key, `nil` for other keys.

      iex> NanoKVMGo.HID.Keymap.modifier("ShiftLeft")
      0x02
      iex> NanoKVMGo.HID.Keymap.modifier("KeyA")
      nil
  """
  @spec modifier(code()) :: modifier_bit() | nil
  def modifier(code), do: Map.get(@modifiers, code)

  @doc """
  The HID usage of any other key, `nil` when the keyboard has none.

      iex> NanoKVMGo.HID.Keymap.usage("KeyA")
      0x04
      iex> NanoKVMGo.HID.Keymap.usage("Enter")
      0x28
  """
  @spec usage(code()) :: 0x04..0xDD | nil
  def usage(code), do: Map.get(@usages, code)
end
