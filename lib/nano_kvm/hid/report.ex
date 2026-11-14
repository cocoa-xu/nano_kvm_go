defmodule NanoKVM.HID.Report do
  @moduledoc """
  The USB HID reports of the boot keyboard and the absolute mouse that
  `NanoKVM.USB` sets up.
  """

  import Bitwise

  @typedoc "Mouse buttons as report bits: 1 left, 2 right, 4 middle."
  @type buttons() :: 0..7

  @doc """
  A boot keyboard report: the modifier bits, a reserved byte and up to six
  key usages.

      iex> NanoKVM.HID.Report.keyboard(0x02, [0x04])
      <<0x02, 0, 0x04, 0, 0, 0, 0, 0>>
  """
  @spec keyboard(0..255, [0..255]) :: <<_::64>>
  def keyboard(modifiers, keys) when length(keys) <= 6 do
    keys = keys ++ List.duplicate(0, 6 - length(keys))
    <<modifiers, 0>> <> :binary.list_to_bin(keys)
  end

  @doc """
  An absolute mouse report: the buttons, X and Y from 0 (left, top) to 32767
  (right, bottom), and wheel steps, positive up.

      iex> NanoKVM.HID.Report.mouse(1, 16384, 0, -1)
      <<1, 0x00, 0x40, 0, 0, 0xFF>>
  """
  @spec mouse(buttons(), 0..32_767, 0..32_767, -127..127) :: <<_::48>>
  def mouse(buttons, x, y, wheel) do
    <<buttons &&& 0x07, x::little-16, y::little-16, wheel::signed-8>>
  end

  @doc """
  A position across the screen, 0.0 to 1.0 (clamped), in the mouse's range.

      iex> NanoKVM.HID.Report.absolute(0.5)
      16384
  """
  @spec absolute(number()) :: 0..32_767
  def absolute(v), do: round(min(max(v, 0.0), 1.0) * 32_767)
end
