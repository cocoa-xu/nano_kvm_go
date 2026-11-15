defmodule NanoKVM.HID.ReportTest do
  use ExUnit.Case, async: true

  alias NanoKVM.HID.Report

  doctest Report

  test "keyboard reports have eight bytes" do
    assert Report.keyboard(0, []) == <<0::64>>
    assert Report.keyboard(0x05, [4, 5, 6, 7, 8, 9]) == <<5, 0, 4, 5, 6, 7, 8, 9>>
  end

  test "mouse reports have seven bytes and clamp the position" do
    assert Report.mouse(31, 32_767, 32_767, 1, -1) == <<31, 0xFF, 0x7F, 0xFF, 0x7F, 1, 0xFF>>
    assert Report.absolute(-1) == 0
    assert Report.absolute(2) == 32_767
  end

  test "pen and touch reports" do
    assert Report.stylus(false, true, 1, 2) == <<2, 0b10, 1, 0, 2, 0, 0>>
    assert Report.touch([]) == <<3>> <> <<0::480>> <> <<0>>

    report = Report.touch([{0, 10, 20}, {1, 30, 40}])

    assert <<3, 0b11, 0, 10::little-16, 20::little-16, 0b11, 1, 30::little-16, 40::little-16,
             _rest::binary-size(48), 2>> = report
  end
end
