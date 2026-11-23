defmodule NanoKVMGo.Metrics do
  @moduledoc """
  What the NanoKVM-Go is doing, sampled each second: the share of the CPU in
  use, the memory in use, the SoC temperature, the traffic of each network
  interface, the load average and the time since it started. The process
  keeps the last five minutes for graphs, and sends each sample to its
  subscribers.

      NanoKVMGo.Metrics.current()
      #=> %{
      #=>   cpu: %{total: 12.5, cores: [10.0, 15.0]},
      #=>   memory: %{used: 251_658_240, total: 510_390_272, percent: 49.3},
      #=>   temperature: 71.3,
      #=>   network: %{"wlan0" => %{down: 1200.0, up: 310.5}},
      #=>   load: [0.08, 0.03, 0.01],
      #=>   uptime: 33_432
      #=> }

      :ok = NanoKVMGo.Metrics.subscribe()

      receive do
        {NanoKVMGo.Metrics, sample} -> sample
      end

  CPU and memory are in percent, the temperature in degrees Celsius (`nil`
  without the sensor), network traffic in bytes per second each way (`down`
  received, `up` sent, the loopback left out), the uptime in seconds. The
  first sample comes a second after the start: the CPU's share is measured
  between two readings.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Metrics` by default
    * `:interval` - milliseconds between samples, 1000 by default
    * `:history` - how many samples to keep, 300 by default
    * `:root` - the root of the file system with procfs and sysfs, `"/"` by
      default
  """
  use GenServer

  alias NanoKVMGo.Options
  alias NanoKVMGo.Thermal

  @typedoc "One sample, see the module documentation."
  @type sample() :: %{
          cpu: %{total: float(), cores: [float()]},
          memory: %{used: non_neg_integer(), total: non_neg_integer(), percent: float()},
          temperature: float() | nil,
          network: %{String.t() => %{down: float(), up: float()}},
          load: [float()],
          uptime: non_neg_integer() | nil
        }

  @typedoc """
  The samples kept, oldest first: CPU and memory in percent, temperatures,
  and the traffic of each interface. An interface that came later has fewer.
  """
  @type history() :: %{
          cpu: [float()],
          memory: [float()],
          temperature: [float() | nil],
          network: %{String.t() => %{down: [float()], up: [float()]}}
        }

  @typedoc "A message to subscribers: each sample."
  @type message() :: {NanoKVMGo.Metrics, sample()}

  @type option() ::
          {:name, GenServer.name()}
          | {:interval, pos_integer()}
          | {:history, pos_integer()}
          | {:root, Path.t()}

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Options.validate!(
        opts,
        [name: __MODULE__, interval: 1_000, history: 300, root: "/"],
        &valid?/2
      )

    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  The last sample, `nil` before the first.
  """
  @spec current(GenServer.server()) :: sample() | nil
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc """
  The samples kept, oldest first.
  """
  @spec history(GenServer.server()) :: history()
  def history(server \\ __MODULE__), do: GenServer.call(server, :history)

  @doc """
  Sends each sample to the caller, as `{NanoKVMGo.Metrics, sample}`, until it
  unsubscribes or exits.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)

  @doc """
  Stops the samples to the caller.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, :unsubscribe)

  @impl GenServer
  def init(config) do
    state = %{
      root: config.root,
      interval: config.interval,
      keep: config.history,
      reading: nil,
      current: nil,
      # Newest first.
      history: %{cpu: [], memory: [], temperature: [], network: %{}},
      subscribers: %{}
    }

    {:ok, take_sample(state)}
  end

  @impl GenServer
  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  def handle_call(:history, _from, state) do
    %{cpu: cpu, memory: memory, temperature: temperature, network: network} = state.history

    history = %{
      cpu: Enum.reverse(cpu),
      memory: Enum.reverse(memory),
      temperature: Enum.reverse(temperature),
      network:
        Map.new(network, fn {name, %{down: down, up: up}} ->
          {name, %{down: Enum.reverse(down), up: Enum.reverse(up)}}
        end)
    }

    {:reply, history, state}
  end

  def handle_call(:subscribe, {pid, _tag}, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  @impl GenServer
  def handle_info(:sample, state), do: {:noreply, take_sample(state)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp take_sample(state) do
    _ref = Process.send_after(self(), :sample, state.interval)

    case {state.reading, read(state.root)} do
      {_last, :error} -> state
      {nil, {:ok, reading}} -> %{state | reading: reading}
      {last, {:ok, reading}} -> publish(%{state | reading: reading}, sample(last, reading))
    end
  end

  defp read(root) do
    proc = Path.join(root, "proc")

    with {:ok, stat} <- File.read(Path.join(proc, "stat")),
         [_ | _] = cpu <- parse_stat(stat),
         {:ok, meminfo} <- File.read(Path.join(proc, "meminfo")),
         {:ok, net_dev} <- File.read(Path.join(proc, "net/dev")) do
      {:ok,
       %{
         at: System.monotonic_time(:millisecond),
         cpu: cpu,
         memory: parse_meminfo(meminfo),
         network: parse_net_dev(net_dev),
         temperature: temperature(root),
         load: read_load(proc),
         uptime: read_uptime(proc)
       }}
    else
      _error -> :error
    end
  end

  defp sample(last, reading) do
    seconds = max(reading.at - last.at, 1) / 1000
    [total | cores] = cpu_use(last.cpu, reading.cpu)
    %{total: memory_total, available: available} = reading.memory
    used = max(memory_total - available, 0)

    network =
      Map.new(reading.network, fn {name, {rx, tx}} ->
        {last_rx, last_tx} = Map.get(last.network, name, {rx, tx})
        # Counters start again from 0 when an interface comes back.
        {name, %{down: max(rx - last_rx, 0) / seconds, up: max(tx - last_tx, 0) / seconds}}
      end)

    %{
      cpu: %{total: total, cores: cores},
      memory: %{used: used, total: memory_total, percent: percent(used, memory_total)},
      temperature: reading.temperature,
      network: network,
      load: reading.load,
      uptime: reading.uptime
    }
  end

  defp publish(state, sample) do
    for {pid, _ref} <- state.subscribers, do: send(pid, {__MODULE__, sample})
    %{state | current: sample, history: remember(state.history, sample, state.keep)}
  end

  defp remember(history, sample, keep) do
    network =
      Map.new(sample.network, fn {name, %{down: down, up: up}} ->
        old = Map.get(history.network, name, %{down: [], up: []})
        {name, %{down: keep(down, old.down, keep), up: keep(up, old.up, keep)}}
      end)

    %{
      cpu: keep(sample.cpu.total, history.cpu, keep),
      memory: keep(sample.memory.percent, history.memory, keep),
      temperature: keep(sample.temperature, history.temperature, keep),
      network: network
    }
  end

  defp keep(value, list, keep), do: Enum.take([value | list], keep)

  defp parse_stat(text) do
    for "cpu" <> _ = line <- String.split(text, "\n"),
        [name | fields] = String.split(line),
        # user nice system idle iowait irq softirq steal; guest time is in user.
        times = fields |> Enum.take(8) |> Enum.map(&String.to_integer/1),
        length(times) >= 4 do
      [_user, _nice, _system, idle | rest] = times
      iowait = Enum.at(rest, 0, 0)
      total = Enum.sum(times)
      {name, total - idle - iowait, total}
    end
  end

  defp cpu_use(last, now) do
    for {name, busy, total} <- now do
      {_name, last_busy, last_total} = List.keyfind(last, name, 0, {name, busy, total})
      percent(busy - last_busy, total - last_total)
    end
  end

  defp parse_meminfo(text) do
    fields =
      for line <- String.split(text, "\n"),
          [key, value | _unit] <- [String.split(line, [":", " "], trim: true)],
          {kilobytes, ""} <- [Integer.parse(value)],
          into: %{},
          do: {key, kilobytes * 1024}

    %{total: Map.get(fields, "MemTotal", 0), available: Map.get(fields, "MemAvailable", 0)}
  end

  defp parse_net_dev(text) do
    for line <- String.split(text, "\n"),
        [name, counters] <- [String.split(line, ":", parts: 2)],
        name = String.trim(name),
        name != "lo",
        [rx, _, _, _, _, _, _, _, tx | _] <- [String.split(counters)],
        {rx, ""} <- [Integer.parse(rx)],
        {tx, ""} <- [Integer.parse(tx)],
        into: %{},
        do: {name, {rx, tx}}
  end

  defp read_load(proc) do
    with {:ok, text} <- File.read(Path.join(proc, "loadavg")),
         [one, five, fifteen | _rest] <- String.split(text),
         loads = Enum.map([one, five, fifteen], &Float.parse/1),
         true <- Enum.all?(loads, &match?({_value, ""}, &1)) do
      Enum.map(loads, &elem(&1, 0))
    else
      _ -> []
    end
  end

  defp read_uptime(proc) do
    with {:ok, text} <- File.read(Path.join(proc, "uptime")),
         [seconds | _idle] <- String.split(text),
         {seconds, ""} <- Float.parse(seconds) do
      trunc(seconds)
    else
      _ -> nil
    end
  end

  defp temperature(root) do
    case Thermal.temperature(root) do
      {:ok, celsius} -> celsius
      {:error, _reason} -> nil
    end
  end

  defp percent(_part, whole) when whole <= 0, do: 0.0
  defp percent(part, whole), do: min(max(part * 100 / whole, 0.0), 100.0)

  defp valid?(:name, _name), do: true
  defp valid?(:interval, interval), do: is_integer(interval) and interval > 0
  defp valid?(:history, history), do: is_integer(history) and history > 0
  defp valid?(:root, root), do: is_binary(root)
end
