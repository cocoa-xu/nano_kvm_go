defmodule NanoKVMGo.ButtonTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Button

  @moduletag :tmp_dir

  defp event(type, code, value),
    do: <<0::64, type::little-16, code::little-16, value::little-signed-32>>

  test "presses become down and up, the rest is left out", %{tmp_dir: tmp_dir} do
    device = Path.join(tmp_dir, "event1")
    {_, 0} = System.cmd("mkfifo", [device])
    button = start_supervised!({Button, device: device, name: nil})
    :ok = Button.subscribe(button)

    {:ok, fifo} = File.open(device, [:write, :raw, :binary])

    :ok =
      :file.write(
        fifo,
        event(1, 148, 1) <>
          event(0, 0, 0) <> event(1, 148, 2) <> event(1, 30, 1) <> event(1, 148, 0)
      )

    assert_receive {Button, :down}, 1_000
    assert_receive {Button, :up}, 1_000
    refute_receive {Button, _}, 100
    File.close(fifo)
  end
end
