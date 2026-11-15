defmodule NanoKVM.FakeKV do
  @moduledoc false
  # Nerves.Runtime.KV for tests: sends what is put to the process registered
  # under this module's name.

  @spec put(%{String.t() => String.t()}) :: :ok
  def put(variables) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {__MODULE__, variables})
    end

    :ok
  end
end
