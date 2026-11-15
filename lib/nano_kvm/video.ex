defmodule NanoKVM.Video do
  @moduledoc """
  Capture of the HDMI/DisplayPort input with the hardware encoders.

  The process runs the `nano_kvm_video` port program. It captures the input
  at the input's own size and encodes each frame from the capture buffer, with
  no copy:

    * to JPEG, which the program serves itself as MJPEG over HTTP:
      `http://<device>:<mjpeg_port>/stream.mjpg`, with a viewer page at `/`
    * to H.264 (Annex B), sent to the subscribers while there are any

  When the input changes, the program stops and starts again at the new size;
  subscribers get the new input, then a keyframe.

  ## Options

    * `:name` - the name to register, `NanoKVM.Video` by default
    * `:mjpeg_port` - the TCP port of the MJPEG server, 8088 by default
    * `:mjpeg_token` - a token the MJPEG stream asks for,
      `/stream.mjpg?token=<token>`; without one the stream and a viewer page
      are open to anyone who reaches the port
    * `:jpeg_quality` - 1 to 100, 60 by default
    * `:h264_qp` - the H.264 quantizer, 0 (best) to 51, 30 by default

  ## Messages

  Subscribers receive:

    * `{NanoKVM.Video, {:input, input}}` when subscribing and when the input
      changes, see `t:NanoKVM.Video.Input.t/0`
    * `{NanoKVM.Video, {:h264, :key | :delta, data}}`, one access unit each,
      starting with a keyframe. The SPS and PPS come before every keyframe.

  A subscriber with more than 30 messages waiting misses the deltas until
  the next keyframe, which is then asked for.

  ## EDID

  The bridge presents an EDID to the source, kept in its flash: `edid/0`
  reads it and `set_edid/1` replaces it, with or without the process.
  """
  use GenServer
  require Logger

  alias NanoKVM.Video.Devices
  alias NanoKVM.Video.EDID
  alias NanoKVM.Video.Input
  alias NanoKVM.Video.Protocol

  @restart_delay 2_000
  @input_restart_delay 100
  @max_backlog 30

  @type option() ::
          {:name, GenServer.name()}
          | {:mjpeg_port, :inet.port_number()}
          | {:mjpeg_token, String.t() | nil}
          | {:jpeg_quality, 1..100}
          | {:h264_qp, 0..51}

  @typedoc "A message to subscribers, see the module documentation."
  @type message() ::
          {NanoKVM.Video, {:input, Input.t()} | {:h264, :key | :delta, binary()}}

  @doc """
  Starts the capture. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends the input and the H.264 stream to the caller until it unsubscribes or
  exits. Returns `{:error, :no_encoder}` without the H.264 encoder.
  """
  @spec subscribe(GenServer.server()) :: :ok | {:error, :no_encoder}
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)

  @doc """
  Stops sending to the caller.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, :unsubscribe)

  @doc """
  Asks for a keyframe soon.
  """
  @spec request_keyframe(GenServer.server()) :: :ok
  def request_keyframe(server \\ __MODULE__), do: GenServer.cast(server, :keyframe)

  @doc """
  The current input, `nil` until known.
  """
  @spec input(GenServer.server()) :: Input.t() | nil
  def input(server \\ __MODULE__), do: GenServer.call(server, :input)

  @doc """
  Counters of the capture driver since the device started, `nil` when the
  driver does not have them:

    * `:mid_frame_stops` - captures stopped in the middle of a frame; input
      changes cause them
    * `:csi_recoveries` - restarts of the CSI-2 receiver after receive errors
  """
  @spec capture_stats() :: %{
          mid_frame_stops: non_neg_integer() | nil,
          csi_recoveries: non_neg_integer() | nil
        }
  def capture_stats do
    dir = with device when is_binary(device) <- Devices.capture(), do: Devices.sysfs_dir(device)

    %{
      mid_frame_stops: read_counter(dir, "mid_frame_stops"),
      csi_recoveries: read_counter(dir, "csi_recoveries")
    }
  end

  @doc """
  The EDID the input presents to the source: one to four blocks of 128 bytes.

  The first read takes over a second, as the bridge reads its flash.
  `NanoKVM.EDID.decode/1` tells what it says.
  """
  @spec edid() :: {:ok, binary()} | {:error, term()}
  def edid, do: EDID.read(edid_program(), Devices.capture())

  @doc """
  Stores an EDID for the input to present to the source: one to four blocks
  of 128 bytes, each with a valid checksum. Takes a few seconds.

  The source reads it when it next connects, for example when the NanoKVM is
  plugged in again. Read the current EDID with `edid/0` first to be able to
  go back to it.
  """
  @spec set_edid(binary()) :: :ok | {:error, term()}
  def set_edid(edid), do: EDID.write(edid_program(), Devices.capture(), edid)

  @impl GenServer
  def init(opts) do
    config = %{
      mjpeg_port: Keyword.get(opts, :mjpeg_port, 8088),
      mjpeg_token: Keyword.get(opts, :mjpeg_token),
      jpeg_quality: Keyword.get(opts, :jpeg_quality, 60),
      h264_qp: Keyword.get(opts, :h264_qp, 30),
      # For tests: another program and other devices than the ones found.
      program: Keyword.get_lazy(opts, :program, &default_program/0),
      devices: Keyword.get(opts, :devices)
    }

    validate!(config)

    state = %{
      config: config,
      port: nil,
      h264?: false,
      subscribers: %{},
      key_requested?: false,
      input: nil
    }

    if File.regular?(config.program),
      do: {:ok, state, {:continue, :start}},
      else: {:stop, {:missing_program, config.program}}
  end

  @impl GenServer
  def handle_continue(:start, state), do: {:noreply, start_program(state)}

  @impl GenServer
  def handle_call(:subscribe, _from, %{port: port, h264?: false} = state) when port != nil do
    {:reply, {:error, :no_encoder}, state}
  end

  def handle_call(:subscribe, {pid, _tag}, state) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        first? = state.subscribers == %{}
        command(state, if(first?, do: :h264_start, else: :keyframe))
        subscriber = %{monitor: Process.monitor(pid), synced?: false}
        %{state | subscribers: Map.put(state.subscribers, pid, subscriber), key_requested?: true}
      end

    send(pid, {__MODULE__, {:input, state.input}})
    {:reply, :ok, state}
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_call(:input, _from, state), do: {:reply, state.input, state}

  @impl GenServer
  def handle_cast(:keyframe, state) do
    command(state, :keyframe)
    {:noreply, %{state | key_requested?: true}}
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    {:noreply, handle_packet(Protocol.decode(packet), state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if Protocol.input_changed?(status) do
      Logger.info("nano_kvm: video input changed, restarting the capture")
      Process.send_after(self(), :start, @input_restart_delay)
    else
      Logger.warning("nano_kvm: nano_kvm_video exited (#{status}), restarting")
      Process.send_after(self(), :start, @restart_delay)
    end

    {:noreply, stopped(state)}
  end

  def handle_info(:start, state), do: {:noreply, start_program(state)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_packet({:log, line}, state) do
    Logger.debug("nano_kvm_video: " <> line)
    state
  end

  defp handle_packet({:input, input}, %{input: input} = state), do: state

  defp handle_packet({:input, input}, state) do
    Logger.info("nano_kvm: video input #{inspect(input)}")
    notify(state, {:input, input})
    %{state | input: input}
  end

  defp handle_packet({:h264, kind, au}, state) do
    subscribers =
      Map.new(state.subscribers, fn {pid, subscriber} ->
        {pid, deliver(pid, subscriber, kind, au)}
      end)

    waiting? = Enum.any?(subscribers, fn {_pid, subscriber} -> not subscriber.synced? end)

    key_requested? =
      cond do
        kind == :key -> waiting?
        waiting? and not state.key_requested? -> command(state, :keyframe) == :ok
        true -> state.key_requested?
      end

    %{state | subscribers: subscribers, key_requested?: key_requested?}
  end

  defp handle_packet(:unknown, state), do: state

  # Keyframes go to everyone; deltas only to subscribers that have the
  # stream's state and keep up.
  defp deliver(pid, subscriber, :key, au) do
    send(pid, {__MODULE__, {:h264, :key, au}})
    %{subscriber | synced?: true}
  end

  defp deliver(pid, %{synced?: true} = subscriber, :delta, au) do
    if backlog(pid) < @max_backlog do
      send(pid, {__MODULE__, {:h264, :delta, au}})
      subscriber
    else
      %{subscriber | synced?: false}
    end
  end

  defp deliver(_pid, subscriber, :delta, _au), do: subscriber

  defp backlog(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> 0
    end
  end

  defp notify(state, event) do
    Enum.each(state.subscribers, fn {pid, _subscriber} -> send(pid, {__MODULE__, event}) end)
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {subscriber, subscribers} ->
        Process.demonitor(subscriber.monitor, [:flush])
        if subscribers == %{}, do: command(state, :h264_stop)
        %{state | subscribers: subscribers}
    end
  end

  # The next program starts with a keyframe for everyone.
  defp stopped(state) do
    subscribers = Map.new(state.subscribers, fn {pid, s} -> {pid, %{s | synced?: false}} end)
    %{state | port: nil, subscribers: subscribers}
  end

  defp start_program(state) do
    config = state.config

    case devices(config) do
      {:ok, devices} ->
        port = open_port(config, devices)
        state = %{state | port: port, h264?: devices.h264 != nil, key_requested?: false}
        if state.subscribers != %{}, do: command(state, :h264_start)
        state

      :error ->
        Logger.warning("nano_kvm: no video capture or JPEG encoder device, trying again later")
        Process.send_after(self(), :start, @restart_delay)
        state
    end
  end

  defp token_env(nil), do: []
  defp token_env(token), do: [{~c"KVM_MJPEG_TOKEN", String.to_charlist(token)}]

  defp open_port(config, devices) do
    args = [
      devices.capture,
      devices.jpeg,
      Integer.to_string(config.mjpeg_port),
      Integer.to_string(config.jpeg_quality)
    ]

    h264_env =
      if devices.h264,
        do: [
          {~c"KVM_H264_DEV", String.to_charlist(devices.h264)},
          {~c"KVM_H264_QP", ~c"#{config.h264_qp}"}
        ],
        else: []

    Port.open({:spawn_executable, config.program}, [
      :binary,
      {:packet, 4},
      :exit_status,
      args: args,
      env: [{~c"KVM_PORT", ~c"1"} | h264_env] ++ token_env(config.mjpeg_token)
    ])
  end

  defp command(%{port: nil}, _command), do: :ok
  defp command(%{h264?: false}, _command), do: :ok

  defp command(%{port: port}, command) do
    Port.command(port, Protocol.command(command))
    :ok
  end

  defp devices(%{devices: nil}) do
    capture = Devices.capture()
    jpeg = Devices.jpeg()

    if capture && jpeg,
      do: {:ok, %{capture: capture, jpeg: jpeg, h264: Devices.h264()}},
      else: :error
  end

  defp devices(%{devices: devices}), do: {:ok, Map.put_new(devices, :h264, nil)}

  defp read_counter(dir, file) when is_binary(dir) do
    with {:ok, text} <- File.read(Path.join(dir, file)),
         {count, _rest} <- Integer.parse(text) do
      count
    else
      _ -> nil
    end
  end

  defp read_counter(_dir, _file), do: nil

  defp default_program, do: Application.app_dir(:nano_kvm, "priv/nano_kvm_video")

  defp edid_program, do: Application.app_dir(:nano_kvm, "priv/nano_kvm_edid")

  defp validate!(config) do
    check!(config.mjpeg_port in 1..65_535, :mjpeg_port, config.mjpeg_port)
    check!(config.jpeg_quality in 1..100, :jpeg_quality, config.jpeg_quality)

    check!(
      is_nil(config.mjpeg_token) or
        (is_binary(config.mjpeg_token) and config.mjpeg_token =~ ~r/\A[A-Za-z0-9_-]{16,}\z/),
      :mjpeg_token,
      config.mjpeg_token
    )

    check!(config.h264_qp in 0..51, :h264_qp, config.h264_qp)
  end

  defp check!(true, _option, _value), do: :ok

  defp check!(false, option, value) do
    raise ArgumentError, "invalid #{inspect(option)}: #{inspect(value)}"
  end
end
