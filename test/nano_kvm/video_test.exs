defmodule NanoKVM.VideoTest do
  # One fake program at a time: started together, they would hold each
  # other's pipes open.
  use ExUnit.Case, async: false

  alias NanoKVM.Video

  @moduletag :tmp_dir

  # Stands in for nano_kvm_video: reports an input, then answers the H.264
  # commands ("1" start, "k" keyframe) with {:packet, 4} frames until its
  # stdin ends. Each command comes {:packet, 4} framed too, 5 bytes.
  @fake """
  #!/bin/sh
  printf '\\000\\000\\000\\015\\003'
  printf '1920x1080@60'
  while c=$(dd bs=5 count=1 2>/dev/null | tail -c 1) && [ -n "$c" ]; do
    case "$c" in
      1) printf '\\000\\000\\000\\004\\002KEY\\000\\000\\000\\004\\001DEL' ;;
      k) printf '\\000\\000\\000\\004\\002KEY' ;;
    esac
  done
  """

  setup %{tmp_dir: tmp_dir} do
    program = Path.join(tmp_dir, "fake_video")
    File.write!(program, @fake)
    File.chmod!(program, 0o755)

    devices = %{capture: "/dev/null", jpeg: "/dev/null", h264: "/dev/null"}
    video = start_supervised!({Video, program: program, devices: devices, name: nil})

    # Whatever happens to its stdin, the program does not outlive the test.
    _input = Video.input(video)
    {:os_pid, os_pid} = Port.info(:sys.get_state(video).port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    %{video: video}
  end

  test "reports the input and streams H.264 to subscribers", %{video: video} do
    wait_for_input(video)
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

  test "refuses bad options" do
    Process.flag(:trap_exit, true)
    assert {:error, {%ArgumentError{}, _stack}} = Video.start_link(jpeg_quality: 0, name: nil)

    # A token goes in a URL as it is.
    assert {:error, {%ArgumentError{}, _stack}} =
             Video.start_link(mjpeg_token: "short", name: nil)

    assert {:error, {%ArgumentError{}, _stack}} =
             Video.start_link(mjpeg_token: "has spaces and & in it", name: nil)
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")

    assert {:error, {:missing_program, ^missing}} =
             Video.start_link(program: missing, name: nil)
  end

  defp wait_for_input(video, tries \\ 100) do
    cond do
      Video.input(video) != nil -> :ok
      tries == 0 -> flunk("no input reported")
      true -> Process.sleep(10) && wait_for_input(video, tries - 1)
    end
  end
end
