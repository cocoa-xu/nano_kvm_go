defmodule NanoKVM.HID.Descriptor do
  @moduledoc false
  # The HID functions NanoKVM.USB creates. The reports are NanoKVM.HID.Report.

  @type t() :: %{
          protocol: 0..2,
          subclass: 0..1,
          report_length: pos_integer(),
          report_desc: binary()
        }

  @type pointer_mode() :: NanoKVM.HID.pointer_mode()

  # Boot keyboard: modifiers, reserved, 6 keys of usages 0..0xE7 (the
  # logical maximum in two bytes: one would read as negative); LED output.
  @keyboard Base.decode16!(
              "05010906A101050719E029E715002501750195088102950175088103" <>
                "95057501050819012905910295017503910395067508150026E700" <>
                "0507190029E78100C0"
            )

  # Buttons 1 to 5 (left, right, middle, back, forward) and padding, then
  # the axes, the wheel and the horizontal wheel (AC Pan).
  @buttons "05091901290515002501950575018102950175038103"
  @pan "050C0A38021581257F750895018106"

  # Relative boot mouse: X, Y and the wheel from -127 to 127.
  @relative_mouse Base.decode16!(
                    "05010902A1010901A100" <>
                      @buttons <>
                      "05010930093109381581257F750895038106" <> @pan <> "C0C0"
                  )

  # Absolute mouse: X and Y from 0 to 32767, a relative wheel.
  @mouse Base.decode16!(
           "05010902A1010901A100" <>
             @buttons <>
             "050109300931150026FF7F751095028102" <>
             "0938158125" <> "7F750895018106" <> @pan <> "C0C0"
         )

  # Pen (stock firmware's "digitizer-stylus", for Android and iPadOS):
  # report 2, tip and in range, X and Y from 0 to 32767, pressure.
  @stylus Base.decode16!(
            "050D0905A10185020920A100050D0942093215002501750195028102" <>
              "75069501810305010930093116000026FF7F751095028102" <>
              "050D0930150026FF00750895018102C0C0"
          )

  # Touch screen (stock firmware's "touch-screen"): report 3 with ten
  # contacts (tip, confidence, id, X, Y) and the contact count; feature
  # report 4, the most contacts.
  @contact "050D0922A10209420947150025017501950281027506950181037508" <>
             "250A0951950181020501150026FF7F751095010930810209318102C0"
  @touch Base.decode16!(
           "050D0904A1018503" <>
             String.duplicate(@contact, 10) <>
             "050D1500250A750895010954810285040955B102C0"
         )

  @spec keyboard() :: t()
  def keyboard, do: %{protocol: 1, subclass: 1, report_length: 8, report_desc: @keyboard}

  @spec relative_mouse() :: t()
  def relative_mouse,
    do: %{protocol: 2, subclass: 1, report_length: 5, report_desc: @relative_mouse}

  @spec mouse(pointer_mode()) :: t()
  def mouse(:absolute), do: %{protocol: 2, subclass: 0, report_length: 7, report_desc: @mouse}
  def mouse(:stylus), do: %{protocol: 0, subclass: 0, report_length: 7, report_desc: @stylus}
  def mouse(:touch), do: %{protocol: 0, subclass: 0, report_length: 62, report_desc: @touch}

  @doc "The pointer mode of a report descriptor, `nil` for another one."
  @spec pointer_mode(binary()) :: pointer_mode() | nil
  def pointer_mode(@mouse), do: :absolute
  def pointer_mode(@stylus), do: :stylus
  def pointer_mode(@touch), do: :touch
  def pointer_mode(_report_desc), do: nil
end
