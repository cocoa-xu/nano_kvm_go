defmodule NanoKVMGo.VideoTest do
  # One fake program at a time: started together, they would hold each
  # other's pipes open.
  use ExUnit.Case, async: false

  alias NanoKVMGo.{FakeProgram, Peer, Video}

  @moduletag :tmp_dir

  @devices %{capture: "/dev/null", jpeg: "/dev/null", encoder: "/dev/null"}

  # Stands in for nano_kvm_go_video: reports an input, then reports each
  # command it gets as an event and answers the stream commands ("1" start,
  # "k" keyframe) and snapshots ("s ...", a 2x1 picture) with {:packet, 4}
  # frames, until its stdin ends. A command
  # is {:packet, 4} framed too: a 4-byte length, then the command. The
  # shell's own printf would leave what it failed to write, once the port is
  # gone, to the command substitution, which would then loop forever.
  @fake """
  env printf '\\000\\000\\000\\015\\003'
  env printf '1920x1080@60'
  while length=$(dd bs=4 count=1 2>/dev/null | od -An -tu1 |
                 awk 'NR == 1 { print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }') &&
        [ -n "$length" ]; do
    command=$(dd bs="$length" count=1 2>/dev/null)
    event "command $command"
    case "$command" in
      1) env printf '\\000\\000\\000\\014\\002STAMPKEY\\000\\000\\000\\014\\001STAMPDEL' ;;
      k) env printf '\\000\\000\\000\\014\\002STAMPKEY' ;;
      s*) env printf '\\000\\000\\000\\013\\006\\000\\002\\000\\001RGBrgb' ;;
    esac
  done
  """

  # One block, no name or modes, with a valid checksum.
  @edid <<0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>> <>
          :binary.copy(<<0>>, 119) <> <<6>>

  # A capture of a fake program, once the program runs.
  defp start_video(tmp_dir, opts \\ []) do
    {fake, opts} = Keyword.pop(opts, :fake, @fake)

    stamp =
      for <<(byte <- <<os_time()::64>>)>>,
        into: "",
        do: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")

    fake = String.replace(fake, "STAMP", stamp)
    name = "fake_video_#{System.unique_integer([:positive])}"
    program = FakeProgram.write!(Path.join(tmp_dir, name), fake)
    video = start_supervised!({Video, [program: program, devices: @devices, name: nil] ++ opts})
    assert_receive {FakeProgram, "start"}
    {video, program}
  end

  test "reports the input and streams H.264 to subscribers", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    assert :ok = Video.subscribe(video)

    assert_receive {Video, {:input, %{width: 1920, height: 1080, fps: 60}}}
    assert_receive {Video, {:h264, :key, "KEY"}}
    assert_receive {Video, {:h264, :delta, "DEL"}}

    Video.request_keyframe(video)
    assert_receive {Video, {:h264, :key, "KEY"}}

    assert :ok = Video.unsubscribe(video)
    assert_receive {FakeProgram, "command 0"}

    # A keyframe asked for now reaches no one. Traced, to know when it comes;
    # a call made then is handled after it.
    :erlang.trace(video, true, [:receive])
    Video.request_keyframe(video)
    assert_receive {:trace, ^video, :receive, {_port, {:data, <<2, _at::64, "KEY">>}}}
    _codec = Video.codec(video)
    refute_received {Video, _message}
  end

  test "the time each access unit came from the encoder, for subscribers that ask", %{
    tmp_dir: tmp_dir
  } do
    before = System.monotonic_time(:microsecond)
    {video, _program} = start_video(tmp_dir)
    assert :ok = Video.subscribe(video, timestamps: true)

    assert_receive {Video, {:h264, :key, "KEY", key_at}}
    assert_receive {Video, {:h264, :delta, "DEL", delta_at}}
    assert before <= key_at and key_at <= delta_at

    assert :ok = Video.subscribe(video, timestamps: false)
    Video.request_keyframe(video)
    assert_receive {Video, {:h264, :key, "KEY"}}
    assert_raise ArgumentError, fn -> Video.subscribe(video, timestamps: :yes) end
  end

  test "capture timestamps survive a blocked video process", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    assert :ok = Video.subscribe(video, timestamps: true)
    assert_receive {Video, {:h264, :key, "KEY", _}}
    assert_receive {Video, {:h264, :delta, "DEL", _}}
    port = FakeProgram.port(video)
    send(video, {port, {:data, <<7, "seconds 1">>}})
    assert_receive {Video, {:stats, %{port_frames: 2}}}
    captured = os_time()

    :ok = :sys.suspend(video)

    try do
      send(video, {port, {:data, <<1, captured::64, "FIRST">>}})
      Process.sleep(60)
      send(video, {port, {:data, <<1, captured + 5_000::64, "SECOND">>}})
    after
      :ok = :sys.resume(video)
    end

    assert_receive {Video, {:h264, :delta, "FIRST", first}}
    assert_receive {Video, {:h264, :delta, "SECOND", second}}
    assert second - first == 5_000
    assert System.monotonic_time(:microsecond) - first >= 50_000
    send(video, {port, {:data, <<7, "seconds 1 pipe_ms 0.2 pipe_max_ms 0.9">>}})

    assert_receive {Video,
                    {:stats, %{port_frames: 2, port_ms: mean, port_max_ms: longest, pipe_ms: 0.2}}}

    assert mean >= 50
    assert longest >= mean
    send(video, {port, {:data, <<7, "seconds 1">>}})
    assert_receive {Video, {:stats, %{port_frames: 0, port_ms: 0, port_max_ms: 0.0}}}
  end

  test "a stalled viewer recovers without interrupting a healthy viewer", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    assert :ok = Video.subscribe(video)
    assert_receive {Video, {:h264, :key, "KEY"}}
    assert_receive {Video, {:h264, :delta, "DEL"}}
    test = self()

    slow =
      spawn_link(fn ->
        :ok = Video.subscribe(video)
        send(test, :subscribed)
        paused_viewer(test)
      end)

    on_exit(fn -> Process.exit(slow, :kill) end)
    assert_receive :subscribed
    assert_receive {FakeProgram, "command k"}
    assert_receive {Video, {:h264, :key, "KEY"}}

    for _ <- 1..2 do
      for _ <- 1..40 do
        inject_frame(video, 1, "TICK")
        assert_receive {Video, {:h264, :delta, "TICK"}}
      end

      assert {:message_queue_len, 30} = Process.info(slow, :message_queue_len)
      refute_receive {FakeProgram, "command k"}, 50

      send(slow, :catch_up)
      assert_receive :caught_up
      inject_frame(video, 1, "RECOVER")
      assert_receive {Video, {:h264, :delta, "RECOVER"}}
      assert_receive {FakeProgram, "command k"}
      assert_receive {Video, {:h264, :key, "KEY"}}
      assert_receive {:slow, {Video, {:h264, :key, "KEY"}}}
      inject_frame(video, 1, "LIVE")
      assert_receive {Video, {:h264, :delta, "LIVE"}}
      assert_receive {:slow, {Video, {:h264, :delta, "LIVE"}}}
      refute_receive {FakeProgram, "command k"}, 50
      send(slow, :pause)
      assert_receive :paused
    end

    monitor = Process.monitor(slow)
    send(slow, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^slow, :normal}
    inject_frame(video, 1, "AFTER")
    assert_receive {Video, {:h264, :delta, "AFTER"}}
    refute_receive {FakeProgram, "command 0"}, 50
  end

  test "keyframes also stop accumulating for a stalled viewer", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    test = self()

    slow =
      spawn_link(fn ->
        :ok = Video.subscribe(video)
        send(test, :subscribed)
        paused_viewer(test)
      end)

    on_exit(fn -> Process.exit(slow, :kill) end)
    assert_receive :subscribed
    assert_receive {FakeProgram, "command 1"}
    for _ <- 1..40, do: inject_frame(video, 2, "KEY")
    assert {:message_queue_len, 30} = Process.info(slow, :message_queue_len)
    refute_receive {FakeProgram, "command k"}, 50
  end

  defp os_time do
    :erlang.system_info(:os_monotonic_time_source)
    |> Keyword.fetch!(:time)
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp inject_frame(video, type, data) do
    send(video, {FakeProgram.port(video), {:data, <<type, os_time()::64, data::binary>>}})
    Video.codec(video)
  end

  defp paused_viewer(test) do
    receive do
      :catch_up ->
        flush_video()
        send(test, :caught_up)
        active_viewer(test)

      :stop ->
        :ok
    end
  end

  defp active_viewer(test) do
    receive do
      :pause ->
        send(test, :paused)
        paused_viewer(test)

      message ->
        send(test, {:slow, message})
        active_viewer(test)
    end
  end

  defp flush_video do
    receive do
      {Video, _} -> flush_video()
    after
      0 -> :ok
    end
  end

  test "tells subscribers the codec of each access unit", %{tmp_dir: tmp_dir} do
    # Packet types 5 and 4: an H.265 keyframe and delta.
    h265 =
      @fake
      |> String.replace("\\002STAMPKEY", "\\005STAMPKEY")
      |> String.replace("\\001STAMPDEL", "\\004STAMPDEL")

    {video, _program} = start_video(tmp_dir, fake: h265)
    assert :ok = Video.subscribe(video)

    assert_receive {Video, {:h265, :key, "KEY"}}
    assert_receive {Video, {:h265, :delta, "DEL"}}
  end

  test "takes H.265 while every subscriber decodes it", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    assert Video.codec(video) == :h264

    assert :ok = Video.subscribe(video, codecs: [:h264, :h265])
    assert_receive {FakeProgram, "command e h265 vbr 8000000 24 0 0 auto auto"}
    assert_receive {FakeProgram, "command 1"}
    assert Video.codec(video) == :h265

    test = self()

    h264_only =
      spawn(fn ->
        :ok = Video.subscribe(video)
        send(test, :subscribed)
        receive do: (:leave -> :ok)
      end)

    assert_receive :subscribed
    assert_receive {FakeProgram, "command e h264 vbr 8000000 24 0 0 auto auto"}
    assert Video.codec(video) == :h264

    send(h264_only, :leave)
    assert_receive {FakeProgram, "command e h265 vbr 8000000 24 0 0 auto auto"}

    assert_raise ArgumentError, fn -> Video.subscribe(video, codecs: []) end
    assert_raise ArgumentError, fn -> Video.subscribe(video, codecs: [:vp9]) end
  end

  test "takes snapshots of the picture or a region of it", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    assert :ok = Video.subscribe(video)
    assert_receive {Video, {:input, %{width: 1920, height: 1080}}}

    assert Video.snapshot(video, {2, 1, 2, 1}) == {:ok, %{width: 2, height: 1, data: "RGBrgb"}}
    assert_receive {FakeProgram, "command s 2 1 2 1"}
    assert {:ok, %{width: 2, height: 1}} = Video.snapshot(video)
    assert_receive {FakeProgram, "command s 0 0 1920 1080"}
  end

  test "takes no snapshot without a picture or an answer", %{tmp_dir: tmp_dir} do
    # Without its first two lines the program reports no input.
    [_header, _input, no_input] = String.split(@fake, "\n", parts: 3)
    {video, _program} = start_video(tmp_dir, fake: no_input)
    assert Video.snapshot(video) == {:error, :no_input}
    stop_supervised!(Video)

    {video, _program} = start_video(tmp_dir, fake: String.replace(@fake, "s*)", "s_*)"))
    assert :ok = Video.subscribe(video)
    assert_receive {Video, {:input, %{width: 1920}}}
    assert Video.snapshot(video, :all, 100) == {:error, :timeout}
  end

  test "tells a subscriber the input once it is known", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir, fake: "cat > /dev/null\n")

    # The input would come before the reply.
    assert :ok = Video.subscribe(video)
    refute_received {Video, _message}
  end

  test "streams to a subscriber on another node", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    Peer.spawn_caller("NanoKVMGo.Video.subscribe(server)", server: video)

    # The peer takes a while to start.
    assert_receive {Peer, {Video, {:input, %{width: 1920, height: 1080, fps: 60}}}}, 10_000
    assert_receive {Peer, {Video, {:h264, :key, "KEY"}}}
    assert_receive {Peer, {Video, {:h264, :delta, "DEL"}}}
  end

  @tag :capture_log
  test "takes a command that comes as the program exits", %{tmp_dir: tmp_dir} do
    {video, program} = start_video(tmp_dir)
    :ok = Video.subscribe(video)
    assert_receive {Video, {:input, input}}
    port = FakeProgram.port(video)
    ref = Port.monitor(port)

    # The keyframe request waits in the queue while the program dies.
    :ok = :sys.suspend(video)
    Video.request_keyframe(video)
    FakeProgram.kill(program)
    assert_receive {:DOWN, ^ref, :port, ^port, _reason}
    :ok = :sys.resume(video)

    assert Video.input(video) == input
  end

  test "holds the capture buffers asked for", %{tmp_dir: tmp_dir} do
    start_video(tmp_dir,
      fake: ~s(event "buffers $KVM_CAPTURE_BUFFERS"\n) <> @fake,
      capture_buffers: 5
    )

    assert_receive {FakeProgram, "buffers 5"}

    for count <- [1, 7, :many] do
      assert_raise ArgumentError, fn ->
        Video.start_link(capture_buffers: count, devices: @devices, name: nil)
      end
    end
  end

  test "takes the encoding a function returns each time it starts", %{tmp_dir: tmp_dir} do
    saved = start_supervised!({Agent, fn -> [rate_control: :cbr, bitrate: 3_000_000] end})

    {video, _program} =
      start_video(tmp_dir,
        fake: ~s(event "encoding $KVM_ENCODING"\n) <> @fake,
        encoding: {Agent, :get, [saved, & &1]}
      )

    assert_receive {FakeProgram, "encoding h264 cbr 3000000 24 0 0 auto auto"}

    Agent.update(saved, fn _encoding -> [rate_control: :constant_qp, qp: 30] end)
    Process.exit(video, :kill)

    assert_receive {FakeProgram, "start"}
    assert_receive {FakeProgram, "encoding h264 cq 8000000 30 0 0 auto auto"}
  end

  test "encodes as asked, from the start and while it runs", %{tmp_dir: tmp_dir} do
    {video, _program} =
      start_video(tmp_dir,
        fake: ~s(event "encoding $KVM_ENCODING"\n) <> @fake,
        encoding: [rate_control: :cbr, bitrate: 3_000_000]
      )

    assert_receive {FakeProgram, "encoding h264 cbr 3000000 24 0 0 auto auto"}

    assert Video.encoding(video) == %{
             codec: :auto,
             rate_control: :cbr,
             bitrate: 3_000_000,
             qp: 24,
             keyframe_interval: 0,
             max_fps: 0,
             color_matrix: :auto,
             color_range: :auto
           }

    assert %{codec: :h265, rate_control: :vbr, bitrate: 3_000_000, max_fps: 30} =
             Video.set_encoding(video, codec: :h265, rate_control: :vbr, max_fps: 30)

    assert_receive {FakeProgram, "command e h265 vbr 3000000 24 0 30 auto auto"}
    assert Video.codec(video) == :h265

    for changes <- [
          [qp: 52],
          [codec: :vp9],
          [rate_control: :abr],
          [bitrate: 0],
          [keyframe_interval: 65_536],
          [color_matrix: :bt2020],
          [color_range: :tv],
          [gop: 30]
        ] do
      assert_raise ArgumentError, fn -> Video.set_encoding(video, changes) end
    end

    assert Video.encoding(video).rate_control == :vbr
  end

  test "refuses bad options" do
    for opts <- [
          [jpeg_quality: 0],
          [jpeg_qualty: 60],
          [h264_qp: 30],
          [encoding: [qp: 60]],
          [encoding: %{rate_control: :abr}],
          [devices: %{capture: "/dev/video0"}],
          # A token goes in a URL as it is.
          [mjpeg_token: "short"],
          [mjpeg_token: "has spaces and & in it"]
        ] do
      assert_raise ArgumentError, fn -> Video.start_link([name: nil] ++ opts) end
    end
  end

  test "reads the EDID of the device", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "edid.bin"), @edid)

    program =
      FakeProgram.write!(
        Path.join(tmp_dir, "fake_edid"),
        ~s(if [ "$1" = /dev/video0 ]; then cat "#{tmp_dir}/edid.bin"; else echo garbage; fi\n)
      )

    assert Video.edid(device: "/dev/video0", program: program) == {:ok, @edid}
    assert Video.edid(device: "/dev/video1", program: program) == {:error, :invalid_edid}
    assert Video.edid(program: program) == {:error, :no_device}
  end

  test "reports why the EDID program failed", %{tmp_dir: tmp_dir} do
    program =
      FakeProgram.write!(
        Path.join(tmp_dir, "fake_edid"),
        "echo 'VIDIOC_G_EDID: Inappropriate ioctl' >&2\nexit 1\n"
      )

    assert Video.edid(device: "/dev/video0", program: program) ==
             {:error, {:exit_status, 1, "VIDIOC_G_EDID: Inappropriate ioctl"}}

    missing = Path.join(tmp_dir, "missing")

    assert Video.edid(device: "/dev/video0", program: missing) ==
             {:error, {:missing_program, missing}}
  end

  test "stores a valid EDID in hex", %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "stored")

    program =
      FakeProgram.write!(
        Path.join(tmp_dir, "fake_edid"),
        ~s(printf '%s %s' "$1" "$2" > "#{out}"\n)
      )

    assert Video.set_edid(@edid, device: "/dev/video0", program: program) == :ok
    assert File.read!(out) == "/dev/video0 " <> Base.encode16(@edid)

    File.rm!(out)
    assert_raise ArgumentError, fn -> Video.set_edid(<<1, 2, 3>>, program: program) end
    refute File.exists?(out)
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")

    assert {:error, {:missing_program, ^missing}} =
             Video.start_link(program: missing, name: nil)
  end
end
