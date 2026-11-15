defmodule NanoKVM.TouchTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Touch

  @moduletag :tmp_dir

  defp event(type, code, value), do: <<0::64, type::little-16, code::little-16, value::little-signed-32>>
  defp touch(x, y, down), do: event(3, 0, x) <> event(3, 1, y) <> event(1, 0x14A, down) <> event(0, 0, 0)

  test "touches become down, move and up", %{tmp_dir: tmp_dir} do
    device = Path.join(tmp_dir, "event0")
    {_, 0} = System.cmd("mkfifo", [device])
    touch = start_supervised!({Touch, device: device, name: nil})
    :ok = Touch.subscribe(touch)

    # The reader has the FIFO open by now; opening it for writing waits for it.
    {:ok, fifo} = File.open(device, [:write, :raw, :binary])

    :ok =
      :file.write(
        fifo,
        touch(10, 20, 1) <> touch(10, 20, 1) <> touch(15, 25, 1) <> touch(15, 25, 0)
      )

    assert_receive {Touch, {:down, 10, 20}}, 1_000
    assert_receive {Touch, {:move, 15, 25}}, 1_000
    assert_receive {Touch, {:up, 15, 25}}, 1_000
    refute_receive {Touch, _}, 100
    File.close(fifo)
  end
end
