defmodule NanoKVM.USBTest do
  use ExUnit.Case, async: true

  alias NanoKVM.FakeConfigfs

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
    assert FakeConfigfs.read(gadget, "functions/hid.mouse/report_length") == "6"
    assert FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.0/removable") == "1"

    assert File.read_link!(Path.join(gadget, "configs/c.1/hid.keyboard")) ==
             Path.join(gadget, "functions/hid.keyboard")

    assert File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
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
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_chmask") == "1"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_chmask") == "3"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_srate") == "48000"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_ssize") == "2"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_sync") == "adaptive"

    assert File.read_link!(Path.join(gadget, "configs/c.1/uac2.audio")) ==
             Path.join(gadget, "functions/uac2.audio")
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
    File.write!(Path.join(dir, "c_chmask"), "0\n")
    # A rebind would rewrite the controller's name.
    File.write!(Path.join(gadget, "UDC"), "untouched")

    pid =
      start_supervised!(
        {NanoKVM.USB, functions: [:microphone], gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert NanoKVM.USB.functions(pid) == [:microphone]
    assert FakeConfigfs.read(gadget, "UDC") == "untouched"
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
    assert NanoKVM.USB.configure(pid, [:camera]) == {:error, {:unknown_functions, [:camera]}}

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
