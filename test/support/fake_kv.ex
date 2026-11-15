defmodule NanoKVMGo.FakeKV do
  @moduledoc false
  # Nerves.Runtime.KV for tests: gets from the application environment
  # (:nano_kvm_go, NanoKVMGo.FakeKV) and sends what is put to the process
  # registered under this module's name.

  @spec get(String.t()) :: String.t() | nil
  def get(variable), do: Application.get_env(:nano_kvm_go, __MODULE__, %{})[variable]

  @spec put(%{String.t() => String.t()}) :: :ok
  def put(variables) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {__MODULE__, variables})
    end

    :ok
  end
end
