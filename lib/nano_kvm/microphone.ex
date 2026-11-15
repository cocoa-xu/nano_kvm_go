defmodule NanoKVM.Microphone do
  @moduledoc """
  The microphone the target computer sees, with the `:microphone` function
  of `NanoKVM.USB`.

  `play/2` sends it PCM: interleaved samples in the microphone's format, the
  channels and sample size `NanoKVM.USB` set it up with, at the rate the
  target chose. `format/1` tells that format, and subscribers hear of it.
  The `nano_kvm_playback` port program keeps the microphone's stream
  running: between samples the target hears silence, and samples that come
  in faster than the target takes them are dropped once more than 200 ms
  wait, so the sound never lags. The program runs while there are
  subscribers, and from `play/2` until `:idle_ms` without samples.

  ## Messages

  Subscribers receive `{NanoKVM.Microphone, {:format, format}}`, a
  `t:NanoKVM.Audio.format/0`, when the program starts, when subscribing to a
  running one, and when the target chooses another rate. Samples sent in
  the old format until then play at the wrong speed.

  ## Options

    * `:name` - the name to register, `NanoKVM.Microphone` by default
    * `:device` - the ALSA playback device, `"hw:CARD=UAC2Gadget,DEV=0"` by
      default
    * `:idle_ms` - how long to keep the stream without samples and
      subscribers, 10 s by default
  """
  use GenServer
  require Logger

  alias NanoKVM.Audio.Protocol

  @period_ms 20
  @restart_delay 2_000

  @type option() ::
          {:name, GenServer.name()}
          | {:device, String.t()}
          | {:idle_ms, pos_integer()}

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Plays samples on the microphone, in its format, any number of frames.
  """
  @spec play(GenServer.server(), binary()) :: :ok
  def play(server \\ __MODULE__, pcm) when is_binary(pcm) do
    GenServer.cast(server, {:play, pcm})
  end

  @doc """
  Sends the format to the caller until it unsubscribes or exits, and keeps
  the stream running meanwhile.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)

  @doc """
  Stops sending to the caller.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, :unsubscribe)

  @doc """
  The format of the running stream, `nil` without one.
  """
  @spec format(GenServer.server()) :: NanoKVM.Audio.format() | nil
  def format(server \\ __MODULE__), do: GenServer.call(server, :format)

  @impl GenServer
  def init(opts) do
    config = %{
      device: Keyword.get(opts, :device, "hw:CARD=UAC2Gadget,DEV=0"),
      idle_ms: Keyword.get(opts, :idle_ms, 10_000),
      # For tests: another program than the one built with the library.
      program: Keyword.get_lazy(opts, :program, &default_program/0)
    }

    unless is_integer(config.idle_ms) and config.idle_ms > 0 do
      raise ArgumentError, "invalid :idle_ms: #{inspect(config.idle_ms)}"
    end

    state = %{
      config: config,
      port: nil,
      format: nil,
      subscribers: %{},
      idle: nil,
      restart: nil,
      paused_until: nil
    }

    if File.regular?(config.program),
      do: {:ok, state},
      else: {:stop, {:missing_program, config.program}}
  end

  @impl GenServer
  def handle_call(:subscribe, {pid, _tag}, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      if state.format, do: send(pid, {__MODULE__, {:format, state.format}})
      subscribers = Map.put(state.subscribers, pid, Process.monitor(pid))
      {:reply, :ok, ensure_running(%{state | subscribers: subscribers})}
    end
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_call(:format, _from, state), do: {:reply, state.format, state}

  @impl GenServer
  def handle_cast({:play, pcm}, state) do
    state = ensure_running(state)
    if state.port, do: Port.command(state.port, pcm)
    {:noreply, restart_idle_timer(state)}
  end

  @impl GenServer
  def handle_info(:idle, state) do
    state = %{state | idle: nil}
    {:noreply, if(state.subscribers == %{}, do: stop(state), else: state)}
  end

  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    {:noreply, handle_packet(Protocol.decode(packet), state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("nano_kvm: nano_kvm_playback exited (#{status})")
    # Samples within the next moments are dropped rather than a busy restart.
    paused_until = System.monotonic_time(:millisecond) + @restart_delay
    state = %{state | port: nil, format: nil, paused_until: paused_until}

    if state.subscribers == %{},
      do: {:noreply, state},
      else: {:noreply, %{state | restart: Process.send_after(self(), :restart, @restart_delay)}}
  end

  def handle_info(:restart, state), do: {:noreply, ensure_running(%{state | restart: nil})}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_packet({:format, format}, state) do
    Enum.each(state.subscribers, fn {pid, _monitor} ->
      send(pid, {__MODULE__, {:format, format}})
    end)

    %{state | format: format}
  end

  defp handle_packet({:log, line}, state) do
    Logger.debug("nano_kvm_playback: " <> line)
    state
  end

  defp handle_packet(_other, state), do: state

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | subscribers: subscribers}
        if subscribers == %{} and state.idle == nil, do: stop(state), else: state
    end
  end

  defp ensure_running(%{port: nil, restart: nil} = state) do
    case paused_for(state) do
      0 ->
        args = [state.config.device, Integer.to_string(@period_ms)]

        port =
          Port.open({:spawn_executable, state.config.program}, [
            :binary,
            {:packet, 4},
            :exit_status,
            args: args
          ])

        %{state | port: port, paused_until: nil}

      # Subscribers wait for the format; samples meanwhile are dropped.
      ms when state.subscribers != %{} ->
        %{state | restart: Process.send_after(self(), :restart, ms)}

      _ms ->
        state
    end
  end

  defp ensure_running(state), do: state

  defp paused_for(%{paused_until: nil}), do: 0

  defp paused_for(%{paused_until: until}) do
    max(until - System.monotonic_time(:millisecond), 0)
  end

  defp restart_idle_timer(state) do
    _remaining = state.idle && Process.cancel_timer(state.idle)
    %{state | idle: Process.send_after(self(), :idle, state.config.idle_ms)}
  end

  defp stop(%{port: nil} = state), do: cancel_restart(state)

  defp stop(state) do
    # It may have exited on its own, its exit_status still on the way.
    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    cancel_restart(%{state | port: nil, format: nil})
  end

  defp cancel_restart(%{restart: nil} = state), do: state

  defp cancel_restart(state) do
    _remaining = Process.cancel_timer(state.restart)
    %{state | restart: nil}
  end

  defp default_program, do: Application.app_dir(:nano_kvm, "priv/nano_kvm_playback")
end
