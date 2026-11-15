defmodule NanoKVM.USBTest do
  use ExUnit.Case, async: true

  alias NanoKVM.FakeConfigfs

  doctest NanoKVM.USB

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir}, do: FakeConfigfs.gadget(tmp_dir)

  test "adds the functions and binds the gadget again", %{gadget: gadget, udc_class: udc_class} do
    File.write!(Path.join(gadget, "UDC"), "")

    pid =
      start_supervised!(
        {NanoKVM.USB,
         functions: [:storage, :keyboard, :mouse], gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert NanoKVM.USB.functions(pid) == [:keyboard, :mouse, :storage]
    assert FakeConfigfs.read(gadget, "UDC") == "udc.0"

    assert FakeConfigfs.read(gadget, "functions/hid.keyboard/protocol") == "1"
    assert FakeConfigfs.read(gadget, "functions/hid.keyboard/report_length") == "8"
    assert FakeConfigfs.read(gadget, "functions/hid.mouse/protocol") == "2"
    assert FakeConfigfs.read(gadget, "functions/hid.mouse/report_length") == "7"
    assert FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.0/removable") == "1"

    assert File.read_link!(Path.join(gadget, "configs/c.1/hid.keyboard")) ==
             Path.join(gadget, "functions/hid.keyboard")

    assert File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
  end

  test "sets up the pointer in its mode and the relative mouse", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid = start_supervised!({NanoKVM.USB, gadget: gadget, udc_class: udc_class, name: nil})

    assert :ok = NanoKVM.USB.configure(pid, [{:mouse, mode: :touch}, :relative_mouse])
    assert NanoKVM.USB.functions(pid) == [:mouse, :relative_mouse]
    assert FakeConfigfs.read(gadget, "functions/hid.mouse/report_length") == "62"
    assert FakeConfigfs.read(gadget, "functions/hid.relative_mouse/subclass") == "1"
    assert FakeConfigfs.read(gadget, "functions/hid.relative_mouse/report_length") == "5"
    assert NanoKVM.USB.hid_device(:relative_mouse, gadget: gadget) == {:error, :enoent}

    # The mode is read back from the report descriptor.
    File.write!(Path.join(gadget, "UDC"), "untouched")
    assert :ok = NanoKVM.USB.configure(pid, [:relative_mouse, {:mouse, mode: :touch}])
    assert FakeConfigfs.read(gadget, "UDC") == "untouched"

    assert {:error, {:invalid_mode, :mouse, :tablet}} =
             NanoKVM.USB.configure(pid, [{:mouse, mode: :tablet}])
  end

  test "leaves the gadget alone when nothing changes", %{gadget: gadget, udc_class: udc_class} do
    pid = start_supervised!({NanoKVM.USB, gadget: gadget, udc_class: udc_class, name: nil})
    assert :ok = NanoKVM.USB.configure(pid, [:storage])

    # A rebind would rewrite the controller's name.
    File.write!(Path.join(gadget, "UDC"), "untouched")
    assert :ok = NanoKVM.USB.configure(pid, [:storage])
    assert FakeConfigfs.read(gadget, "UDC") == "untouched"
  end

  test "removes the functions not asked for", %{gadget: gadget, udc_class: udc_class} do
    # configfs removes attributes with their function: here only empty ones go.
    File.mkdir_p!(Path.join(gadget, "functions/hid.mouse"))

    File.ln_s!(
      Path.join(gadget, "functions/hid.mouse"),
      Path.join(gadget, "configs/c.1/hid.mouse")
    )

    pid = start_supervised!({NanoKVM.USB, gadget: gadget, udc_class: udc_class, name: nil})

    assert NanoKVM.USB.functions(pid) == []
    refute File.exists?(Path.join(gadget, "functions/hid.mouse"))
    assert File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
  end

  test "sets up the microphone and the speaker as one audio function", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid =
      start_supervised!(
        {NanoKVM.USB,
         functions: [:speaker, :microphone], gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert NanoKVM.USB.functions(pid) == [:microphone, :speaker]
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_chmask") == "3"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_chmask") == "3"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_srate") == "48000"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_ssize") == "2"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_sync") == "adaptive"

    assert File.read_link!(Path.join(gadget, "configs/c.1/uac2.audio")) ==
             Path.join(gadget, "functions/uac2.audio")
  end

  test "names the audio directions where the kernel takes names", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    # A kernel with the attributes; configfs makes them with the function.
    dir = Path.join(gadget, "functions/uac2.audio")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "c_alt0_name"), "Playback Inactive\n")
    File.write!(Path.join(dir, "int_ep_present"), "1\n")

    start_supervised!(
      {NanoKVM.USB, functions: [:speaker], gadget: gadget, udc_class: udc_class, name: nil}
    )

    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_alt0_name") == "NanoKVM-Go Speaker"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/int_ep_present") == "0"
    refute File.exists?(Path.join(dir, "p_alt0_name"))
  end

  test "a microphone alone leaves the speaker direction out", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid =
      start_supervised!(
        {NanoKVM.USB, functions: [:microphone], gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert NanoKVM.USB.functions(pid) == [:microphone]
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_chmask") == "0"
  end

  test "tells the audio directions from the function's channel masks", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    dir = Path.join(gadget, "functions/uac2.audio")
    File.mkdir_p!(dir)
    File.ln_s!(dir, Path.join(gadget, "configs/c.1/uac2.audio"))
    File.write!(Path.join(dir, "p_chmask"), "1\n")
    File.write!(Path.join(dir, "p_srate"), "44100,48000\n")
    File.write!(Path.join(dir, "p_ssize"), "2\n")
    File.write!(Path.join(dir, "c_chmask"), "0\n")
    # A rebind would rewrite the controller's name.
    File.write!(Path.join(gadget, "UDC"), "untouched")

    pid =
      start_supervised!(
        {NanoKVM.USB,
         functions: [{:microphone, channels: 1, rates: [48_000, 44_100]}],
         gadget: gadget,
         udc_class: udc_class,
         name: nil}
      )

    assert NanoKVM.USB.functions(pid) == [:microphone]

    assert NanoKVM.USB.audio(pid) == %{
             microphone: %{channels: 1, rates: [44_100, 48_000], sample_bits: 16}
           }

    assert FakeConfigfs.read(gadget, "UDC") == "untouched"
  end

  test "sets up the formats of the audio directions", %{gadget: gadget, udc_class: udc_class} do
    pid = start_supervised!({NanoKVM.USB, gadget: gadget, udc_class: udc_class, name: nil})

    assert :ok =
             NanoKVM.USB.configure(pid, [
               {:microphone, channels: 1, rates: [48_000, 44_100, 96_000], sample_bits: 24},
               {:speaker, rates: [192_000], sample_bits: 32}
             ])

    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_chmask") == "1"
    # The target starts with the first rate.
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_srate") == "48000,44100,96000"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_ssize") == "3"
    # 97 frames of 3 bytes a millisecond fit a packet.
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_hs_bint") == "4"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_chmask") == "3"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_srate") == "192000"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_ssize") == "4"
    # 97 frames of 8 bytes each 500 µs do not, 49 each 250 µs do.
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_hs_bint") == "2"

    assert NanoKVM.USB.audio(pid) == %{
             microphone: %{channels: 1, rates: [48_000, 44_100, 96_000], sample_bits: 24},
             speaker: %{channels: 2, rates: [192_000], sample_bits: 32}
           }
  end

  test "leaves the audio function alone in the same format", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid =
      start_supervised!(
        {NanoKVM.USB, functions: [:microphone], gadget: gadget, udc_class: udc_class, name: nil}
      )

    File.write!(Path.join(gadget, "UDC"), "untouched")
    assert :ok = NanoKVM.USB.configure(pid, [{:microphone, channels: 2, rates: [48_000]}])
    assert FakeConfigfs.read(gadget, "UDC") == "untouched"
  end

  test "refuses formats the USB audio function cannot have", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid = start_supervised!({NanoKVM.USB, gadget: gadget, udc_class: udc_class, name: nil})
    configure = &NanoKVM.USB.configure(pid, [&1])

    assert {:error, {:invalid_channels, :microphone, 9}} = configure.({:microphone, channels: 9})
    assert {:error, {:invalid_rates, :speaker, []}} = configure.({:speaker, rates: []})

    assert {:error, {:invalid_rates, :speaker, _rates}} =
             configure.({:speaker, rates: Enum.map(1..11, &(&1 * 8_000))})

    assert {:error, {:invalid_rates, :speaker, [1_000]}} = configure.({:speaker, rates: [1_000]})

    assert {:error, {:invalid_sample_bits, :speaker, 20}} =
             configure.({:speaker, sample_bits: 20})

    # 8 channels of 32 bits at 384 kHz: 49 frames of 32 bytes each 125 µs.
    assert {:error, {:too_much_bandwidth, :speaker, _format}} =
             configure.({:speaker, channels: 8, rates: [384_000], sample_bits: 32})

    # 7.1 of 24 bits at 192 kHz: 25 frames of 24 bytes each 125 µs fit 682.
    assert :ok =
             NanoKVM.USB.validate([{:speaker, channels: 8, rates: [192_000], sample_bits: 24}])

    assert :ok = configure.({:speaker, channels: 2, rates: [384_000], sample_bits: 32})

    assert {:error, {:unknown_options, :microphone, [:volume]}} =
             configure.({:microphone, volume: 3})

    assert {:error, {:duplicate_function, :microphone}} =
             NanoKVM.USB.configure(pid, [:microphone, {:microphone, channels: 1}])
  end

  test "goes back to the functions it had when the controller refuses", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid = start_supervised!({NanoKVM.USB, gadget: gadget, udc_class: udc_class, name: nil})

    # Binding fails: the controller name cannot be written.
    File.rm!(Path.join(gadget, "UDC"))
    File.mkdir!(Path.join(gadget, "UDC"))

    assert {:error, :eisdir} = NanoKVM.USB.configure(pid, [:microphone])
    assert NanoKVM.USB.functions(pid) == []
    refute File.exists?(Path.join(gadget, "configs/c.1/uac2.audio"))
  end

  test "refuses unknown functions", %{gadget: gadget, udc_class: udc_class} do
    pid = start_supervised!({NanoKVM.USB, gadget: gadget, udc_class: udc_class, name: nil})
    assert NanoKVM.USB.configure(pid, [:camera]) == {:error, {:unknown_function, :camera}}

    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{}, _stack}} =
             NanoKVM.USB.start_link(functions: [:camera], gadget: gadget, name: nil)
  end

  test "tells the state of the connection to the target", %{gadget: gadget, udc_class: udc_class} do
    opts = [gadget: gadget, udc_class: udc_class]
    udc = Path.join(udc_class, "udc.0")
    File.write!(Path.join(udc, "state"), "configured\n")
    File.write!(Path.join(udc, "current_speed"), "high-speed\n")

    assert NanoKVM.USB.connection(opts) ==
             {:ok, %{state: :configured, speed: :high_speed, controller: "udc.0"}}

    File.write!(Path.join(udc, "state"), "not attached\n")
    File.write!(Path.join(udc, "current_speed"), "UNKNOWN\n")
    assert {:ok, %{state: :not_attached, speed: :unknown}} = NanoKVM.USB.connection(opts)

    File.write!(Path.join(gadget, "UDC"), "\n")
    assert NanoKVM.USB.connection(opts) == {:error, :no_udc}
  end

  describe "the network" do
    @serial "6a1a78455040f186"
    @device "ea:52:ab:b6:67:a7"
    @host "2e:53:95:27:a5:9d"

    # As the NanoKVM-Go system leaves it, with the KVM functions linked after.
    setup %{gadget: gadget} do
      ncm = Path.join(gadget, "functions/ncm.usb0")
      File.write!(Path.join(ncm, "dev_addr"), @device <> "\0\n")
      File.write!(Path.join(ncm, "host_addr"), @host <> "\0\n")
      File.write!(Path.join(ncm, "ifname"), "usb0\n")
      File.write!(Path.join(ncm, "qmult"), "5\n")
      Process.register(self(), NanoKVM.FakeKV)
      %{ncm: ncm}
    end

    defp start_usb(context, opts \\ []) do
      opts =
        Keyword.merge(
          [
            functions: [:keyboard, :storage],
            gadget: context.gadget,
            udc_class: context.udc_class,
            serial_number: @serial,
            kv: NanoKVM.FakeKV,
            name: nil
          ],
          opts
        )

      start_supervised!({NanoKVM.USB, opts}, id: make_ref())
    end

    test "tells the addresses and those by default", context do
      pid = start_usb(context)

      assert NanoKVM.USB.network(pid) ==
               {:ok,
                %{
                  interface: "usb0",
                  device_address: @device,
                  host_address: @host,
                  default_addresses: %{device_address: @device, host_address: @host}
                }}

      File.write!(Path.join(context.ncm, "ifname"), "(unnamed net_device)\n")
      assert {:ok, %{interface: nil}} = NanoKVM.USB.network(pid)

      pid = start_usb(context, serial_number: nil)
      assert {:ok, %{default_addresses: nil}} = NanoKVM.USB.network(pid)

      assert NanoKVM.USB.set_network_addresses(pid, host_address: :default) ==
               {:error, :no_default_addresses}
    end

    test "gives the target computer's end another address", context do
      pid = start_usb(context)
      File.write!(Path.join(context.gadget, "UDC"), "")

      assert :ok = NanoKVM.USB.set_network_addresses(pid, host_address: "02:12:34:56:78:9A")

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/host_addr") ==
               "02:12:34:56:78:9a"

      # The NanoKVM's interface stays: the function is the same.
      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/ifname") == "usb0\n"
      assert FakeConfigfs.read(context.gadget, "UDC") == "udc.0"

      for function <- ["ncm.usb0", "hid.keyboard", "mass_storage.disk"] do
        assert File.read_link!(Path.join(context.gadget, "configs/c.1/#{function}")) ==
                 Path.join(context.gadget, "functions/#{function}")
      end

      assert_received {NanoKVM.FakeKV, %{"usbnet_hostaddr" => "02:12:34:56:78:9a"} = put}
      refute Map.has_key?(put, "usbnet_devaddr")
    end

    test "gives the NanoKVM's end another address with a new function", context do
      # configfs takes the attributes away with the function.
      rmdir = fn dir ->
        File.rm_rf!(dir)
        :ok
      end

      pid = start_usb(context, rmdir: rmdir)

      assert :ok =
               NanoKVM.USB.set_network_addresses(pid,
                 device_address: "06-AA-BB-CC-DD-EE",
                 host_address: :default
               )

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/dev_addr") ==
               "06:aa:bb:cc:dd:ee"

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/host_addr") == @host
      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/qmult") == "5"
      refute File.exists?(Path.join(context.gadget, "functions/ncm.usb0/ifname"))
      assert File.exists?(Path.join(context.gadget, "configs/c.1/ncm.usb0"))

      assert_received {NanoKVM.FakeKV,
                       %{"usbnet_devaddr" => "06:aa:bb:cc:dd:ee", "usbnet_hostaddr" => ""}}
    end

    test "keeps the addresses that are there", context do
      pid = start_usb(context)
      File.write!(Path.join(context.gadget, "UDC"), "untouched")

      assert :ok =
               NanoKVM.USB.set_network_addresses(pid,
                 device_address: :default,
                 host_address: String.upcase(@host)
               )

      assert FakeConfigfs.read(context.gadget, "UDC") == "untouched"
      assert_received {NanoKVM.FakeKV, %{"usbnet_devaddr" => "", "usbnet_hostaddr" => @host}}

      assert :ok = NanoKVM.USB.set_network_addresses(pid, host_address: @host, persist: false)
      refute_received {NanoKVM.FakeKV, _put}
    end

    test "refuses what is not a unicast address of its own", context do
      pid = start_usb(context)
      set = &NanoKVM.USB.validate_network_addresses(pid, &1)

      assert set.(host_address: "02:12:34:56:78") ==
               {:error, {:invalid_address, :host_address, "02:12:34:56:78"}}

      assert set.(host_address: "02:12:34:56:78:9g") ==
               {:error, {:invalid_address, :host_address, "02:12:34:56:78:9g"}}

      assert set.(device_address: "00:00:00:00:00:00") ==
               {:error, {:invalid_address, :device_address, "00:00:00:00:00:00"}}

      assert set.(device_address: "01:00:5e:00:00:fb") ==
               {:error, {:multicast_address, :device_address, "01:00:5e:00:00:fb"}}

      assert set.(device_address: nil) == {:error, {:invalid_address, :device_address, nil}}
      assert set.(host_address: @device) == {:error, :same_addresses}
      assert set.(mac: @device) == {:error, {:unknown_options, [:mac]}}
      assert set.(persist: "yes") == {:error, {:invalid_persist, "yes"}}

      assert set.([{"host_address", @device}]) ==
               {:error, {:invalid_settings, [{"host_address", @device}]}}

      assert set.(device_address: @host, host_address: @device) == :ok

      File.write!(Path.join(context.gadget, "UDC"), "untouched")

      assert {:error, :same_addresses} =
               NanoKVM.USB.set_network_addresses(pid, host_address: @device)

      assert FakeConfigfs.read(context.gadget, "UDC") == "untouched"
      refute_received {NanoKVM.FakeKV, _put}
    end

    @tag capture_log: true
    test "connects the functions again when the new function fails", context do
      # A plain directory with attributes cannot go.
      pid = start_usb(context)
      File.write!(Path.join(context.gadget, "UDC"), "")

      assert {:error, _reason} =
               NanoKVM.USB.set_network_addresses(pid, device_address: "02:00:00:00:00:01")

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/dev_addr") == @device <> "\0\n"
      assert FakeConfigfs.read(context.gadget, "UDC") == "udc.0"

      for function <- ["ncm.usb0", "hid.keyboard", "mass_storage.disk"] do
        assert File.exists?(Path.join(context.gadget, "configs/c.1/#{function}"))
      end

      refute_received {NanoKVM.FakeKV, _put}
    end
  end

  @tag capture_log: true
  test "runs on without a gadget", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing")
    pid = start_supervised!({NanoKVM.USB, functions: [:storage], gadget: missing, name: nil})

    assert NanoKVM.USB.functions(pid) == []
    assert NanoKVM.USB.configure(pid, [:storage]) == {:error, {:no_gadget, missing}}
  end
end
