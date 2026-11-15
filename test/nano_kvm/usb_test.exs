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
    assert :ok = NanoKVM.USB.validate([{:speaker, channels: 8, rates: [192_000], sample_bits: 24}])

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

  @tag capture_log: true
  test "runs on without a gadget", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing")
    pid = start_supervised!({NanoKVM.USB, functions: [:storage], gadget: missing, name: nil})

    assert NanoKVM.USB.functions(pid) == []
    assert NanoKVM.USB.configure(pid, [:storage]) == {:error, {:no_gadget, missing}}
  end
end
