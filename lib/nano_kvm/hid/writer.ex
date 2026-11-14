defmodule NanoKVM.HID.Writer do
  @moduledoc false
  # Writes reports to one /dev/hidg* device, linked to NanoKVM.HID.
  #
  # A write blocks until the target computer has taken the previous report,
  # and for as long as it does not poll (unplugged, asleep), so writes happen
  # in this process. Each report holds the whole state of its device, so when
  # reports pile up only the newest is written: no key stays held and no
  # stale input is replayed later.
  require Logger

  @collapse_at 8

  @spec start_link(Path.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(path), do: :proc_lib.start_link(__MODULE__, :init, [path])

  @spec write(pid(), binary()) :: :ok
  def write(writer, report) do
    send(writer, {:report, report})
    :ok
  end

  @doc false
  # Raw files belong to the process that opens them: open here. Opening for
  # writing creates missing files, which in /dev would stand in the way of
  # the device node: only open what is there (regular files in tests).
  def init(path) do
    with {:ok, %File.Stat{type: type}} when type in [:device, :regular] <- File.stat(path),
         {:ok, device} <- File.open(path, [:write, :raw, :binary]) do
      :proc_lib.init_ack({:ok, self()})
      loop(path, device)
    else
      {:ok, %File.Stat{type: type}} -> :proc_lib.init_ack({:error, {:not_a_device, type}})
      {:error, reason} -> :proc_lib.init_ack({:error, reason})
    end
  end

  defp loop(path, device) do
    receive do
      {:report, report} ->
        case :file.write(device, newest(report)) do
          :ok ->
            loop(path, device)

          {:error, reason} ->
            # The gadget went away (rebind, unplug): NanoKVM.HID opens it again.
            Logger.info("nano_kvm: #{path}: #{inspect(reason)}")
            exit({:shutdown, reason})
        end
    end
  end

  defp newest(report) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} when n >= @collapse_at -> drain(report)
      _ -> report
    end
  end

  defp drain(report) do
    receive do
      {:report, newer} -> drain(newer)
    after
      0 -> report
    end
  end
end
