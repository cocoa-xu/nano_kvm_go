defmodule NanoKVMGo.AudioTest do
  # One fake program at a time, as in NanoKVMGo.VideoTest.
  use ExUnit.Case, async: false

  alias NanoKVMGo.{Audio, FakeProgram, Peer, Wait}
  alias NanoKVMGo.Audio.Protocol

  @moduletag :tmp_dir

  # Stands in for nano_kvm_go_audio: reports the format, 44.1 kHz when given the
  # video device of the test, sends two periods of PCM, then waits for the
  # end of its stdin.
  @fake """
  printf '\\000\\000\\000\\010\\002'
  if [ "$5" = /dev/video7 ]; then printf '44100 2'; else printf '48000 2'; fi
  printf '\\000\\000\\000\\005\\001ABCD\\000\\000\\000\\005\\001EFGH'
  exec cat > /dev/null
  """

  setup %{tmp_dir: tmp_dir} do
    program = FakeProgram.write!(Path.join(tmp_dir, "fake_audio"), @fake)
    audio = start_supervised!({Audio, program: program, video_device: nil, name: nil})
    %{audio: audio, program: program}
  end

  test "captures while there are subscribers", %{audio: audio, program: program} do
    assert Audio.format(audio) == nil
    assert FakeProgram.runs(program) == []
    assert :ok = Audio.subscribe(audio)

    # The first program of a run can take a while to start.
    assert_receive {Audio, {:format, :hdmi, %{rate: 48_000, channels: 2}}}, 1_000
    assert_receive {Audio, {:pcm, :hdmi, "ABCD"}}
    assert_receive {Audio, {:pcm, :hdmi, "EFGH"}}
    assert Audio.format(audio) == %{rate: 48_000, channels: 2, sample_format: :s16_le}

    assert :ok = Audio.unsubscribe(audio)
    assert Audio.format(audio) == nil
    Wait.until(fn -> not FakeProgram.running?(program) end)
  end

  test "a subscriber that goes away stops the capture", %{audio: audio, program: program} do
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
    Wait.until(fn -> FakeProgram.running?(program) end)

    send(subscriber, :leave)
    Wait.until(fn -> not FakeProgram.running?(program) end)
  end

  test "sends to a subscriber on another node", %{audio: audio} do
    subscriber = Peer.spawn_caller(audio, :subscribe)

    # The format and two periods.
    Wait.until(fn -> Peer.message_queue_len(subscriber) == 3 end)
    assert Audio.format(audio) == %{rate: 48_000, channels: 2, sample_format: :s16_le}
  end

  test "hands the video device with the rate control to the program", %{program: program} do
    audio =
      start_supervised!({Audio, program: program, video_device: "/dev/video7", name: nil},
        id: :with_video_device
      )

    assert :ok = Audio.subscribe(audio)
    assert_receive {Audio, {:format, :hdmi, %{rate: 44_100, channels: 2}}}, 1_000
  end

  @tag :capture_log
  test "stops a capture whose program exits as the last subscriber leaves",
       %{tmp_dir: tmp_dir} do
    program = FakeProgram.write!(Path.join(tmp_dir, "quiet_audio"), "exec cat > /dev/null\n")
    audio = start_supervised!({Audio, program: program, name: nil}, id: :quiet)
    test = self()

    subscriber =
      spawn(fn ->
        :ok = Audio.subscribe(audio)
        send(test, :subscribed)
        receive do: (:leave -> :ok)
      end)

    assert_receive :subscribed
    Wait.until(fn -> FakeProgram.running?(program) end)
    port = FakeProgram.port(audio)

    :ok = :sys.suspend(audio)
    send(subscriber, :leave)
    Wait.until(fn -> Process.info(audio, :message_queue_len) == {:message_queue_len, 1} end)
    FakeProgram.kill(program)
    Wait.until(fn -> Port.info(port) == nil end)
    :ok = :sys.resume(audio)

    assert Audio.format(audio) == nil
  end

  test "captures the USB speaker with source: :usb", %{tmp_dir: tmp_dir} do
    program =
      FakeProgram.write!(Path.join(tmp_dir, "fake_usb_audio"), """
      printf '\\000\\000\\000\\010\\002'
      if [ "$1 $#" = "hw:CARD=UAC2Gadget,DEV=0 4" ]; then printf '32000 2'; else printf '48000 2'; fi
      exec cat > /dev/null
      """)

    audio = start_supervised!({Audio, program: program, source: :usb, name: nil}, id: :usb)

    assert :ok = Audio.subscribe(audio)
    assert_receive {Audio, {:format, :usb, %{rate: 32_000, channels: 2}}}, 1_000
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

  test "refuses bad options" do
    for opts <- [[source: :spdif], [period_ms: 0], [rate: 44_100.0], [sources: :usb]] do
      assert_raise ArgumentError, fn -> Audio.start_link([name: nil] ++ opts) end
    end
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")
    assert {:error, {:missing_program, ^missing}} = Audio.start_link(program: missing, name: nil)
  end

  test "decodes the packets of the port program" do
    assert Protocol.decode(<<0, "open">>) == {:log, "open"}
    assert Protocol.decode(<<1, 1, 0, 255, 255>>) == {:pcm, <<1, 0, 255, 255>>}

    assert Protocol.decode(<<2, "44100 2">>) ==
             {:format, %{rate: 44_100, channels: 2, sample_format: :s16_le}}

    assert Protocol.decode(<<2, "96000 1 S24_3LE">>) ==
             {:format, %{rate: 96_000, channels: 1, sample_format: :s24_3le}}

    assert Protocol.decode(<<2, "48000 2 FLOAT_LE">>) == :unknown
    assert Protocol.decode(<<2, "fast">>) == :unknown
    assert Protocol.decode(<<7>>) == :unknown
  end
end
