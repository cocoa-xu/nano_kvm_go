defmodule NanoKVMGo.BacklightTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Backlight

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
    {[backlight: backlight], backlight, device}
  end

  test "brightness and power", %{tmp_dir: tmp_dir} do
    {opts, backlight, _device} = fake(tmp_dir)
    File.write!(Path.join(backlight, "max_brightness"), "200")

    assert :ok = Backlight.set_brightness(40, opts)
    assert File.read!(Path.join(backlight, "brightness")) == "80"
    assert Backlight.brightness(opts) == {:ok, 40}

    assert :ok = Backlight.off(opts)
    assert File.read!(Path.join(backlight, "bl_power")) == "4"
    assert {:ok, %{on: false, brightness: 40}} = Backlight.info(opts)

    assert :ok = Backlight.on(opts)
    assert File.read!(Path.join(backlight, "bl_power")) == "0"
  end

  test "a frequency of your own, then the device tree's", %{tmp_dir: tmp_dir} do
    {opts, _backlight, device} = fake(tmp_dir)

    assert :ok = Backlight.set_frequency(100_000, opts)
    assert File.read!(Path.join(device, "pwm_period_ns")) == "10000"

    assert Backlight.info(opts) ==
             {:ok,
              %{
                on: true,
                brightness: 100,
                period: 10_000,
                frequency: 100_000.0,
                default_period: 40_000
              }}

    assert :ok = Backlight.set_frequency(2160, opts)
    assert File.read!(Path.join(device, "pwm_period_ns")) == "462963"

    assert :ok = Backlight.set_frequency(:default, opts)
    assert File.read!(Path.join(device, "pwm_period_ns")) == "40000"
  end

  test "refuses frequencies that make no period and brightness out of range",
       %{tmp_dir: tmp_dir} do
    {opts, _backlight, device} = fake(tmp_dir)

    for hz <- [0, -5, 1.0e12, "fast", nil] do
      assert_raise FunctionClauseError, fn -> Backlight.set_frequency(hz, opts) end
    end

    assert_raise FunctionClauseError, fn -> Backlight.set_brightness(101, opts) end
    assert_raise ArgumentError, fn -> Backlight.on(backlite: "/sys") end
    assert File.read!(Path.join(device, "pwm_period_ns")) == "40000\n"
  end

  test "a kernel without the period attribute", %{tmp_dir: tmp_dir} do
    {opts, _backlight, device} = fake(tmp_dir)
    File.rm_rf!(device)

    assert Backlight.set_frequency(25_000, opts) == {:error, :enoent}
    assert Backlight.set_frequency(:default, opts) == {:error, :no_default_period}

    assert {:ok, %{on: true, brightness: 100, period: nil, frequency: nil, default_period: nil}} =
             Backlight.info(opts)
  end
end
