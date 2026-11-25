defmodule NanoKVMGo.MicrophoneTest do
  # One fake program at a time, as in NanoKVMGo.AudioTest.
  use ExUnit.Case, async: false

  alias NanoKVMGo.{FakeProgram, Microphone}

  @moduletag :tmp_dir

  # Stands in for nano_kvm_go_playback: reports its arguments and a format,
  # then each chunk it is sent, in hex, as events.
  defp fake_program(tmp_dir) do
    FakeProgram.write!(Path.join(tmp_dir, "fake_playback"), """
    event "args $*"
    printf '\\000\\000\\000\\020\\002'
    printf '44100 1 S24_3LE'
    while chunk=$(dd bs=4096 count=1 2>/dev/null | od -An -tx1 -v | tr -d ' \\n') &&
          [ -n "$chunk" ]; do
      event "received $chunk"
    done
    """)
  end

  # What the program was sent, once it has the bytes of `size`.
  defp received(size, bytes \\ "")

  defp received(size, bytes) when byte_size(bytes) < size do
    receive do
      {FakeProgram, "received " <> hex} ->
        received(size, bytes <> Base.decode16!(hex, case: :lower))
    after
      1_000 -> flunk("the program got #{inspect(bytes)}")
    end
  end

  defp received(_size, bytes), do: bytes

  test "plays what it is sent through the program", %{tmp_dir: tmp_dir} do
    program = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, name: nil})

    assert FakeProgram.runs(program) == []
    :ok = Microphone.play(mic, <<1, 0, 2, 0>>)
    :ok = Microphone.play(mic, <<3, 0>>)

    assert_receive {FakeProgram, "args hw:CARD=UAC2Gadget,DEV=0 20"}, 1_000
    assert received(14) == <<0, 0, 0, 4, 1, 0, 2, 0, 0, 0, 0, 2, 3, 0>>
  end

  test "tells subscribers the format", %{tmp_dir: tmp_dir} do
    program = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, idle_ms: 100, name: nil})

    assert Microphone.format(mic) == nil
    assert :ok = Microphone.subscribe(mic)

    format = %{rate: 44_100, channels: 1, sample_format: :s24_3le}
    assert_receive {Microphone, {:format, ^format}}, 1_000
    assert Microphone.format(mic) == format

    # Subscribers keep the stream past the idle time of samples.
    :ok = Microphone.play(mic, <<0, 0, 0>>)
    refute_receive {FakeProgram, "exit"}, 200

    assert :ok = Microphone.unsubscribe(mic)
    assert_receive {FakeProgram, "exit"}
  end

  test "stops the program after a while without samples", %{tmp_dir: tmp_dir} do
    program = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, idle_ms: 100, name: nil})
    :ok = Microphone.play(mic, <<0, 0>>)

    assert_receive {FakeProgram, "start"}, 1_000
    assert_receive {FakeProgram, "exit"}, 1_000
  end

  @tag :capture_log
  test "takes samples that come as the program exits", %{tmp_dir: tmp_dir} do
    program = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, name: nil})
    :ok = Microphone.play(mic, <<0, 0>>)
    assert_receive {FakeProgram, "start"}, 1_000
    port = FakeProgram.port(mic)
    ref = Port.monitor(port)

    # The samples wait in the queue while the program dies.
    :ok = :sys.suspend(mic)
    :ok = Microphone.play(mic, <<1, 0>>)
    FakeProgram.kill(program)
    assert_receive {:DOWN, ^ref, :port, ^port, _reason}
    :ok = :sys.resume(mic)

    assert Microphone.format(mic) == nil
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")

    assert {:error, {:missing_program, ^missing}} =
             Microphone.start_link(program: missing, name: nil)
  end
end
