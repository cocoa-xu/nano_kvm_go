defmodule NanoKVM.HID.Keymap do
  @moduledoc """
  Key names to USB HID keyboard usages.

  Keys are named by their physical position, as the W3C UI Events
  `KeyboardEvent.code` values that browsers send ("KeyA", "Digit1",
  "ShiftLeft", "ArrowUp"): the target computer applies its own layout.
  The boot keyboard has the usages 0x04..0x65 and eight modifier keys.
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
  @fkeys for i <- 1..12, into: %{}, do: {"F#{i}", 0x39 + i}
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
            "ContextMenu" => 0x65
          }
          |> Map.merge(@letters)
          |> Map.merge(@digits)
          |> Map.merge(@fkeys)
          |> Map.merge(@numpad)

  @doc """
  The report bit of a modifier key, `nil` for other keys.

      iex> NanoKVM.HID.Keymap.modifier("ShiftLeft")
      0x02
      iex> NanoKVM.HID.Keymap.modifier("KeyA")
      nil
  """
  @spec modifier(code()) :: modifier_bit() | nil
  def modifier(code), do: Map.get(@modifiers, code)

  @doc """
  The HID usage of any other key, `nil` when the boot keyboard has none.

      iex> NanoKVM.HID.Keymap.usage("KeyA")
      0x04
      iex> NanoKVM.HID.Keymap.usage("Enter")
      0x28
  """
  @spec usage(code()) :: 0x04..0x65 | nil
  def usage(code), do: Map.get(@usages, code)
end
