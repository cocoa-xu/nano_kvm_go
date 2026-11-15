defmodule NanoKVM.BacklightTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Backlight

  @moduletag :tmp_dir

  # The backlight's class directory, pwm-backlight's driver directory, and a
  # PWM chip whose channel 2 is already exported (writes cannot export here).
  defp fake(tmp_dir, pwm2 \\ %{"period" => "0", "duty_cycle" => "0", "enable" => "0"}) do
    backlight = Path.join(tmp_dir, "backlight")
    driver = Path.join(tmp_dir, "pwm-backlight")
    chip = Path.join(tmp_dir, "pwmchip0")

    for dir <- [backlight, driver, Path.join(chip, "pwm2")], do: File.mkdir_p!(dir)
    for {file, value} <- pwm2, do: File.write!(Path.join([chip, "pwm2", file]), value)

    for {file, value} <- [{"brightness", "100"}, {"max_brightness", "100"}, {"bl_power", "0"}],
        do: File.write!(Path.join(backlight, file), value)

    opts = [backlight: backlight, driver: {driver, "backlight"}, pwm: {chip, 2}, name: nil]
    {opts, backlight, driver, chip}
  end

  defp read(path), do: File.read!(path)

  test "the kernel's driver: brightness and power", %{tmp_dir: tmp_dir} do
    {opts, backlight, _driver, _chip} = fake(tmp_dir)
    File.write!(Path.join(backlight, "max_brightness"), "200")
    pid = start_supervised!({Backlight, opts})

    assert :ok = Backlight.set_brightness(pid, 40)
    assert read(Path.join(backlight, "brightness")) == "80"
    assert Backlight.brightness(pid) == {:ok, 40}

    assert :ok = Backlight.off(pid)
    assert read(Path.join(backlight, "bl_power")) == "4"
    assert Backlight.info(pid) == {:ok, %{control: :kernel, on: false, brightness: 40}}
    assert :ok = Backlight.release(pid)
  end

  test "taking the PWM keeps the brightness, on the lightness curve", %{tmp_dir: tmp_dir} do
    {opts, backlight, driver, chip} = fake(tmp_dir)
    File.write!(Path.join(backlight, "brightness"), "40")
    pid = start_supervised!({Backlight, opts})
    pwm = Path.join(chip, "pwm2")

    assert :ok = Backlight.set_pwm(pid, frequency: 25_000)
    assert read(Path.join(driver, "unbind")) == "backlight"
    assert read(Path.join(chip, "export")) == "2"
    assert read(Path.join(pwm, "period")) == "40000"
    assert read(Path.join(pwm, "duty_cycle")) == "4500"
    assert read(Path.join(pwm, "enable")) == "1"
    assert Backlight.brightness(pid) == {:ok, 40}

    assert :ok = Backlight.set_brightness(pid, 50)
    assert read(Path.join(pwm, "duty_cycle")) == "7367"

    assert :ok = Backlight.off(pid)
    assert read(Path.join(pwm, "duty_cycle")) == "0"
    assert :ok = Backlight.on(pid)
    assert read(Path.join(pwm, "duty_cycle")) == "7367"
  end

  test "a duty cycle of your own, then back to the kernel's driver", %{tmp_dir: tmp_dir} do
    {opts, backlight, driver, chip} = fake(tmp_dir)
    pid = start_supervised!({Backlight, opts})
    pwm = Path.join(chip, "pwm2")

    assert :ok = Backlight.set_pwm(pid, frequency: 200, duty: 0.5)
    assert read(Path.join(pwm, "period")) == "5000000"
    assert read(Path.join(pwm, "duty_cycle")) == "2500000"

    assert Backlight.info(pid) ==
             {:ok,
              %{
                control: :user,
                on: true,
                brightness: 76,
                frequency: 200.0,
                period: 5_000_000,
                duty: 0.5
              }}

    assert :ok = Backlight.set_pwm(pid, period: 1_000_000)
    assert read(Path.join(pwm, "duty_cycle")) == "500000"

    assert :ok = Backlight.release(pid)
    assert read(Path.join(chip, "unexport")) == "2"
    assert read(Path.join(driver, "bind")) == "backlight"
    assert read(Path.join(backlight, "brightness")) == "76"
    assert read(Path.join(backlight, "bl_power")) == "0"
    assert {:ok, %{control: :kernel}} = Backlight.info(pid)
  end

  test "a channel left exported is taken up again", %{tmp_dir: tmp_dir} do
    {opts, _backlight, _driver, _chip} =
      fake(tmp_dir, %{"period" => "40000", "duty_cycle" => "20000", "enable" => "1"})

    pid = start_supervised!({Backlight, opts})
    assert {:ok, %{control: :user, duty: 0.5, period: 40_000}} = Backlight.info(pid)
  end

  test "refuses periods the timer cannot make and duty cycles past 1", %{tmp_dir: tmp_dir} do
    {opts, _backlight, driver, _chip} = fake(tmp_dir)
    pid = start_supervised!({Backlight, opts})

    assert Backlight.set_pwm(pid, frequency: 0) == {:error, :invalid_period}
    assert Backlight.set_pwm(pid, frequency: 50_000_000) == {:error, :invalid_period}
    assert Backlight.set_pwm(pid, frequency: 1000, period: 1_000_000) == {:error, :invalid_period}
    assert Backlight.set_pwm(pid, duty: 1.5) == {:error, :invalid_duty}
    refute File.exists?(Path.join(driver, "unbind"))
  end

  test "without the PWM chip there is nothing to take", %{tmp_dir: tmp_dir} do
    {opts, _backlight, _driver, _chip} = fake(tmp_dir)
    pid = start_supervised!({Backlight, Keyword.put(opts, :pwm, {nil, 2})})
    assert Backlight.set_pwm(pid, frequency: 1000) == {:error, :no_pwm}
  end
end
