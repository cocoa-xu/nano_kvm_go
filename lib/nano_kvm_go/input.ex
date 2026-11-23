defmodule NanoKVMGo.Input do
  @moduledoc false
  # Linux input devices, found by their names and read by the
  # nano_kvm_go_input port program: {:packet, 4} frames of a type byte and a
  # payload, 0 a log line, 1 the events of one read, 8 bytes each. The end
  # of its stdin stops it.

  @input_class "/sys/class/input"

  @type event() :: {type :: non_neg_integer(), code :: non_neg_integer(), value :: integer()}

  @spec program() :: Path.t()
  def program, do: Application.app_dir(:nano_kvm_go, "priv/nano_kvm_go_input")

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

  @spec open(Path.t(), Path.t()) :: port()
  def open(program, device) do
    Port.open({:spawn_executable, program}, [:binary, {:packet, 4}, :exit_status, args: [device]])
  end

  @spec decode(binary()) :: {:events, [event()]} | {:log, String.t()} | :unknown
  def decode(<<0, line::binary>>), do: {:log, line}

  def decode(<<1, events::binary>>) do
    {:events,
     for(
       <<type::little-16, code::little-16, value::little-signed-32 <- events>>,
       do: {type, code, value}
     )}
  end

  def decode(_packet), do: :unknown
end
