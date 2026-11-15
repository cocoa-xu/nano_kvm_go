defmodule NanoKVM.AudioTest do
  # One fake program at a time, as in NanoKVM.VideoTest.
  use ExUnit.Case, async: false

  alias NanoKVM.Audio
  alias NanoKVM.Audio.Protocol

  @moduletag :tmp_dir

  # Stands in for nano_kvm_audio: reports the format, 44.1 kHz when given the
  # video device of the test, sends two periods of PCM, then waits for the
  # end of its stdin.
  @fake """
  #!/bin/sh
  printf '\\000\\000\\000\\010\\002'
  if [ "$5" = /dev/video7 ]; then printf '44100 2'; else printf '48000 2'; fi
  printf '\\000\\000\\000\\005\\001ABCD\\000\\000\\000\\005\\001EFGH'
  exec cat > /dev/null
  """

  setup %{tmp_dir: tmp_dir} do
    program = Path.join(tmp_dir, "fake_audio")
    File.write!(program, @fake)
    File.chmod!(program, 0o755)
    audio = start_supervised!({Audio, program: program, video_device: nil, name: nil})
    %{audio: audio, program: program}
  end

  test "captures while there are subscribers", %{audio: audio} do
    assert Audio.format(audio) == nil
    assert :ok = Audio.subscribe(audio)
    kill_on_exit(audio)

    # The first program of a run can take a while to start.
    assert_receive {Audio, {:format, %{rate: 48_000, channels: 2}}}, 1_000
    assert_receive {Audio, {:pcm, "ABCD"}}
    assert_receive {Audio, {:pcm, "EFGH"}}
    assert Audio.format(audio) == %{rate: 48_000, channels: 2}

    assert :ok = Audio.unsubscribe(audio)
    assert %{port: nil} = :sys.get_state(audio)
    assert Audio.format(audio) == nil
  end

  test "a subscriber that goes away stops the capture", %{audio: audio} do
    test = self()

    subscriber =
      spawn(fn ->
        :ok = Audio.subscribe(audio)
        send(test, :subscribed)

        receive do
          :leave -> :ok
        end
      end)

    assert_receive :subscribed
    kill_on_exit(audio)

    ref = Process.monitor(subscriber)
    send(subscriber, :leave)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert %{port: nil, subscribers: subscribers} = :sys.get_state(audio)
    assert subscribers == %{}
  end

  test "hands the video device with the rate control to the program", %{program: program} do
    audio =
      start_supervised!({Audio, program: program, video_device: "/dev/video7", name: nil},
        id: :with_video_device
      )

    assert :ok = Audio.subscribe(audio)
    kill_on_exit(audio)
    assert_receive {Audio, {:format, %{rate: 44_100, channels: 2}}}, 1_000
  end

  test "captures the USB speaker with source: :usb", %{tmp_dir: tmp_dir} do
    program = Path.join(tmp_dir, "fake_usb_audio")

    File.write!(program, """
    #!/bin/sh
    printf '\\000\\000\\000\\010\\002'
    if [ "$1 $#" = "hw:CARD=UAC2Gadget,DEV=0 4" ]; then printf '32000 2'; else printf '48000 2'; fi
    exec cat > /dev/null
    """)

    File.chmod!(program, 0o755)
    audio = start_supervised!({Audio, program: program, source: :usb, name: nil}, id: :usb)

    assert :ok = Audio.subscribe(audio)
    kill_on_exit(audio)
    assert_receive {Audio, {:format, %{rate: 32_000, channels: 2}}}, 1_000
  end

  test "processes for both sources fit in one supervisor", %{program: program} do
    children = [
      {Audio, program: program, video_device: nil},
      {Audio, program: program, source: :usb, name: :usb_speaker}
    ]

    assert {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    assert [:usb_speaker, Audio] = Enum.map(Supervisor.which_children(sup), &elem(&1, 0))
    Supervisor.stop(sup)
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")
    assert {:error, {:missing_program, ^missing}} = Audio.start_link(program: missing, name: nil)
  end

  test "decodes the packets of the port program" do
    assert Protocol.decode(<<0, "open">>) == {:log, "open"}
    assert Protocol.decode(<<1, 1, 0, 255, 255>>) == {:pcm, <<1, 0, 255, 255>>}
    assert Protocol.decode(<<2, "44100 2">>) == {:format, %{rate: 44_100, channels: 2}}
    assert Protocol.decode(<<2, "fast">>) == :unknown
    assert Protocol.decode(<<7>>) == :unknown
  end

  # Whatever happens to its stdin, the program does not outlive the test.
  defp kill_on_exit(audio) do
    {:os_pid, os_pid} = Port.info(:sys.get_state(audio).port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)
  end
end
