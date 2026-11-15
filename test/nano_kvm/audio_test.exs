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

  test "captures from the first subscriber on", %{audio: audio} do
    assert Audio.format(audio) == nil
    assert :ok = Audio.subscribe(audio)
    kill_on_exit(audio)

    # The first program of a run can take a while to start.
    assert_receive {Audio, {:format, %{rate: 48_000, channels: 2}}}, 1_000
    assert_receive {Audio, {:pcm, "ABCD"}}
    assert_receive {Audio, {:pcm, "EFGH"}}
    assert Audio.format(audio) == %{rate: 48_000, channels: 2}

    # The capture goes on: restarting it can leave the bridge silent.
    assert :ok = Audio.unsubscribe(audio)
    assert %{port: port, subscribers: subscribers} = :sys.get_state(audio)
    assert is_port(port) and subscribers == %{}
    assert Audio.format(audio) == %{rate: 48_000, channels: 2}

    # A new subscriber gets the format of the running capture at once.
    assert :ok = Audio.subscribe(audio)
    assert_receive {Audio, {:format, %{rate: 48_000, channels: 2}}}
    assert %{port: ^port} = :sys.get_state(audio)
  end

  test "drops a subscriber that goes away", %{audio: audio} do
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

    assert %{port: port, subscribers: subscribers} = :sys.get_state(audio)
    assert is_port(port) and subscribers == %{}
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
