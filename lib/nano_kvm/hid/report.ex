defmodule NanoKVM.HID.Report do
  @moduledoc """
  The USB HID reports of the devices `NanoKVM.USB` sets up: the boot
  keyboard, the relative boot mouse, and the absolute pointer as a mouse, a
  pen or a touch screen.
  """

  import Bitwise

  @typedoc "Mouse buttons as report bits: 1 left, 2 right, 4 middle, 8 back, 16 forward."
  @type buttons() :: 0..31

  @typedoc "A touch: its id (0 to 9) and where, from 0 to 32767."
  @type contact() :: {0..9, 0..32_767, 0..32_767}

  @max_contacts 10

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
  (right, bottom), and wheel steps, positive up, and to the right.

      iex> NanoKVM.HID.Report.mouse(1, 16384, 0, -1, 0)
      <<1, 0x00, 0x40, 0, 0, 0xFF, 0>>
  """
  @spec mouse(buttons(), 0..32_767, 0..32_767, -127..127, -127..127) :: <<_::56>>
  def mouse(buttons, x, y, wheel, pan) do
    <<buttons &&& 0x1F, x::little-16, y::little-16, wheel::signed-8, pan::signed-8>>
  end

  @doc """
  A relative boot mouse report: the buttons, the movement right and down,
  and wheel steps, positive up, and to the right. The first three bytes are
  the boot report.

      iex> NanoKVM.HID.Report.relative_mouse(2, -5, 10, 0, 1)
      <<2, 0xFB, 10, 0, 1>>
  """
  @spec relative_mouse(buttons(), -127..127, -127..127, -127..127, -127..127) :: <<_::40>>
  def relative_mouse(buttons, dx, dy, wheel, pan) do
    <<buttons &&& 0x1F, dx::signed-8, dy::signed-8, wheel::signed-8, pan::signed-8>>
  end

  @doc """
  A pen report: whether the tip touches, whether the pen is in range, and
  where, from 0 to 32767. The tip presses fully.

      iex> NanoKVM.HID.Report.stylus(true, true, 100, 200)
      <<2, 0b11, 100, 0, 200, 0, 255>>
  """
  @spec stylus(boolean(), boolean(), 0..32_767, 0..32_767) :: <<_::56>>
  def stylus(tip, in_range, x, y) do
    bits = if(tip, do: 1, else: 0) ||| if(in_range, do: 2, else: 0)
    <<2, bits, x::little-16, y::little-16, if(tip, do: 255, else: 0)>>
  end

  @doc """
  A touch screen report: the contacts touching, up to ten.

      iex> report = NanoKVM.HID.Report.touch([{0, 1, 2}])
      iex> {byte_size(report), binary_part(report, 0, 7), :binary.last(report)}
      {62, <<3, 0b11, 0, 1, 0, 2, 0>>, 1}
  """
  @spec touch([contact()]) :: <<_::496>>
  def touch(contacts) when length(contacts) <= @max_contacts do
    touching = for {id, x, y} <- contacts, into: <<>>, do: <<0b11, id, x::little-16, y::little-16>>
    rest = :binary.copy(<<0::48>>, @max_contacts - length(contacts))
    <<3>> <> touching <> rest <> <<length(contacts)>>
  end

  @doc """
  A position across the screen, 0.0 to 1.0 (clamped), in the pointer's
  range.

      iex> NanoKVM.HID.Report.absolute(0.5)
      16384
  """
  @spec absolute(number()) :: 0..32_767
  def absolute(v), do: round(min(max(v, 0.0), 1.0) * 32_767)
end
