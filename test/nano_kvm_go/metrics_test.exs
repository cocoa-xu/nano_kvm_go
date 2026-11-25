defmodule NanoKVMGo.MetricsTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Metrics

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

  # Samples come when the test sends what the timer would, an hour apart.
  defp start(root, opts \\ []) do
    start_supervised!({Metrics, [root: root, interval: :timer.hours(1), name: nil] ++ opts})
  end

  defp sample(pid) do
    send(pid, :sample)
    Metrics.current(pid)
  end

  test "CPU, memory, temperature, traffic, load and uptime", %{tmp_dir: root} do
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}})
    thermal(root, 71_257)
    clock = :atomics.new(1, signed: true)
    pid = start(root, clock: fn -> :atomics.get(clock, 1) end)
    assert Metrics.current(pid) == nil

    # A second later: 150 of 400 ticks busy since; 200 kB more in use; 2 MB
    # down, 0.5 MB up.
    counters(root, [200, 0, 100, 1050, 50, 0, 0, 0], 400, %{"wlan0" => {2_000_000, 500_000}})
    :atomics.put(clock, 1, 1_000)
    sample = sample(pid)

    assert_in_delta sample.cpu.total, 37.5, 0.01
    assert [core] = sample.cpu.cores
    assert_in_delta core, 37.5, 0.01
    assert sample.memory == %{used: 614_400, total: 1_024_000, percent: 60.0}
    assert sample.temperature == 71.257
    assert sample.load == [0.52, 0.30, 0.12]
    assert sample.uptime == 33_432

    assert %{"wlan0" => %{down: 2_000_000.0, up: 500_000.0} = wlan0} = sample.network

    assert %{cpu: [cpu], memory: [60.0], temperature: [71.257], network: %{"wlan0" => history}} =
             Metrics.history(pid)

    assert_in_delta cpu, 37.5, 0.01
    assert history == %{down: [wlan0.down], up: [wlan0.up]}
  end

  test "subscribers get each sample once until they unsubscribe", %{tmp_dir: root} do
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{})
    pid = start(root)

    assert :ok = Metrics.subscribe(pid)
    assert :ok = Metrics.subscribe(pid)
    sample = sample(pid)
    assert_received {Metrics, ^sample}
    refute_received {Metrics, _sample}

    assert :ok = Metrics.unsubscribe(pid)
    sample(pid)
    refute_received {Metrics, _sample}
  end

  test "samples go on when a subscriber exits", %{tmp_dir: root} do
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{})
    pid = start(root)
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

    assert %{cpu: %{total: +0.0}} = sample(pid)
  end

  test "keeps as many samples as asked, and an interface's own", %{tmp_dir: root} do
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}})
    pid = start(root, history: 3)

    for _ <- 1..5, do: sample(pid)
    # The USB network comes, its counters from zero.
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"wlan0" => {0, 0}, "usb0" => {10, 10}})
    sample(pid)

    history = Metrics.history(pid)
    assert length(history.cpu) == 3
    assert history.temperature == [nil, nil, nil]
    assert length(history.network["wlan0"].down) == 3
    assert history.network["usb0"] == %{down: [0.0], up: [0.0]}

    # Gone, and back with its counters from zero: no negative rates.
    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{"usb0" => {5, 5}})
    assert sample(pid).network == %{"usb0" => %{down: 0.0, up: 0.0}}
    refute Map.has_key?(Metrics.history(pid).network, "wlan0")
  end

  test "carries on through procfs it cannot read", %{tmp_dir: root} do
    pid = start(root)
    assert sample(pid) == nil

    counters(root, [100, 0, 50, 800, 50, 0, 0, 0], 600, %{})
    sample(pid)
    assert %{cpu: %{total: +0.0}, temperature: nil} = sample(pid)
  end

  test "refuses a history or interval that is not a positive integer" do
    for opts <- [[history: 0], [interval: -1], [history: :all], [interval: nil], [proc: "/"]] do
      assert_raise ArgumentError, fn -> Metrics.start_link([name: nil] ++ opts) end
    end
  end
end
