defmodule NanoKVMGo.Bluetooth.HIDTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Bluetooth.HID

  # Boot keyboard: Usage Page (Generic Desktop), Usage (Keyboard),
  # Collection (Application) ... End Collection
  @keyboard <<0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0xC0>>

  test "a report ID goes right after the application collection" do
    assert HID.with_report_id(@keyboard, 3) ==
             <<0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x03, 0x05, 0x07, 0xC0>>
  end

  test "only the first application collection gets it" do
    twice = @keyboard <> @keyboard
    assert HID.with_report_id(twice, 1) == HID.with_report_id(@keyboard, 1) <> @keyboard
  end

  test "a descriptor without an application collection is refused" do
    assert_raise ArgumentError, fn -> HID.with_report_id(<<0x05, 0x01, 0xC0>>, 1) end
  end
end
