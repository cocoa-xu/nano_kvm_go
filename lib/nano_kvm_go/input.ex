defmodule NanoKVMGo.Input do
  @moduledoc false
  # Linux input devices: found by name, read in a linked process that sends
  # the owner {:events, binary} of whole struct input_event (16 bytes on a
  # 32-bit kernel), and exits when the device goes away.

  @input_class "/sys/class/input"
  @event_size 16

  @spec event_size() :: pos_integer()
  def event_size, do: @event_size

  @doc "The event device of the input device whose name starts with `name`."
  @spec find(String.t()) :: Path.t() | nil
  def find(name) do
    case File.ls(@input_class) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, "event"))
        |> Enum.find_value(&with_name(&1, name))

      {:error, _reason} ->
        nil
    end
  end

  defp with_name(event, name) do
    case File.read(Path.join([@input_class, event, "device", "name"])) do
      {:ok, ^name <> _rest} -> Path.join("/dev/input", event)
      _other -> nil
    end
  end

  @doc "Starts the linked reader of a device."
  @spec start_reader(pid(), Path.t()) :: pid()
  def start_reader(owner, device), do: spawn_link(fn -> read(owner, device) end)

  # Raw files block only their own process: reading waits here.
  defp read(owner, device) do
    case File.open(device, [:read, :raw, :binary]) do
      {:ok, file} -> loop(owner, file)
      {:error, reason} -> exit(reason)
    end
  end

  # An event a read: a raw read waits until it has all the bytes asked for.
  defp loop(owner, file) do
    case :file.read(file, @event_size) do
      {:ok, data} ->
        send(owner, {:events, data})
        loop(owner, file)

      :eof ->
        exit(:eof)

      {:error, reason} ->
        exit(reason)
    end
  end
end
