defmodule NanoKVMGo.Video do
  @moduledoc """
  Capture of the HDMI/DisplayPort input with the hardware encoders.

  The process runs the `nano_kvm_go_video` port program. It captures the input
  at the input's own size and encodes each frame from the capture buffer, with
  no copy:

    * to JPEG, which the program serves itself as MJPEG over HTTP:
      `http://<device>:<mjpeg_port>/stream.mjpg`, with a viewer page at `/`
    * to H.264 or H.265 (Annex B), sent to the subscribers while there are
      any

  When the input changes, the program stops and starts again at the new size;
  subscribers get the new input, then a keyframe.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Video` by default
    * `:mjpeg_port` - the TCP port of the MJPEG server, 8088 by default
    * `:mjpeg_token` - a token the MJPEG stream asks for,
      `/stream.mjpg?token=<token>`: at least 16 of the characters `A-Z`,
      `a-z`, `0-9`, `-` and `_`, which go in a URL as they are, such as
      `Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)`.
      Without one the stream and a viewer page are open to anyone who
      reaches the port
    * `:jpeg_quality` - 1 to 100, 60 by default
    * `:encoding` - how the stream is encoded, see `t:encoding/0`: the
      codec every subscriber decodes, VBR of up to 8 Mbit/s at QP 24, a
      keyframe every 600 frames, by default. Or `{module, function, args}`
      that returns it, called each time the process starts: a restart by
      its supervisor then takes the encoding saved last, a user's settings
      say
    * `:devices` - the devices to capture and encode with, see
      `t:devices/0`, by default the board's, found by their drivers each
      time the capture starts
    * `:capture_buffers` - how many frames the capture holds, 2 to 6, which
      the encoders read in place: by default four with a video CMA pool of
      176 MiB or more, three with less, as on the Go with 256 MiB (see
      `NanoKVMGo.CMA`)
    * `:program` - the port program, the library's `nano_kvm_go_video` by
      default

  ## Messages

  Subscribers receive:

    * `{NanoKVMGo.Video, {:input, input}}` when subscribing and when the input
      changes, once the capture knows it, see `t:input/0`
    * `{NanoKVMGo.Video, {codec, :key | :delta, data}}`, one access unit each
      of the codec, `:h264` or `:h265`, starting with a keyframe. The
      parameter sets come before every keyframe. When the codec changes, the
      next access unit is a keyframe of the new one.

  A subscriber with more than 30 messages waiting misses the deltas until
  the next keyframe, which is then asked for. One on another node gets them
  all: its messages waiting cannot be counted.

  ## EDID

  The bridge presents an EDID to the source, kept in its flash: `edid/1`
  reads it and `set_edid/2` replaces it, with or without the process.
  """
  use GenServer
  require Logger

  alias NanoKVMGo.EDID
  alias NanoKVMGo.Options
  alias NanoKVMGo.Video.Devices
  alias NanoKVMGo.Video.Protocol

  @restart_delay 2_000
  @snapshot_timeout 5_000
  @max_restart_delay 60_000
  @default_encoding %{
    codec: :auto,
    rate_control: :vbr,
    bitrate: 8_000_000,
    qp: 24,
    keyframe_interval: 600,
    max_fps: 0,
    color_matrix: :auto,
    color_range: :auto
  }
  @input_restart_delay 100
  @max_backlog 30

  @typedoc """
  The signal at the input, as the LT7911EXC bridge reports it: the size of
  a frame in pixels and the frame rate, `:none` without a signal, or
  `:unsupported` for a signal the bridge cannot pass on.
  """
  @type input() ::
          %{width: pos_integer(), height: pos_integer(), fps: non_neg_integer()}
          | :none
          | :unsupported

  @typedoc "A rectangle of the input's pixels: `{x, y, width, height}`."
  @type region() ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "A picture of `snapshot/3`: RGB, three bytes a pixel, rows top to bottom."
  @type snapshot() :: %{width: non_neg_integer(), height: non_neg_integer(), data: binary()}

  @typedoc """
  The video devices: the capture's, the JPEG encoder's and, for the stream,
  the H.264 and H.265 encoder's.
  """
  @type devices() :: %{
          required(:capture) => Path.t(),
          required(:jpeg) => Path.t(),
          optional(:encoder) => Path.t() | nil
        }

  @typedoc """
  How the stream is encoded:

    * `:codec` - `:h264`, `:h265`, or `:auto` for H.265 while every
      subscriber decodes it and H.264 otherwise (see `subscribe/2`)
    * `:rate_control` - `:constant_qp`, every frame at `:qp`; `:cbr`, at a
      constant `:bitrate`; `:vbr`, at `:qp` unless the bitrate would go over
      `:bitrate`, then at the QP that keeps it
    * `:bitrate` - bits a second: what CBR keeps to, the most VBR takes
    * `:qp` - the quantizer, 0 (the best picture) to 51: constant QP's, the
      best VBR goes to
    * `:keyframe_interval` - frames from a keyframe to the next, unless one
      is asked for sooner
    * `:max_fps` - frames a second at most, 0 for as many as the input has
    * `:color_matrix` - the matrix that turns the samples into RGB,
      `:bt601` or `:bt709`
    * `:color_range` - whether the samples use the `:full` range or the
      `:limited` one

  The bitrate a still picture takes is low whatever the rate control: CBR
  and VBR save no bits for later.

  Where the capture converts the colour (the system's HDMI bridge driver
  from linux-ax620e 4bd74a0 on), the bridge turns the picture into the
  colour asked for, and the streams and snapshots carry it: `:auto` is
  BT.601 at full range, which JPEG decoders take for granted, so the MJPEG
  stream shows the colours right as well. Elsewhere the colour only labels
  the samples as the bridge hands them over: `:auto` is that, BT.709 at full
  range, and another label shifts the colours a decoder shows.
  """
  @type encoding() :: %{
          codec: :auto | :h264 | :h265,
          rate_control: :constant_qp | :cbr | :vbr,
          bitrate: pos_integer(),
          qp: 0..51,
          keyframe_interval: pos_integer(),
          max_fps: non_neg_integer(),
          color_matrix: :auto | :bt601 | :bt709,
          color_range: :auto | :full | :limited
        }

  @type option() ::
          {:name, GenServer.name()}
          | {:mjpeg_port, :inet.port_number()}
          | {:mjpeg_token, String.t() | nil}
          | {:jpeg_quality, 1..100}
          | {:encoding, keyword() | map() | {module(), atom(), [term()]}}
          | {:devices, devices() | nil}
          | {:capture_buffers, 2..6 | :auto}
          | {:program, Path.t()}

  @type edid_option() :: {:device, Path.t()} | {:program, Path.t()}

  @typedoc "An option of `subscribe/2`: the codecs the subscriber decodes."
  @type subscribe_option() :: {:codecs, [:h264 | :h265, ...]}

  @typedoc "A message to subscribers, see the module documentation."
  @type message() ::
          {NanoKVMGo.Video, {:input, input()} | {:h264 | :h265, :key | :delta, binary()}}

  @doc """
  Starts the capture. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Options.validate!(
        opts,
        [
          name: __MODULE__,
          mjpeg_port: 8088,
          mjpeg_token: nil,
          jpeg_quality: 60,
          encoding: [],
          devices: nil,
          capture_buffers: :auto,
          program: Application.app_dir(:nano_kvm_go, "priv/nano_kvm_go_video")
        ],
        &valid?/2
      )

    {name, opts} = Keyword.pop!(opts, :name)
    {encoding, opts} = Keyword.pop!(opts, :encoding)
    config = opts |> Map.new() |> Map.put(:encoding, checked_encoding(encoding))
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @doc """
  How the stream is encoded, see `t:encoding/0`.
  """
  @spec encoding(GenServer.server()) :: encoding()
  def encoding(server \\ __MODULE__), do: GenServer.call(server, :encoding)

  @doc """
  Changes how the stream is encoded, from the next frame: the keys given, see
  `t:encoding/0`. Returns the encoding, and raises `ArgumentError` for one
  it does not take.

      NanoKVMGo.Video.set_encoding(codec: :h265, rate_control: :cbr, bitrate: 3_000_000)
  """
  @spec set_encoding(GenServer.server(), keyword() | map()) :: encoding()
  def set_encoding(server \\ __MODULE__, changes) do
    GenServer.call(server, {:set_encoding, encoding!(%{}, changes)})
  end

  @doc """
  Sends the input and the stream to the caller until it unsubscribes or
  exits. Returns `{:error, :no_encoder}` without the H.264 and H.265 encoder.

  The option `:codecs` names those the caller decodes, `[:h264]` by
  default: with the `:auto` codec the stream takes H.265 while every
  subscriber decodes it. Subscribing again changes them. With options,
  name the server first:

      NanoKVMGo.Video.subscribe(NanoKVMGo.Video, codecs: [:h264, :h265])
  """
  @spec subscribe(GenServer.server(), [subscribe_option()]) :: :ok | {:error, :no_encoder}
  def subscribe(server \\ __MODULE__, opts \\ []) do
    opts = Options.validate!(opts, [codecs: [:h264]], &valid_subscription?/2)
    GenServer.call(server, {:subscribe, opts[:codecs]})
  end

  @doc """
  The codec the stream takes now, `:h264` or `:h265`: the encoding's, or
  for `:auto` the one every subscriber decodes.
  """
  @spec codec(GenServer.server()) :: :h264 | :h265
  def codec(server \\ __MODULE__), do: GenServer.call(server, :codec)

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
  A region of the next captured picture, `{x, y, width, height}` in the
  input's pixels, or the whole of it, as RGB: three bytes a pixel, rows top
  to bottom, in the colours the streams declare. A region partly outside the
  picture is cut to it, one outside gives an empty picture.

  `{:error, :no_input}` without a picture to take it from, `:timeout` when
  none came within `timeout` milliseconds, `:stopped` when the capture
  stopped first.
  """
  @spec snapshot(GenServer.server(), region() | :all, timeout()) ::
          {:ok, snapshot()} | {:error, :no_input | :timeout | :stopped}
  def snapshot(server \\ __MODULE__, region \\ :all, timeout \\ @snapshot_timeout)
      when region == :all or tuple_size(region) == 4 do
    GenServer.call(server, {:snapshot, region, timeout}, timeout + 1_000)
  end

  @doc """
  The current input, `nil` until known.
  """
  @spec input(GenServer.server()) :: input() | nil
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
    case Devices.capture() do
      nil ->
        %{mid_frame_stops: nil, csi_recoveries: nil}

      device ->
        dir = Devices.sysfs_dir(device)

        %{
          mid_frame_stops: read_counter(dir, "mid_frame_stops"),
          csi_recoveries: read_counter(dir, "csi_recoveries")
        }
    end
  end

  @doc """
  The EDID the input presents to the source: one to four blocks of 128 bytes.

  The first read takes over a second, as the bridge reads its flash.
  `NanoKVMGo.EDID.decode/1` tells what it says. A failure of the
  `nano_kvm_go_edid` program gives `{:error, {:exit_status, status,
  output}}`.

  ## Options

    * `:device` - the video capture device, by default the board's
    * `:program` - the program that reads and stores the EDID, the
      library's `nano_kvm_go_edid` by default
  """
  @spec edid([edid_option()]) :: {:ok, binary()} | {:error, term()}
  def edid(opts \\ []) do
    opts = Options.validate!(opts, [:device, program: edid_program()], &valid?/2)

    with {:ok, device} <- capture_device(opts),
         {:ok, edid} <- run_edid(opts[:program], [device]) do
      if EDID.valid?(edid), do: {:ok, edid}, else: {:error, :invalid_edid}
    end
  end

  @doc """
  Stores an EDID for the input to present to the source, one that
  `NanoKVMGo.EDID.valid?/1` takes. Takes a few seconds.

  The source reads it when it next connects, for example when the NanoKVM is
  plugged in again. Read the current EDID with `edid/1` first to be able to
  go back to it. The options are those of `edid/1`.
  """
  @spec set_edid(binary(), [edid_option()]) :: :ok | {:error, term()}
  def set_edid(edid, opts \\ []) do
    opts = Options.validate!(opts, [:device, program: edid_program()], &valid?/2)

    if not EDID.valid?(edid) do
      raise ArgumentError, "not an EDID: #{inspect(edid, limit: 16)}"
    end

    with {:ok, device} <- capture_device(opts),
         {:ok, _output} <- run_edid(opts[:program], [device, Base.encode16(edid)]) do
      :ok
    end
  end

  @impl GenServer
  def init(config) do
    state = %{
      config: %{config | encoding: initial_encoding(config.encoding)},
      port: nil,
      encoder?: false,
      subscribers: %{},
      key_requested?: false,
      input: nil,
      codec: nil,
      started_at: nil,
      restart_delay: nil,
      snapshots: []
    }

    if File.regular?(config.program),
      do: {:ok, %{state | codec: stream_codec(state)}, {:continue, :start}},
      else: {:stop, {:missing_program, config.program}}
  end

  @impl GenServer
  def handle_continue(:start, state), do: {:noreply, start_program(state)}

  @impl GenServer
  def handle_call({:subscribe, _codecs}, _from, %{port: port, encoder?: false} = state)
      when port != nil do
    {:reply, {:error, :no_encoder}, state}
  end

  def handle_call({:subscribe, codecs}, {pid, _tag}, state) do
    state =
      case state.subscribers do
        %{^pid => subscriber} ->
          choose_codec(put_in(state.subscribers[pid], %{subscriber | codecs: codecs}))

        subscribers ->
          subscriber = %{monitor: Process.monitor(pid), synced?: false, codecs: codecs}
          state = choose_codec(%{state | subscribers: Map.put(subscribers, pid, subscriber)})
          :ok = command(state, if(subscribers == %{}, do: :start_stream, else: :keyframe))
          %{state | key_requested?: true}
      end

    if state.input, do: send(pid, {__MODULE__, {:input, state.input}})
    {:reply, :ok, state}
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_call(:input, _from, state), do: {:reply, state.input, state}

  def handle_call({:snapshot, region, timeout}, from, state) do
    case {state.port, state.input} do
      {port, %{width: width, height: height}} when port != nil ->
        region = if region == :all, do: {0, 0, width, height}, else: region
        if state.snapshots == [], do: command(state, {:snapshot, region})
        timer = Process.send_after(self(), {:snapshot_timeout, from}, timeout)
        {:noreply, %{state | snapshots: [{from, timer} | state.snapshots]}}

      _ ->
        {:reply, {:error, :no_input}, state}
    end
  end

  def handle_call(:encoding, _from, state), do: {:reply, state.config.encoding, state}

  def handle_call(:codec, _from, state), do: {:reply, state.codec, state}

  def handle_call({:set_encoding, changes}, _from, state) do
    state = update_in(state.config.encoding, &Map.merge(&1, changes))
    state = %{state | codec: stream_codec(state)}
    :ok = command(state, {:encoding, program_encoding(state)})
    {:reply, state.config.encoding, state}
  end

  @impl GenServer
  def handle_cast(:keyframe, state), do: {:noreply, ask_keyframe(state)}

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    {:noreply, handle_packet(Protocol.decode(packet), state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if Protocol.input_changed?(status) do
      Logger.info("nano_kvm_go: video input changed, restarting the capture")
      Process.send_after(self(), :start, @input_restart_delay)
      {:noreply, stopped(state)}
    else
      delay = next_restart_delay(state)

      Logger.warning(
        "nano_kvm_go: nano_kvm_go_video exited (#{status}), restarting in #{div(delay, 1000)} s"
      )

      Process.send_after(self(), :start, delay)
      {:noreply, %{stopped(state) | restart_delay: delay}}
    end
  end

  def handle_info(:start, state), do: {:noreply, start_program(state)}

  def handle_info({:snapshot_timeout, from}, state) do
    {timed_out, waiting} = Enum.split_with(state.snapshots, fn {f, _timer} -> f == from end)
    Enum.each(timed_out, fn {f, _timer} -> GenServer.reply(f, {:error, :timeout}) end)
    {:noreply, %{state | snapshots: waiting}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_packet({:log, line}, state) do
    Logger.debug("nano_kvm_go_video: " <> line)
    state
  end

  defp handle_packet({:input, input}, %{input: input} = state), do: state

  defp handle_packet({:input, input}, state) do
    Logger.info("nano_kvm_go: video input #{inspect(input)}")
    notify(state, {:input, input})
    %{state | input: input}
  end

  defp handle_packet({codec, kind, au}, state) when codec in [:h264, :h265] do
    subscribers =
      Map.new(state.subscribers, fn {pid, subscriber} ->
        {pid, deliver(pid, subscriber, {codec, kind, au})}
      end)

    waiting? = Enum.any?(subscribers, fn {_pid, subscriber} -> not subscriber.synced? end)
    state = %{state | subscribers: subscribers}

    cond do
      kind == :key -> %{state | key_requested?: waiting?}
      waiting? and not state.key_requested? -> ask_keyframe(state)
      true -> state
    end
  end

  defp handle_packet({:snapshot, picture}, state), do: reply_snapshots(state, {:ok, picture})
  defp handle_packet(:unknown, state), do: state

  defp reply_snapshots(state, reply) do
    Enum.each(state.snapshots, fn {from, timer} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, reply)
    end)

    %{state | snapshots: []}
  end

  # Keyframes go to everyone; deltas only to subscribers that have the
  # stream's state and keep up.
  defp deliver(pid, subscriber, {_codec, :key, _au} = message) do
    send(pid, {__MODULE__, message})
    %{subscriber | synced?: true}
  end

  defp deliver(pid, %{synced?: true} = subscriber, message) do
    if backlog(pid) < @max_backlog do
      send(pid, {__MODULE__, message})
      subscriber
    else
      %{subscriber | synced?: false}
    end
  end

  defp deliver(_pid, subscriber, _delta), do: subscriber

  # Process.info/2 takes local processes only.
  defp backlog(pid) when node(pid) == node() do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> 0
    end
  end

  defp backlog(_pid), do: 0

  defp ask_keyframe(state) do
    :ok = command(state, :keyframe)
    %{state | key_requested?: true}
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
        state = %{state | subscribers: subscribers}
        if subscribers == %{}, do: :ok = command(state, :stop_stream)
        choose_codec(state)
    end
  end

  # The codec the stream takes: the encoding's, or for :auto H.265 while
  # every subscriber decodes it.
  defp stream_codec(%{config: %{encoding: %{codec: :auto}}} = state) do
    subscribers = Map.values(state.subscribers)
    if subscribers != [] and Enum.all?(subscribers, &(:h265 in &1.codecs)), do: :h265, else: :h264
  end

  defp stream_codec(state), do: state.config.encoding.codec

  # Tells the program when the codec the subscribers call for changes.
  defp choose_codec(state) do
    case stream_codec(state) do
      codec when codec == state.codec ->
        state

      codec ->
        state = %{state | codec: codec}
        :ok = command(state, {:encoding, program_encoding(state)})
        state
    end
  end

  defp program_encoding(state), do: %{state.config.encoding | codec: state.codec}

  # A program that fails soon after it starts, as when the video pool cannot
  # hold the input's buffers, starts again less and less often.
  defp next_restart_delay(%{restart_delay: nil}), do: @restart_delay

  defp next_restart_delay(%{started_at: started_at, restart_delay: delay}) do
    if System.monotonic_time(:millisecond) - started_at >= @max_restart_delay,
      do: @restart_delay,
      else: min(delay * 2, @max_restart_delay)
  end

  defp stopped(state) do
    subscribers = Map.new(state.subscribers, fn {pid, s} -> {pid, %{s | synced?: false}} end)
    reply_snapshots(%{state | port: nil, subscribers: subscribers}, {:error, :stopped})
  end

  defp start_program(state) do
    config = state.config

    case devices(config) do
      {:ok, devices} ->
        state = %{state | codec: stream_codec(state)}
        port = open_port(config, devices, program_encoding(state))

        state = %{
          state
          | port: port,
            encoder?: devices.encoder != nil,
            key_requested?: false,
            started_at: System.monotonic_time(:millisecond)
        }

        if state.subscribers != %{}, do: command(state, :start_stream)
        state

      :error ->
        Logger.warning("nano_kvm_go: no video capture or JPEG encoder device, trying again later")
        Process.send_after(self(), :start, @restart_delay)
        state
    end
  end

  defp token_env(nil), do: []
  defp token_env(token), do: [{~c"KVM_MJPEG_TOKEN", String.to_charlist(token)}]

  defp open_port(config, devices, encoding) do
    args = [
      devices.capture,
      devices.jpeg,
      Integer.to_string(config.mjpeg_port),
      Integer.to_string(config.jpeg_quality)
    ]

    encoder_env =
      if devices.encoder,
        do: [
          {~c"KVM_ENCODER_DEV", String.to_charlist(devices.encoder)},
          {~c"KVM_ENCODING", String.to_charlist(Protocol.encoding(encoding))}
        ],
        else: []

    env = [
      {~c"KVM_PORT", ~c"1"},
      {~c"KVM_CAPTURE_BUFFERS", Integer.to_charlist(capture_buffers(config))}
    ]

    Port.open({:spawn_executable, config.program}, [
      :binary,
      {:packet, 4},
      :exit_status,
      args: args,
      env: env ++ encoder_env ++ token_env(config.mjpeg_token)
    ])
  end

  # Four frames at 4K take about 140 MiB with JPEG and a video encoder: the
  # Go's 128 MiB pool takes three.
  defp capture_buffers(%{capture_buffers: :auto}),
    do: if(NanoKVMGo.CMA.sizes().video >= 176, do: 4, else: 3)

  defp capture_buffers(%{capture_buffers: count}), do: count

  defp command(%{port: nil}, _command), do: :ok
  defp command(%{encoder?: false}, _command), do: :ok

  # Unlike Port.command/2, a message never raises once the program has exited.
  defp command(%{port: port}, command) do
    send(port, {self(), {:command, Protocol.command(command)}})
    :ok
  end

  defp devices(%{devices: nil}) do
    capture = Devices.capture()
    jpeg = Devices.jpeg()

    if capture && jpeg,
      do: {:ok, %{capture: capture, jpeg: jpeg, encoder: Devices.encoder()}},
      else: :error
  end

  defp devices(%{devices: devices}), do: {:ok, Map.put_new(devices, :encoder, nil)}

  defp read_counter(dir, file) do
    with {:ok, text} <- File.read(Path.join(dir, file)),
         {count, _rest} <- Integer.parse(text) do
      count
    else
      _ -> nil
    end
  end

  defp edid_program, do: Application.app_dir(:nano_kvm_go, "priv/nano_kvm_go_edid")

  # One a function returns is checked as the process starts.
  defp checked_encoding({_module, _function, _args} = source), do: source
  defp checked_encoding(encoding), do: encoding!(@default_encoding, encoding)

  defp initial_encoding({module, function, args}),
    do: encoding!(@default_encoding, apply(module, function, args))

  defp initial_encoding(encoding), do: encoding

  defp encoding!(encoding, changes) do
    changes
    |> Enum.to_list()
    |> Options.validate!(Map.keys(@default_encoding), &valid_encoding?/2)
    |> Map.new()
    |> then(&Map.merge(encoding, &1))
  end

  defp valid_encoding?(:codec, codec), do: codec in [:auto, :h264, :h265]

  defp valid_encoding?(:rate_control, rate_control),
    do: rate_control in [:constant_qp, :cbr, :vbr]

  defp valid_encoding?(:bitrate, bitrate), do: bitrate in 1..1_000_000_000
  defp valid_encoding?(:qp, qp), do: qp in 0..51
  defp valid_encoding?(:keyframe_interval, frames), do: frames in 1..65_535
  defp valid_encoding?(:max_fps, fps), do: fps in 0..1_000
  defp valid_encoding?(:color_matrix, matrix), do: matrix in [:auto, :bt601, :bt709]
  defp valid_encoding?(:color_range, range), do: range in [:auto, :full, :limited]

  defp valid_subscription?(:codecs, codecs),
    do: is_list(codecs) and codecs != [] and Enum.all?(codecs, &(&1 in [:h264, :h265]))

  defp capture_device(opts) do
    case Keyword.get_lazy(opts, :device, &Devices.capture/0) do
      nil -> {:error, :no_device}
      device -> {:ok, device}
    end
  end

  defp run_edid(program, args) do
    if File.regular?(program) do
      case System.cmd(program, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {:exit_status, status, String.trim(output)}}
      end
    else
      {:error, {:missing_program, program}}
    end
  end

  defp valid?(:name, _name), do: true
  defp valid?(:mjpeg_port, port), do: port in 1..65_535
  defp valid?(:mjpeg_token, nil), do: true
  defp valid?(:mjpeg_token, token), do: is_binary(token) and token =~ ~r/\A[A-Za-z0-9_-]{16,}\z/
  defp valid?(:jpeg_quality, quality), do: quality in 1..100

  defp valid?(:capture_buffers, count), do: count == :auto or count in 2..6

  defp valid?(:encoding, {module, function, args}),
    do: is_atom(module) and is_atom(function) and is_list(args)

  defp valid?(:encoding, encoding), do: is_list(encoding) or is_map(encoding)
  defp valid?(:devices, nil), do: true

  defp valid?(:devices, %{capture: capture, jpeg: jpeg} = devices)
       when is_binary(capture) and is_binary(jpeg),
       do: is_binary(devices[:encoder]) or is_nil(devices[:encoder])

  defp valid?(:devices, _devices), do: false
  defp valid?(:device, device), do: is_binary(device)
  defp valid?(:program, program), do: is_binary(program)
end
