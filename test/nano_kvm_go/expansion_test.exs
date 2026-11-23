defmodule NanoKVMGo.ExpansionTest do
  # The fake GPIO lines and the kept mode are global.
  use ExUnit.Case, async: false

  alias NanoKVMGo.{Expansion, FakeGPIO, FakeKV}

  @moduletag :tmp_dir

  @modes "off uart gpio pwm pwm-gpio gpio-pwm i2c\n"

  setup %{tmp_dir: tmp_dir} do
    device = Path.join(tmp_dir, "expansion")
    File.mkdir_p!(device)
    File.write!(Path.join(device, "mode"), "off\n")
    File.write!(Path.join(device, "modes"), @modes)

    # Both channels as if exported: the fake cannot make pwmN on export.
    chip = Path.join(tmp_dir, "pwmchip0")
    for channel <- ["pwm0", "pwm1"], do: File.mkdir_p!(Path.join(chip, channel))

    start_supervised!({FakeGPIO, {%{"EXPANSION0" => 0, "EXPANSION1" => 1}, self()}})
    Process.register(self(), FakeKV)
    on_exit(fn -> Application.delete_env(:nano_kvm_go, FakeKV) end)

    opts = [name: nil, device: device, pwm_chip: chip, kv: FakeKV, gpio: FakeGPIO]
    %{device: device, chip: chip, opts: opts}
  end

  defp start(opts), do: start_supervised!({Expansion, opts})

  defp mode(device), do: File.read!(Path.join(device, "mode"))

  test "starts with what the kernel has", %{opts: opts} do
    pid = start(opts)

    assert Expansion.info(pid) ==
             {:ok,
              %{
                mode: :off,
                modes: [:off, :uart, :gpio, :pwm, :pwm_gpio, :gpio_pwm, :i2c],
                lines: [
                  %{line: 0, role: :off, gpio: nil, pwm: nil},
                  %{line: 1, role: :off, gpio: nil, pwm: nil}
                ],
                uart: "ttyS3",
                i2c: "i2c-2"
              }}
  end

  test "sets a mode and keeps it", %{opts: opts, device: device} do
    pid = start(opts)

    assert :ok = Expansion.set_mode(pid, :pwm_gpio)
    assert mode(device) == "pwm-gpio"
    assert_received {FakeKV, %{"nanokvm_expansion" => "pwm-gpio"}}

    assert :ok = Expansion.set_mode(pid, :i2c, persist: false)
    assert mode(device) == "i2c"
    refute_received {FakeKV, _}

    assert :ok = Expansion.set_mode(pid, :off)
    assert_received {FakeKV, %{"nanokvm_expansion" => ""}}
  end

  test "takes a mode alone, or the server, a mode and options", %{opts: opts, device: device} do
    start(Keyword.put(opts, :name, Expansion))

    assert :ok = Expansion.set_mode(:uart)
    assert mode(device) == "uart"
    assert_received {FakeKV, %{"nanokvm_expansion" => "uart"}}

    assert :ok = Expansion.set_mode(Expansion, :gpio, persist: false)
    assert mode(device) == "gpio"
    refute_received {FakeKV, _}

    assert_raise FunctionClauseError, fn -> Expansion.set_mode(:uart, persist: false) end
    assert_raise ArgumentError, fn -> Expansion.set_mode(Expansion, :uart, persist: :no) end
  end

  test "refuses modes the kernel does not offer", %{opts: opts, device: device} do
    File.write!(Path.join(device, "modes"), "off uart\n")
    pid = start(opts)

    assert Expansion.set_mode(pid, :i2c) == {:error, {:unknown_mode, :i2c}}
    assert_raise FunctionClauseError, fn -> Expansion.set_mode(pid, :sideways) end
    assert mode(device) == "off\n"
  end

  test "sets the kept mode when it starts", %{opts: opts, device: device} do
    Application.put_env(:nano_kvm_go, FakeKV, %{"nanokvm_expansion" => "uart"})
    pid = start(opts)

    assert {:ok, %{mode: :uart, lines: [%{role: :uart_txd}, %{role: :uart_rxd}]}} =
             Expansion.info(pid)

    assert mode(device) == "uart"
  end

  test "leaves a kept mode the kernel does not offer", %{opts: opts, device: device} do
    File.write!(Path.join(device, "modes"), "off uart\n")

    for kept <- ["i2c", "sideways"] do
      Application.put_env(:nano_kvm_go, FakeKV, %{"nanokvm_expansion" => kept})
      pid = start(opts)
      assert {:ok, %{mode: :off}} = Expansion.info(pid)
      assert mode(device) == "off\n"
      :ok = stop_supervised(Expansion)
    end
  end

  test "runs PWM lines and gives them back", %{opts: opts, chip: chip} do
    pid = start(opts)
    pwm0 = Path.join(chip, "pwm0")

    assert Expansion.set_pwm(pid, 0, 20_000_000, 1_500_000) == {:error, {:not_pwm, 0}}

    assert :ok = Expansion.set_mode(pid, :pwm_gpio)
    assert :ok = Expansion.set_pwm(pid, 0, 20_000_000, 2_050_000)
    assert File.read!(Path.join(pwm0, "period")) == "20000000"
    assert File.read!(Path.join(pwm0, "duty_cycle")) == "2050000"
    assert File.read!(Path.join(pwm0, "enable")) == "1"
    assert Expansion.set_pwm(pid, 1, 20_000_000, 0) == {:error, {:not_pwm, 1}}

    assert {:ok, %{lines: [%{role: :pwm, pwm: %{period: 20_000_000, duty_cycle: 2_050_000}}, _]}} =
             Expansion.info(pid)

    # Shorter than the duty cycle: the duty cycle goes first.
    assert :ok = Expansion.set_pwm(pid, 0, 1_000_000, 500_000)
    assert File.read!(Path.join(pwm0, "period")) == "1000000"

    assert :ok = Expansion.set_mode(pid, :off)
    assert File.read!(Path.join(pwm0, "enable")) == "0"
    assert File.read!(Path.join(chip, "unexport")) == "0"
    assert {:ok, %{lines: [%{pwm: nil}, %{pwm: nil}]}} = Expansion.info(pid)
  end

  test "gives the lines back when it stops", %{opts: opts, chip: chip} do
    pid = start(opts)
    assert :ok = Expansion.set_mode(pid, :pwm_gpio)
    assert :ok = Expansion.set_pwm(pid, 0, 20_000_000, 1_500_000)
    assert {:ok, 1} = Expansion.read(pid, 1)

    assert :ok = stop_supervised(Expansion)
    assert File.read!(Path.join([chip, "pwm0", "enable"])) == "0"
    assert File.read!(Path.join(chip, "unexport")) == "0"
    assert_received {FakeGPIO, {:close, "EXPANSION1"}}
  end

  test "reads, drives and watches GPIO lines", %{opts: opts} do
    pid = start(opts)

    assert Expansion.read(pid, 0) == {:error, {:not_gpio, 0}}

    assert :ok = Expansion.set_mode(pid, :gpio)
    assert Expansion.read(pid, 1) == {:ok, 1}
    assert_received {FakeGPIO, {:open, "EXPANSION1", :input}}

    assert :ok = Expansion.write(pid, 0, 1)
    assert_received {FakeGPIO, {:open, "EXPANSION0", :output}}
    assert_received {FakeGPIO, {:write, "EXPANSION0", 1}}

    # Line 1 was opened before: its edges start with the first subscriber.
    assert :ok = Expansion.subscribe(pid)
    assert_received {FakeGPIO, {:set_interrupts, "EXPANSION1", :both}}
    refute_received {FakeGPIO, {:set_interrupts, "EXPANSION0", _}}

    send(pid, {:circuits_gpio, "EXPANSION1", 123_456, 0})
    assert_receive {Expansion, {:edge, 1, 0, 123_456}}

    assert {:ok,
            %{lines: [%{gpio: %{direction: :output, value: 1}}, %{gpio: %{direction: :input}}]}} =
             Expansion.info(pid)

    # A mode change gives the lines back.
    assert :ok = Expansion.set_mode(pid, :pwm_gpio)
    assert_received {FakeGPIO, {:close, "EXPANSION0"}}
    assert_received {FakeGPIO, {:close, "EXPANSION1"}}

    # ...and opens the new mode's inputs for the subscribers.
    assert_received {FakeGPIO, {:open, "EXPANSION1", :input}}
    assert_received {FakeGPIO, {:set_interrupts, "EXPANSION1", :both}}

    assert :ok = Expansion.unsubscribe(pid)
    send(pid, {:circuits_gpio, "EXPANSION1", 223_456, 1})
    refute_receive {Expansion, _}, 50
  end

  test "forgets subscribers that exit", %{opts: opts} do
    pid = start(opts)
    assert :ok = Expansion.set_mode(pid, :gpio)

    test = self()

    subscriber =
      spawn(fn ->
        :ok = Expansion.subscribe(pid)
        send(test, :subscribed)
        receive do: (:stop -> :ok)
      end)

    Process.monitor(subscriber)
    assert_receive :subscribed
    send(subscriber, :stop)
    assert_receive {:DOWN, _ref, :process, ^subscriber, _reason}

    send(pid, {:circuits_gpio, "EXPANSION0", 1, 1})
    assert {:ok, _info} = Expansion.info(pid)
    assert :sys.get_state(pid).subscribers == %{}
  end

  test "tells what the kernel does not have", %{opts: opts, tmp_dir: tmp_dir} do
    pid = start(Keyword.put(opts, :device, Path.join(tmp_dir, "none")))
    assert Expansion.info(pid) == {:error, :enoent}
    assert {:error, :enoent} = Expansion.set_mode(pid, :uart)
  end
end
