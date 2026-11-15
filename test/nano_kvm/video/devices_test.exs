defmodule NanoKVM.Video.DevicesTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Video.Devices

  @moduletag :tmp_dir

  test "finds a video device by the name of its driver", %{tmp_dir: tmp_dir} do
    for {node, name} <- [{"video0", "other"}, {"video1", "ax620e-vin"}, {"video2", "ax620e-vin"}] do
      File.mkdir_p!(Path.join(tmp_dir, node))
      File.write!(Path.join([tmp_dir, node, "name"]), name <> "\n")
    end

    assert Devices.find("ax620e-vin", tmp_dir) == "/dev/video1"
    assert Devices.find("missing", tmp_dir) == nil
    assert Devices.find("ax620e-vin", Path.join(tmp_dir, "none")) == nil
  end

  test "the sysfs directory of a device node" do
    assert Devices.sysfs_dir("/dev/video3") == "/sys/class/video4linux/video3/device"
  end
end
