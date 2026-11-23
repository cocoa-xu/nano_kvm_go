defmodule NanoKVMGo.ThermalTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Thermal

  @moduletag :tmp_dir

  defp zone(root, name, type, temp) do
    dir = Path.join([root, "sys/class/thermal", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "type"), type <> "\n")
    if temp, do: File.write!(Path.join(dir, "temp"), temp)
  end

  test "reads the SoC thermal zone", %{tmp_dir: tmp_dir} do
    zone(tmp_dir, "thermal_zone0", "cpu-thermal", "90000\n")
    zone(tmp_dir, "thermal_zone1", "soc-thermal", "51234\n")

    assert Thermal.temperature(tmp_dir) == {:ok, 51.234}
  end

  test "reports a missing or broken sensor", %{tmp_dir: tmp_dir} do
    assert Thermal.temperature(tmp_dir) == {:error, :no_sensor}

    zone(tmp_dir, "thermal_zone0", "soc-thermal", "hot\n")
    assert Thermal.temperature(tmp_dir) == {:error, :invalid_temperature}

    File.rm!(Path.join([tmp_dir, "sys/class/thermal/thermal_zone0/temp"]))
    assert Thermal.temperature(tmp_dir) == {:error, :enoent}
  end
end
