defmodule NanoKVMGo.MicrophoneTest do
  # One fake program at a time, as in NanoKVMGo.AudioTest.
  use ExUnit.Case, async: false

  alias NanoKVMGo.{FakeProgram, Microphone, Wait}

  @moduletag :tmp_dir

  # Stands in for nano_kvm_go_playback: reports a format, keeps its arguments
  # and what it is sent.
  defp fake_program(tmp_dir) do
    received = Path.join(tmp_dir, "received")

    program =
      FakeProgram.write!(Path.join(tmp_dir, "fake_playback"), """
      echo "$@" > #{tmp_dir}/args
      printf '\\000\\000\\000\\020\\002'
      printf '44100 1 S24_3LE'
      exec cat > #{received}
      """)

    {program, received}
  end

  test "plays what it is sent through the program", %{tmp_dir: tmp_dir} do
    {program, received} = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, name: nil})

    assert FakeProgram.runs(program) == []
    :ok = Microphone.play(mic, <<1, 0, 2, 0>>)
    :ok = Microphone.play(mic, <<3, 0>>)

    Wait.until(fn ->
      File.read(received) == {:ok, <<0, 0, 0, 4, 1, 0, 2, 0, 0, 0, 0, 2, 3, 0>>}
    end)

    assert File.read!(Path.join(tmp_dir, "args")) == "hw:CARD=UAC2Gadget,DEV=0 20\n"
  end

  test "tells subscribers the format", %{tmp_dir: tmp_dir} do
    {program, _received} = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, idle_ms: 100, name: nil})

    assert Microphone.format(mic) == nil
    assert :ok = Microphone.subscribe(mic)

    format = %{rate: 44_100, channels: 1, sample_format: :s24_3le}
    assert_receive {Microphone, {:format, ^format}}, 1_000
    assert Microphone.format(mic) == format

    # Subscribers keep the stream past the idle time.
    Process.sleep(200)
    assert FakeProgram.running?(program)

    assert :ok = Microphone.unsubscribe(mic)
    Wait.until(fn -> not FakeProgram.running?(program) end)
  end

  test "stops the program after a while without samples", %{tmp_dir: tmp_dir} do
    {program, _received} = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, idle_ms: 100, name: nil})

    :ok = Microphone.play(mic, <<0, 0>>)
    Wait.until(fn -> FakeProgram.runs(program) != [] and not FakeProgram.running?(program) end)
  end

  @tag :capture_log
  test "takes samples that come as the program exits", %{tmp_dir: tmp_dir} do
    {program, _received} = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, name: nil})
    :ok = Microphone.play(mic, <<0, 0>>)
    Wait.until(fn -> FakeProgram.running?(program) end)
    port = FakeProgram.port(mic)

    :ok = :sys.suspend(mic)
    :ok = Microphone.play(mic, <<1, 0>>)
    FakeProgram.kill(program)
    Wait.until(fn -> Port.info(port) == nil end)
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
