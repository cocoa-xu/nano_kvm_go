defmodule NanoKVMGo.TouchTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.{FakeProgram, Touch}

  @moduletag :tmp_dir

  # A packet of the events of a touch, as nano_kvm_go_input sends one.
  defp touch(x, y, down) do
    payload =
      for {type, code, value} <- [{3, 0, x}, {3, 1, y}, {1, 0x14A, down}, {0, 0, 0}],
          into: <<1>>,
          do: <<type::little-16, code::little-16, value::little-signed-32>>

    <<byte_size(payload)::32, payload::binary>>
  end

  test "touches become down, move and up", %{tmp_dir: tmp_dir} do
    # The device is a FIFO that the fake program passes on.
    device = Path.join(tmp_dir, "event0")
    {_, 0} = System.cmd("mkfifo", [device])
    program = FakeProgram.write!(Path.join(tmp_dir, "fake_input"), ~s(exec cat "$1"\n))
    touch = start_supervised!({Touch, device: device, program: program, name: nil})
    :ok = Touch.subscribe(touch)

    {:ok, fifo} = File.open(device, [:write, :raw, :binary])

    :ok =
      :file.write(
        fifo,
        touch(10, 20, 1) <> touch(10, 20, 1) <> touch(15, 25, 1) <> touch(15, 25, 0)
      )

    # The last event: what the others gave came before it.
    assert_receive {Touch, {:down, 10, 20}}
    assert_receive {Touch, {:move, 15, 25}}
    assert_receive {Touch, {:up, 15, 25}}
    refute_received {Touch, _}

    :ok = stop_supervised(Touch)
    File.close(fifo)
  end

  test "stops without the port program", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    missing = Path.join(tmp_dir, "missing")
    assert {:error, {:missing_program, ^missing}} = Touch.start_link(program: missing, name: nil)
  end
end
