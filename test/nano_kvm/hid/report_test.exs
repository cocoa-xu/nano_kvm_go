defmodule NanoKVM.HID.ReportTest do
  use ExUnit.Case, async: true

  alias NanoKVM.HID.Report

  doctest Report

  test "keyboard reports have eight bytes" do
    assert Report.keyboard(0, []) == <<0::64>>
    assert Report.keyboard(0x05, [4, 5, 6, 7, 8, 9]) == <<5, 0, 4, 5, 6, 7, 8, 9>>
  end

  test "mouse reports have six bytes and clamp the position" do
    assert Report.mouse(7, 32_767, 32_767, 1) == <<7, 0xFF, 0x7F, 0xFF, 0x7F, 1>>
    assert Report.absolute(-1) == 0
    assert Report.absolute(2) == 32_767
  end
end
