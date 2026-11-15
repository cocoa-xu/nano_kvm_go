defmodule NanoKVM.Microphone do
  @moduledoc """
  The microphone the target computer sees, with the `:microphone` function
  of `NanoKVM.USB`.

  `play/2` sends it PCM: interleaved signed 16-bit little-endian samples at
  48 kHz, mono, the format of the USB microphone. The `nano_kvm_playback`
  port program keeps the microphone's stream running: between samples the
  target hears silence, and samples that come in faster than the target
  takes them are dropped once more than 200 ms wait, so the sound never
  lags. The program starts with the first `play/2` and stops after
  `:idle_ms` without samples.

  ## Options

    * `:name` - the name to register, `NanoKVM.Microphone` by default
    * `:device` - the ALSA playback device, `"hw:CARD=UAC2Gadget,DEV=0"` by
      default
    * `:idle_ms` - how long to keep the stream without samples, 10 s by
      default
  """
  use GenServer
  require Logger

  @rate 48_000
  @channels 1
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
  Plays samples on the microphone: 48 kHz mono S16_LE, any number of frames.
  """
  @spec play(GenServer.server(), binary()) :: :ok
  def play(server \\ __MODULE__, pcm) when is_binary(pcm) do
    GenServer.cast(server, {:play, pcm})
  end

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

    state = %{config: config, port: nil, idle: nil, paused_until: nil}

    if File.regular?(config.program),
      do: {:ok, state},
      else: {:stop, {:missing_program, config.program}}
  end

  @impl GenServer
  def handle_cast({:play, pcm}, state) do
    state = ensure_running(state)
    if state.port, do: Port.command(state.port, pcm)
    {:noreply, restart_idle_timer(state)}
  end

  @impl GenServer
  def handle_info(:idle, state), do: {:noreply, stop(%{state | idle: nil})}

  def handle_info({port, {:data, <<0, line::binary>>}}, %{port: port} = state) do
    Logger.debug("nano_kvm_playback: " <> line)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("nano_kvm: nano_kvm_playback exited (#{status})")
    # Samples within the next moments are dropped rather than a busy restart.
    paused_until = System.monotonic_time(:millisecond) + @restart_delay
    {:noreply, %{state | port: nil, paused_until: paused_until}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_running(%{port: nil} = state) do
    if paused?(state) do
      state
    else
      args = [
        state.config.device,
        Integer.to_string(@rate),
        Integer.to_string(@channels),
        Integer.to_string(div(@rate * @period_ms, 1000))
      ]

      port =
        Port.open({:spawn_executable, state.config.program}, [
          :binary,
          {:packet, 4},
          :exit_status,
          args: args
        ])

      %{state | port: port, paused_until: nil}
    end
  end

  defp ensure_running(state), do: state

  defp paused?(%{paused_until: nil}), do: false
  defp paused?(%{paused_until: until}), do: System.monotonic_time(:millisecond) < until

  defp restart_idle_timer(state) do
    _remaining = state.idle && Process.cancel_timer(state.idle)
    %{state | idle: Process.send_after(self(), :idle, state.config.idle_ms)}
  end

  defp stop(%{port: nil} = state), do: state

  defp stop(state) do
    # It may have exited on its own, its exit_status still on the way.
    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    %{state | port: nil}
  end

  defp default_program, do: Application.app_dir(:nano_kvm, "priv/nano_kvm_playback")
end
