defmodule NanoKVMGo.VideoTest do
  # One fake program at a time: started together, they would hold each
  # other's pipes open.
  use ExUnit.Case, async: false

  alias NanoKVMGo.{FakeProgram, Peer, Video, Wait}

  @moduletag :tmp_dir

  # Stands in for nano_kvm_go_video: reports an input, then answers the H.264
  # commands ("1" start, "k" keyframe) with {:packet, 4} frames until its
  # stdin ends. Each command comes {:packet, 4} framed too, 5 bytes. The
  # shell's own printf would leave what it failed to write, once the port
  # is gone, to the command substitution, which would then loop forever.
  @fake """
  env printf '\\000\\000\\000\\015\\003'
  env printf '1920x1080@60'
  while c=$(dd bs=5 count=1 2>/dev/null | tail -c 1) && [ -n "$c" ]; do
    case "$c" in
      1) env printf '\\000\\000\\000\\004\\002KEY\\000\\000\\000\\004\\001DEL' ;;
      k) env printf '\\000\\000\\000\\004\\002KEY' ;;
    esac
  done
  """

  # A capture of the fake program, once it runs.
  defp start_video(tmp_dir) do
    program = FakeProgram.write!(Path.join(tmp_dir, "fake_video"), @fake)
    devices = %{capture: "/dev/null", jpeg: "/dev/null", h264: "/dev/null"}
    video = start_supervised!({Video, program: program, devices: devices, name: nil})
    Wait.until(fn -> Video.input(video) != nil end)
    {video, program}
  end

  test "reports the input and streams H.264 to subscribers", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    assert :ok = Video.subscribe(video)

    assert_receive {Video, {:input, %{width: 1920, height: 1080, fps: 60}}}, 1_000
    assert_receive {Video, {:h264, :key, "KEY"}}
    assert_receive {Video, {:h264, :delta, "DEL"}}

    Video.request_keyframe(video)
    assert_receive {Video, {:h264, :key, "KEY"}}

    assert :ok = Video.unsubscribe(video)
    Video.request_keyframe(video)
    refute_receive {Video, _event}, 100
  end

  test "streams to a subscriber on another node", %{tmp_dir: tmp_dir} do
    {video, _program} = start_video(tmp_dir)
    subscriber = Peer.spawn_caller(video, :subscribe)

    # The input, a keyframe and a delta.
    Wait.until(fn -> Peer.message_queue_len(subscriber) == 3 end)
    assert Video.input(video) == %{width: 1920, height: 1080, fps: 60}
  end

  @tag :capture_log
  test "takes a command that comes as the program exits", %{tmp_dir: tmp_dir} do
    {video, program} = start_video(tmp_dir)
    port = FakeProgram.port(video)

    :ok = :sys.suspend(video)
    Video.request_keyframe(video)
    FakeProgram.kill(program)
    Wait.until(fn -> Port.info(port) == nil end)
    :ok = :sys.resume(video)

    assert Video.input(video) == %{width: 1920, height: 1080, fps: 60}
  end

  test "refuses bad options" do
    for opts <- [
          [jpeg_quality: 0],
          [jpeg_qualty: 60],
          [devices: %{capture: "/dev/video0"}],
          # A token goes in a URL as it is.
          [mjpeg_token: "short"],
          [mjpeg_token: "has spaces and & in it"]
        ] do
      assert_raise ArgumentError, fn -> Video.start_link([name: nil] ++ opts) end
    end
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")

    assert {:error, {:missing_program, ^missing}} =
             Video.start_link(program: missing, name: nil)
  end
end
