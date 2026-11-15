defmodule NanoKVM.MetricsTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Metrics

  @moduletag :tmp_dir

  # procfs with one core, and the SoC's thermal zone.
  defp counters(dir, cpu, available, network) do
    File.mkdir_p!(Path.join(dir, "proc/net"))

    File.write!(Path.join(dir, "proc/stat"), """
    cpu  #{Enum.join(cpu, " ")} 0 0
    cpu0 #{Enum.join(cpu, " ")} 0 0
    intr 1 2 3
    """)

    File.write!(
      Path.join(dir, "proc/meminfo"),
      "MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: #{available} kB\n"
    )

    interfaces =
      for {name, {rx, tx}} <- network do
        " #{name}: #{rx}      40    0    0    0     0          0         0     #{tx}      50    0    0    0     0       0          0\n"
      end

    File.write!(Path.join(dir, "proc/net/dev"), [
      "Inter-|   Receive                            |  Transmit\n",
      " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets\n",
      "    lo:     100       1    0    0    0     0          0         0      100       1    0    0    0     0       0          0\n"
      | interfaces
    ])

    File.write!(Path.join(dir, "proc/loadavg"), "0.52 0.30 0.12 2/109 423\n")
    File.write!(Path.join(dir, "proc/uptime"), "33432.21 71085.27\n")
  end

  defp thermal(dir, millidegrees) do
    zone = Path.join(dir, "thermal/thermal_zone0")
    File.mkdir_p!(zone)
    File.write!(Path.join(zone, "type"), "soc-thermal\n")
    File.write!(Path.join(zone, "temp"), "#{millidegrees}\n")
  end

  defp start(dir, opts \\ []) do
    opts =
      [proc: Path.join(dir, "proc"), thermal: Path.join(dir, "thermal"), interval: nil, name: nil]
      |> Keyword.merge(opts)

    start_supervised!({Metrics, opts})
  end

  # A sample on demand, once the process has taken the one before.
  defp sample(pid) do
    send(pid, :sample)
    :sys.get_state(pid)
    Metrics.current(pid)
  end

  test "CPU, memory, temperature, traffic, load and uptime", %{tmp_dir: dir} do
    counters(dir, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}})
    thermal(dir, 71_257)
    started = System.monotonic_time(:millisecond)
    pid = start(dir)
    assert Metrics.current(pid) == nil

    # 150 of 400 ticks busy since; 200 kB more in use; 2 MB down, 0.5 MB up.
    counters(dir, [200, 0, 100, 1050, 50, 0, 0, 0], 400, %{"wlan0" => {2_000_000, 500_000}})
    Process.sleep(200)
    sample = sample(pid)
    seconds = (System.monotonic_time(:millisecond) - started) / 1000

    assert_in_delta sample.cpu.total, 37.5, 0.01
    assert [core] = sample.cpu.cores
    assert_in_delta core, 37.5, 0.01
    assert sample.memory == %{used: 614_400, total: 1_024_000, percent: 60.0}
    assert sample.temperature == 71.257
    assert sample.load == [0.52, 0.30, 0.12]
    assert sample.uptime == 33_432

    # Measured over at least the 200 ms slept, and at most since the start.
    %{"wlan0" => wlan0} = sample.network
    assert wlan0.down <= 2_000_000 / 0.2 and wlan0.down >= 2_000_000 / seconds
    assert wlan0.up <= 500_000 / 0.2 and wlan0.up >= 500_000 / seconds

    assert %{cpu: [cpu], memory: [60.0], temperature: [71.257], network: %{"wlan0" => wlan0}} =
             Metrics.history(pid)

    assert_in_delta cpu, 37.5, 0.01
    assert [_down] = wlan0.down
  end

  test "subscribers get each sample until they unsubscribe or exit", %{tmp_dir: dir} do
    counters(dir, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{})
    thermal(dir, 40_000)
    pid = start(dir)

    assert :ok = Metrics.subscribe(pid)
    assert :ok = Metrics.subscribe(pid)
    sample = sample(pid)
    assert_receive {Metrics, ^sample}
    refute_receive {Metrics, _sample}, 50

    assert :ok = Metrics.unsubscribe(pid)
    sample(pid)
    refute_receive {Metrics, _sample}, 50

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
    sample(pid)
    assert :sys.get_state(pid).subscribers == %{}
  end

  test "keeps as many samples as asked, and an interface's own", %{tmp_dir: dir} do
    counters(dir, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}})
    pid = start(dir, history: 3)

    for _ <- 1..5, do: sample(pid)
    # The USB network comes, its counters from zero.
    counters(dir, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}, "usb0" => {10, 10}})
    sample(pid)

    history = Metrics.history(pid)
    assert length(history.cpu) == 3
    assert history.temperature == [nil, nil, nil]
    assert length(history.network["wlan0"].down) == 3
    assert history.network["usb0"] == %{down: [0.0], up: [0.0]}

    # Gone, and back with its counters from zero: no negative rates.
    counters(dir, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"usb0" => {5, 5}})
    assert sample(pid).network == %{"usb0" => %{down: 0.0, up: 0.0}}
    refute Map.has_key?(Metrics.history(pid).network, "wlan0")
  end

  test "carries on through procfs it cannot read", %{tmp_dir: dir} do
    pid = start(dir)
    assert sample(pid) == nil

    counters(dir, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{})
    sample(pid)
    assert %{cpu: %{total: +0.0}, temperature: nil} = sample(pid)
  end

  test "refuses a history or interval that is not a positive integer" do
    Process.flag(:trap_exit, true)

    for opts <- [[history: 0], [interval: -1], [history: :all]] do
      assert {:error, {%ArgumentError{}, _stack}} = Metrics.start_link([name: nil] ++ opts)
    end
  end
end
