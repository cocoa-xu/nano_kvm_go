defmodule NanoKVM.BacklightTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Backlight

  @moduletag :tmp_dir

  # The backlight's class directory and its device: the PWM period and the
  # device tree's pwms, PWM1 channel 2 at 25 kHz.
  defp fake(tmp_dir) do
    backlight = Path.join(tmp_dir, "backlight")
    device = Path.join(backlight, "device")
    File.mkdir_p!(Path.join(device, "of_node"))

    for {file, value} <- [{"brightness", "100"}, {"max_brightness", "100"}, {"bl_power", "0"}],
        do: File.write!(Path.join(backlight, file), value)

    File.write!(Path.join(device, "pwm_period_ns"), "40000\n")
    File.write!(Path.join([device, "of_node", "pwms"]), <<1::32, 2::32, 40_000::32, 0::32>>)
    {[backlight: backlight, name: nil], backlight, device}
  end

  test "brightness and power", %{tmp_dir: tmp_dir} do
    {opts, backlight, _device} = fake(tmp_dir)
    File.write!(Path.join(backlight, "max_brightness"), "200")
    pid = start_supervised!({Backlight, opts})

    assert :ok = Backlight.set_brightness(pid, 40)
    assert File.read!(Path.join(backlight, "brightness")) == "80"
    assert Backlight.brightness(pid) == {:ok, 40}

    assert :ok = Backlight.off(pid)
    assert File.read!(Path.join(backlight, "bl_power")) == "4"
    assert {:ok, %{on: false, brightness: 40}} = Backlight.info(pid)

    assert :ok = Backlight.on(pid)
    assert File.read!(Path.join(backlight, "bl_power")) == "0"
  end

  test "a frequency of your own, then the device tree's", %{tmp_dir: tmp_dir} do
    {opts, _backlight, device} = fake(tmp_dir)
    pid = start_supervised!({Backlight, opts})

    assert :ok = Backlight.set_frequency(pid, 100_000)
    assert File.read!(Path.join(device, "pwm_period_ns")) == "10000"

    assert Backlight.info(pid) ==
             {:ok,
              %{
                on: true,
                brightness: 100,
                period: 10_000,
                frequency: 100_000.0,
                default_period: 40_000
              }}

    assert :ok = Backlight.set_frequency(pid, 2160)
    assert File.read!(Path.join(device, "pwm_period_ns")) == "462963"

    assert :ok = Backlight.set_frequency(pid, :default)
    assert File.read!(Path.join(device, "pwm_period_ns")) == "40000"
  end

  test "refuses frequencies that make no period", %{tmp_dir: tmp_dir} do
    {opts, _backlight, device} = fake(tmp_dir)
    pid = start_supervised!({Backlight, opts})

    for hz <- [0, -5, 1.0e12, "fast", nil] do
      assert Backlight.set_frequency(pid, hz) == {:error, :invalid_frequency}
    end

    assert File.read!(Path.join(device, "pwm_period_ns")) == "40000\n"
  end

  test "a kernel without the period attribute", %{tmp_dir: tmp_dir} do
    {opts, _backlight, device} = fake(tmp_dir)
    File.rm_rf!(device)
    pid = start_supervised!({Backlight, opts})

    assert Backlight.set_frequency(pid, 25_000) == {:error, :enoent}
    assert Backlight.set_frequency(pid, :default) == {:error, :no_default_period}

    assert {:ok, %{on: true, brightness: 100, period: nil, frequency: nil, default_period: nil}} =
             Backlight.info(pid)
  end
end
