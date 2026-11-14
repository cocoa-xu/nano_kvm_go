defmodule NanoKVM.FakeConfigfs do
  @moduledoc false
  # A gadget directory on a plain file system, bound to the device controller
  # "udc.0", and the directory that lists the controllers.

  @spec gadget(Path.t()) :: %{gadget: Path.t(), udc_class: Path.t()}
  def gadget(tmp) do
    gadget = Path.join(tmp, "gadget")
    udc_class = Path.join(tmp, "udc")
    File.mkdir_p!(Path.join(gadget, "configs/c.1"))
    File.mkdir_p!(Path.join(gadget, "functions/ncm.usb0"))
    File.ln_s!(Path.join(gadget, "functions/ncm.usb0"), Path.join(gadget, "configs/c.1/ncm.usb0"))
    File.write!(Path.join(gadget, "UDC"), "udc.0\n")
    File.mkdir_p!(Path.join(udc_class, "udc.0"))
    %{gadget: gadget, udc_class: udc_class}
  end

  @spec read(Path.t(), Path.t()) :: String.t()
  def read(gadget, path), do: File.read!(Path.join(gadget, path))
end
