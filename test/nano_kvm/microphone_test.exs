defmodule NanoKVM.MicrophoneTest do
  # One fake program at a time, as in NanoKVM.AudioTest.
  use ExUnit.Case, async: false

  alias NanoKVM.Microphone

  @moduletag :tmp_dir

  # Stands in for nano_kvm_playback: keeps its arguments and what it is sent.
  defp fake_program(tmp_dir) do
    program = Path.join(tmp_dir, "fake_playback")
    received = Path.join(tmp_dir, "received")

    File.write!(program, """
    #!/bin/sh
    echo "$@" > #{tmp_dir}/args
    exec cat > #{received}
    """)

    File.chmod!(program, 0o755)
    {program, received}
  end

  test "plays what it is sent through the program", %{tmp_dir: tmp_dir} do
    {program, received} = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, name: nil})

    assert %{port: nil} = :sys.get_state(mic)
    :ok = Microphone.play(mic, <<1, 0, 2, 0>>)
    :ok = Microphone.play(mic, <<3, 0>>)
    kill_on_exit(mic)

    assert wait_for(fn ->
             File.read(received) == {:ok, <<0, 0, 0, 4, 1, 0, 2, 0, 0, 0, 0, 2, 3, 0>>}
           end)

    assert File.read!(Path.join(tmp_dir, "args")) == "hw:CARD=UAC2Gadget,DEV=0 48000 1 960\n"
  end

  test "stops the program after a while without samples", %{tmp_dir: tmp_dir} do
    {program, _received} = fake_program(tmp_dir)
    mic = start_supervised!({Microphone, program: program, idle_ms: 100, name: nil})

    :ok = Microphone.play(mic, <<0, 0>>)
    kill_on_exit(mic)
    assert wait_for(fn -> match?(%{port: nil}, :sys.get_state(mic)) end)
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")

    assert {:error, {:missing_program, ^missing}} =
             Microphone.start_link(program: missing, name: nil)
  end

  defp wait_for(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(check, tries - 1)
    end
  end

  # Whatever happens to its stdin, the program does not outlive the test.
  defp kill_on_exit(mic) do
    {:os_pid, os_pid} = Port.info(:sys.get_state(mic).port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)
  end
end
