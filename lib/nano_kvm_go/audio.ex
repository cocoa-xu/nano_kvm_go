defmodule NanoKVMGo.Audio do
  @moduledoc """
  The audio of the HDMI/DisplayPort input, or of the USB speaker.

  The LT7911EXC passes the source's audio on as I2S. This process captures it
  while there are subscribers, in the `nano_kvm_go_audio` port program, as
  interleaved PCM: signed 16-bit little-endian from the HDMI input, and from
  the USB speaker in the format the USB gadget set it up with, at the rate
  the target chose.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Audio` by default
    * `:source` - `:hdmi`, the HDMI/DisplayPort input (the default), or
      `:usb`, what the target plays to the NanoKVM's USB speaker (the
      `:speaker` function of the USB gadget, see `NanoKVMGo.USB`); run one
      process per source
    * `:device` - the ALSA capture device, by default the source's:
      `"hw:CARD=LT7911EXC,DEV=0"` or `"hw:CARD=UAC2Gadget,DEV=0"`
    * `:rate` - the sample rate to expect at first, 48000 by default, the
      rate most computers send at
    * `:channels` - the channels to capture where the device has them, 2 by
      default; the USB speaker has the channels it was set up with
    * `:period_ms` - the audio in each message, 20 ms by default

  ## Messages

  Subscribers receive, with the `:source` of the process, so that one
  subscriber can take both sources apart:

    * `{NanoKVMGo.Audio, source, {:format, format}}`, such as `%{rate: 48000,
      channels: 2, sample_format: :s16_le}`, when the capture starts, when
      subscribing to a running one, and when the source switches to another
      rate. The bridge passes the source's rate on and reports it to the
      video capture driver, which the port program follows. Where the driver
      does not report it, the program measures the rate the samples arrive
      at and snaps it to a standard one (44.1 kHz, 48 kHz, ...) within a few
      seconds. The USB speaker reports the rate the target chooses.
    * `{NanoKVMGo.Audio, source, {:pcm, data}}`, `:period_ms` of samples each

  No samples come while the source sends no audio. A subscriber with more
  than a second of audio waiting misses the next until it catches up; one
  on another node gets them all, as its messages waiting cannot be counted.
  """
  use GenServer
  require Logger

  alias NanoKVMGo.Audio.Protocol
  alias NanoKVMGo.Video.Devices

  @restart_delay 2_000
  @devices %{hdmi: "hw:CARD=LT7911EXC,DEV=0", usb: "hw:CARD=UAC2Gadget,DEV=0"}

  @typedoc "Interleaved signed samples, as ALSA names them: S16_LE, S24_3LE..."
  @type sample_format() :: :s16_le | :s24_3le | :s24_le | :s32_le

  @type format() :: %{
          rate: pos_integer(),
          channels: pos_integer(),
          sample_format: sample_format()
        }

  @type source() :: :hdmi | :usb

  @typedoc "A message to subscribers, see the module documentation."
  @type message() :: {NanoKVMGo.Audio, source(), {:format, format()} | {:pcm, binary()}}

  @type option() ::
          {:name, GenServer.name()}
          | {:source, source()}
          | {:device, String.t()}
          | {:rate, pos_integer()}
          | {:channels, pos_integer()}
          | {:period_ms, pos_integer()}

  @doc """
  A child specification, with the `:name` as its id: one process per
  source can run in the same supervisor.
  """
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends the audio to the caller until it unsubscribes or exits.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)

  @doc """
  Stops sending to the caller.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, :unsubscribe)

  @doc """
  The format of the running capture, `nil` without one.
  """
  @spec format(GenServer.server()) :: format() | nil
  def format(server \\ __MODULE__), do: GenServer.call(server, :format)

  @impl GenServer
  def init(opts) do
    source = Keyword.get(opts, :source, :hdmi)

    unless source in [:hdmi, :usb] do
      raise ArgumentError, "invalid :source: #{inspect(source)}"
    end

    config = %{
      source: source,
      device: Keyword.get(opts, :device, @devices[source]),
      rate: Keyword.get(opts, :rate, 48_000),
      channels: Keyword.get(opts, :channels, 2),
      period_ms: Keyword.get(opts, :period_ms, 20),
      # For tests: another program than the one built with the library, and
      # another video device (or none) than the capture device.
      program: Keyword.get_lazy(opts, :program, &default_program/0),
      video_device: Keyword.get(opts, :video_device, if(source == :hdmi, do: :auto))
    }

    check_config!(config)

    state = %{config: config, port: nil, subscribers: %{}, format: nil, restart: nil}

    if File.regular?(config.program),
      do: {:ok, state},
      else: {:stop, {:missing_program, config.program}}
  end

  defp check_config!(config) do
    valid? =
      Enum.all?([config.rate, config.channels], &(is_integer(&1) and &1 > 0)) and
        is_integer(config.period_ms) and config.period_ms in 1..1000

    unless valid? do
      raise ArgumentError,
            "invalid :rate, :channels or :period_ms: #{inspect(Map.take(config, [:rate, :channels, :period_ms]))}"
    end
  end

  @impl GenServer
  def handle_call(:subscribe, {pid, _tag}, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      if state.format, do: send(pid, {__MODULE__, state.config.source, {:format, state.format}})
      subscribers = Map.put(state.subscribers, pid, Process.monitor(pid))
      {:reply, :ok, ensure_running(%{state | subscribers: subscribers})}
    end
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_call(:format, _from, state), do: {:reply, state.format, state}

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    {:noreply, handle_packet(Protocol.decode(packet), state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | port: nil, format: nil}

    if state.subscribers == %{} do
      {:noreply, state}
    else
      Logger.warning("nano_kvm_go: nano_kvm_go_audio exited (#{status}), restarting")
      {:noreply, %{state | restart: Process.send_after(self(), :restart, @restart_delay)}}
    end
  end

  # A restart already sent when the last subscriber left: nothing to do.
  def handle_info(:restart, %{subscribers: subscribers} = state) when subscribers == %{} do
    {:noreply, %{state | restart: nil}}
  end

  def handle_info(:restart, state), do: {:noreply, ensure_running(%{state | restart: nil})}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_packet({:pcm, pcm}, state) do
    Enum.each(state.subscribers, fn {pid, _monitor} ->
      if backlog(pid) * state.config.period_ms < 1000,
        do: send(pid, {__MODULE__, state.config.source, {:pcm, pcm}})
    end)

    state
  end

  defp handle_packet({:format, format}, state) do
    Enum.each(state.subscribers, fn {pid, _monitor} ->
      send(pid, {__MODULE__, state.config.source, {:format, format}})
    end)

    %{state | format: format}
  end

  defp handle_packet({:log, line}, state) do
    Logger.debug("nano_kvm_go_audio: " <> line)
    state
  end

  defp handle_packet(:unknown, state), do: state

  # Process.info/2 takes local processes only.
  defp backlog(pid) when node(pid) == node() do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> 0
    end
  end

  defp backlog(_pid), do: 0

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | subscribers: subscribers}
        if subscribers == %{}, do: stop(state), else: state
    end
  end

  defp ensure_running(%{port: nil, restart: nil} = state) do
    config = state.config

    args =
      [
        config.device,
        Integer.to_string(config.rate),
        Integer.to_string(config.channels),
        Integer.to_string(config.period_ms)
      ] ++ List.wrap(video_device(config.video_device))

    port =
      Port.open({:spawn_executable, config.program}, [
        :binary,
        {:packet, 4},
        :exit_status,
        args: args
      ])

    %{state | port: port}
  end

  defp ensure_running(state), do: state

  # The device with the bridge's rate control.
  defp video_device(:auto), do: Devices.capture()
  defp video_device(device), do: device

  defp stop(%{port: nil} = state), do: cancel_restart(state)

  # Unlike Port.close/1, a message never raises once the program has exited.
  defp stop(state) do
    send(state.port, {self(), :close})
    cancel_restart(%{state | port: nil, format: nil})
  end

  defp cancel_restart(%{restart: nil} = state), do: state

  defp cancel_restart(state) do
    _remaining = Process.cancel_timer(state.restart)
    %{state | restart: nil}
  end

  defp default_program, do: Application.app_dir(:nano_kvm_go, "priv/nano_kvm_go_audio")
end
