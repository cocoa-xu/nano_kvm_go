defmodule NanoKVM.FakeGPIO do
  @moduledoc false
  # Circuits.GPIO for tests: the lines' values live in an Agent registered
  # under this module's name, which also sends each call that changes
  # something to the test.
  use Agent

  @spec start_link({%{String.t() => 0 | 1}, pid()}) :: Agent.on_start()
  def start_link({values, test}) do
    Agent.start_link(fn -> %{values: values, test: test} end, name: __MODULE__)
  end

  @spec open(String.t(), :input | :output, keyword()) :: {:ok, String.t()}
  def open(name, direction, opts) do
    if direction == :output, do: put(name, Keyword.fetch!(opts, :initial_value))
    tell({:open, name, direction})
    {:ok, name}
  end

  @spec read(String.t()) :: 0 | 1
  def read(name), do: Agent.get(__MODULE__, &Map.fetch!(&1.values, name))

  @spec write(String.t(), 0 | 1) :: :ok
  def write(name, value) do
    put(name, value)
    tell({:write, name, value})
  end

  @spec set_interrupts(String.t(), atom(), keyword()) :: :ok
  def set_interrupts(name, trigger, _opts), do: tell({:set_interrupts, name, trigger})

  @spec close(String.t()) :: :ok
  def close(name), do: tell({:close, name})

  defp put(name, value), do: Agent.update(__MODULE__, &put_in(&1.values[name], value))

  defp tell(call) do
    send(Agent.get(__MODULE__, & &1.test), {__MODULE__, call})
    :ok
  end
end
