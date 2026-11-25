defmodule NanoKVMGo.VideoTest do
  # One fake program at a time: started together, they would hold each
  # other's pipes open.
  use ExUnit.Case, async: false

  alias NanoKVMGo.{FakeProgram, Peer, Video}

  @moduletag :tmp_dir

  @devices %{capture: "/dev/null", jpeg: "/dev/null", encoder: "/dev/null"}

  # Stands in for nano_kvm_go_video: reports an input, then reports each
  # command it gets as an event and answers the stream commands ("1" start,
  # "k" keyframe) with {:packet, 4} frames, until its stdin ends. A command
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
      1) env printf '\\000\\000\\000\\004\\002KEY\\000\\000\\000\\004\\001DEL' ;;
      k) env printf '\\000\\000\\000\\004\\002KEY' ;;
    esac
  done
  """

  # One block, no name or modes, with a valid checksum.
  @edid <<0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>> <>
          :binary.copy(<<0>>, 119) <> <<6>>

  # A capture of a fake program, once the program runs.
  defp start_video(tmp_dir, opts \\ []) do
    {fake, opts} = Keyword.pop(opts, :fake, @fake)
    program = FakeProgram.write!(Path.join(tmp_dir, "fake_video"), fake)
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
    assert_receive {:trace, ^video, :receive, {_port, {:data, <<2, "KEY">>}}}
    _codec = Video.codec(video)
    refute_received {Video, _message}
  end

  test "tells subscribers the codec of each access unit", %{tmp_dir: tmp_dir} do
    # Packet types 5 and 4: an H.265 keyframe and delta.
    h265 =
      @fake
      |> String.replace("\\002KEY", "\\005KEY")
      |> String.replace("\\001DEL", "\\004DEL")

    {video, _program} = start_video(tmp_dir, fake: h265)
    assert :ok = Video.subscribe(video)

    assert_receive {Video, {:h265, :key, "KEY"}}
    assert_receive {Video, {:h265, :delta, "DEL"}}
  end

  test "takes H.265 while every subscriber decodes it", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    assert Video.codec(video) == :h264

    assert :ok = Video.subscribe(video, codecs: [:h264, :h265])
    assert_receive {FakeProgram, "command e h265 vbr 8000000 24 600 0 auto auto"}
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
    assert_receive {FakeProgram, "command e h264 vbr 8000000 24 600 0 auto auto"}
    assert Video.codec(video) == :h264

    send(h264_only, :leave)
    assert_receive {FakeProgram, "command e h265 vbr 8000000 24 600 0 auto auto"}

    assert_raise ArgumentError, fn -> Video.subscribe(video, codecs: []) end
    assert_raise ArgumentError, fn -> Video.subscribe(video, codecs: [:vp9]) end
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

    assert_receive {FakeProgram, "encoding h264 cbr 3000000 24 600 0 auto auto"}

    Agent.update(saved, fn _encoding -> [rate_control: :constant_qp, qp: 30] end)
    Process.exit(video, :kill)

    assert_receive {FakeProgram, "start"}
    assert_receive {FakeProgram, "encoding h264 cq 8000000 30 600 0 auto auto"}
  end

  test "encodes as asked, from the start and while it runs", %{tmp_dir: tmp_dir} do
    {video, _program} =
      start_video(tmp_dir,
        fake: ~s(event "encoding $KVM_ENCODING"\n) <> @fake,
        encoding: [rate_control: :cbr, bitrate: 3_000_000]
      )

    assert_receive {FakeProgram, "encoding h264 cbr 3000000 24 600 0 auto auto"}

    assert Video.encoding(video) == %{
             codec: :auto,
             rate_control: :cbr,
             bitrate: 3_000_000,
             qp: 24,
             keyframe_interval: 600,
             max_fps: 0,
             color_matrix: :auto,
             color_range: :auto
           }

    assert %{codec: :h265, rate_control: :vbr, bitrate: 3_000_000, max_fps: 30} =
             Video.set_encoding(video, codec: :h265, rate_control: :vbr, max_fps: 30)

    assert_receive {FakeProgram, "command e h265 vbr 3000000 24 600 30 auto auto"}
    assert Video.codec(video) == :h265

    for changes <- [
          [qp: 52],
          [codec: :vp9],
          [rate_control: :abr],
          [bitrate: 0],
          [keyframe_interval: 0],
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
