defmodule NanoKVMGo.MetricsTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.{Metrics, Wait}

  @moduletag :tmp_dir

  # procfs with one core. Each file changes at once, as procfs reads.
  defp counters(root, cpu, available, network) do
    write(root, "proc/stat", """
    cpu  #{Enum.join(cpu, " ")} 0 0
    cpu0 #{Enum.join(cpu, " ")} 0 0
    intr 1 2 3
    """)

    write(
      root,
      "proc/meminfo",
      "MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: #{available} kB\n"
    )

    interfaces =
      for {name, {rx, tx}} <- network do
        " #{name}: #{rx}      40    0    0    0     0          0         0     #{tx}      50    0    0    0     0       0          0\n"
      end

    write(root, "proc/net/dev", [
      "Inter-|   Receive                            |  Transmit\n",
      " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets\n",
      "    lo:     100       1    0    0    0     0          0         0      100       1    0    0    0     0       0          0\n"
      | interfaces
    ])

    write(root, "proc/loadavg", "0.52 0.30 0.12 2/109 423\n")
    write(root, "proc/uptime", "33432.21 71085.27\n")
  end

  # The SoC's thermal zone.
  defp thermal(root, millidegrees) do
    write(root, "sys/class/thermal/thermal_zone0/type", "soc-thermal\n")
    write(root, "sys/class/thermal/thermal_zone0/temp", "#{millidegrees}\n")
  end

  defp write(root, file, contents) do
    path = Path.join(root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".new", contents)
    File.rename!(path <> ".new", path)
  end

  defp start(root, opts) do
    start_supervised!({Metrics, [root: root, name: nil] ++ opts})
  end

  # The samples already sent, such as those before a call's reply.
  defp flush_samples do
    receive do
      {Metrics, sample} -> [sample | flush_samples()]
    after
      0 -> []
    end
  end

  defp receive_sample(check) do
    assert_receive {Metrics, sample}, 1_000
    if check.(sample), do: sample, else: receive_sample(check)
  end

  test "CPU, memory, temperature, traffic, load and uptime", %{tmp_dir: root} do
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}})
    thermal(root, 71_257)
    started = System.monotonic_time(:millisecond)
    pid = start(root, interval: 200)
    assert :ok = Metrics.subscribe(pid)
    assert Metrics.current(pid) == nil

    # 150 of 400 ticks busy since; 200 kB more in use; 2 MB down, 0.5 MB up.
    counters(root, [200, 0, 100, 1050, 50, 0, 0, 0], 400, %{"wlan0" => {2_000_000, 500_000}})
    assert_receive {Metrics, sample}, 1_000
    seconds = (System.monotonic_time(:millisecond) - started) / 1000

    assert_in_delta sample.cpu.total, 37.5, 0.01
    assert [core] = sample.cpu.cores
    assert_in_delta core, 37.5, 0.01
    assert sample.memory == %{used: 614_400, total: 1_024_000, percent: 60.0}
    assert sample.temperature == 71.257
    assert sample.load == [0.52, 0.30, 0.12]
    assert sample.uptime == 33_432

    # Measured over at least the interval, and at most since the start.
    %{"wlan0" => wlan0} = sample.network
    assert wlan0.down <= 2_000_000 / 0.2 and wlan0.down >= 2_000_000 / seconds
    assert wlan0.up <= 500_000 / 0.2 and wlan0.up >= 500_000 / seconds

    history = Metrics.history(pid)
    samples = [sample | flush_samples()]
    assert history.cpu == Enum.map(samples, & &1.cpu.total)
    assert history.memory == Enum.map(samples, & &1.memory.percent)
    assert history.temperature == Enum.map(samples, & &1.temperature)
    assert history.network["wlan0"].down == Enum.map(samples, & &1.network["wlan0"].down)
  end

  test "subscribers get each sample until they unsubscribe or exit", %{tmp_dir: root} do
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{})
    pid = start(root, interval: 100)

    assert :ok = Metrics.subscribe(pid)
    assert :ok = Metrics.subscribe(pid)
    assert_receive {Metrics, _sample}, 1_000
    Process.sleep(250)
    assert length(Metrics.history(pid).cpu) == 1 + length(flush_samples())

    assert :ok = Metrics.unsubscribe(pid)
    flush_samples()
    taken = length(Metrics.history(pid).cpu)
    Wait.until(fn -> length(Metrics.history(pid).cpu) > taken end)
    refute_received {Metrics, _sample}

    test = self()

    subscriber =
      spawn(fn ->
        :ok = Metrics.subscribe(pid)
        send(test, :subscribed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :subscribed
    ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    taken = length(Metrics.history(pid).cpu)
    Wait.until(fn -> length(Metrics.history(pid).cpu) > taken end)
  end

  test "keeps as many samples as asked, and an interface's own", %{tmp_dir: root} do
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}})
    pid = start(root, interval: 20, history: 3)
    assert :ok = Metrics.subscribe(pid)
    for _ <- 1..4, do: assert_receive({Metrics, _sample}, 1_000)

    # The USB network comes, its counters from zero.
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}, "usb0" => {10, 10}})
    receive_sample(&Map.has_key?(&1.network, "usb0"))
    history = Metrics.history(pid)
    later = flush_samples()

    assert length(history.cpu) == 3
    assert history.temperature == [nil, nil, nil]
    assert length(history.network["wlan0"].down) == 3
    assert history.network["usb0"].down == List.duplicate(0.0, min(1 + length(later), 3))

    # Gone, and back with its counters from zero: no negative rates.
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"usb0" => {5, 5}})
    sample = receive_sample(&(not Map.has_key?(&1.network, "wlan0")))
    assert sample.network == %{"usb0" => %{down: 0.0, up: 0.0}}
    refute Map.has_key?(Metrics.history(pid).network, "wlan0")
  end

  test "carries on through procfs it cannot read", %{tmp_dir: root} do
    pid = start(root, interval: 20)
    assert :ok = Metrics.subscribe(pid)
    refute_receive {Metrics, _sample}, 100
    assert Metrics.current(pid) == nil

    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{})
    assert_receive {Metrics, %{cpu: %{total: +0.0}, temperature: nil}}, 1_000
  end

  test "refuses a history or interval that is not a positive integer" do
    for opts <- [[history: 0], [interval: -1], [history: :all], [interval: nil], [proc: "/"]] do
      assert_raise ArgumentError, fn -> Metrics.start_link([name: nil] ++ opts) end
    end
  end
end
