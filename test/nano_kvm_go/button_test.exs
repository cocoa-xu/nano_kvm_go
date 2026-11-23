defmodule NanoKVMGo.ButtonTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.{Button, FakeProgram}

  @moduletag :tmp_dir

  # A packet of events, as nano_kvm_go_input sends one.
  defp events(events) do
    payload =
      for {type, code, value} <- events,
          into: <<1>>,
          do: <<type::little-16, code::little-16, value::little-signed-32>>

    <<byte_size(payload)::32, payload::binary>>
  end

  test "presses become down and up, the rest is left out", %{tmp_dir: tmp_dir} do
    # The device is a FIFO that the fake program passes on.
    device = Path.join(tmp_dir, "event1")
    {_, 0} = System.cmd("mkfifo", [device])
    program = FakeProgram.write!(Path.join(tmp_dir, "fake_input"), ~s(exec cat "$1"\n))
    button = start_supervised!({Button, device: device, program: program, name: nil})
    :ok = Button.subscribe(button)

    {:ok, fifo} = File.open(device, [:write, :raw, :binary])

    :ok =
      :file.write(
        fifo,
        events([{1, 148, 1}, {0, 0, 0}, {1, 148, 2}, {1, 30, 1}]) <> events([{1, 148, 0}])
      )

    assert_receive {Button, :down}, 1_000
    assert_receive {Button, :up}, 1_000
    refute_receive {Button, _}, 100

    :ok = stop_supervised(Button)
    File.close(fifo)
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")
    assert {:error, {:missing_program, ^missing}} = Button.start_link(program: missing, name: nil)
  end
end
