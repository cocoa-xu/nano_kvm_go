defmodule NanoKVMGo.USBTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.FakeKV
  alias NanoKVMGo.USB

  doctest USB

  test "the gadget's options for this board" do
    opts = USB.gadget_options(serial_number: "6a1a78455040f186")

    assert opts[:gadget] == "/sys/kernel/config/usb_gadget/nanokvm"
    assert opts[:max_packet] == %{microphone: 832, speaker: 682}
    assert opts[:names][:storage] == {"NanoKVM", "Virtual Media", "0100"}
    assert opts[:network][:function] == "ncm.usb0"

    assert opts[:network][:default_addresses] ==
             %{device_address: "ea:52:ab:b6:67:a7", host_address: "2e:53:95:27:a5:9d"}

    assert USB.gadget_options(serial_number: nil)[:network][:default_addresses] == nil
  end

  test "keeps the network addresses in the U-Boot environment" do
    Process.register(self(), FakeKV)
    persist = USB.gadget_options(serial_number: nil, kv: FakeKV)[:network][:persist]

    assert :ok = persist.(%{host_address: "02:12:34:56:78:9a"})
    assert_received {FakeKV, %{"usbnet_hostaddr" => "02:12:34:56:78:9a"} = put}
    refute Map.has_key?(put, "usbnet_devaddr")

    assert :ok = USB.keep_network_addresses(%{device_address: :default}, FakeKV)
    assert_received {FakeKV, %{"usbnet_devaddr" => ""}}

    assert USB.keep_network_addresses(%{host_address: :default}, NoSuchKV) ==
             {:error, {:undefined, NoSuchKV}}
  end
end
