defmodule NanoKVMGo.Wait do
  @moduledoc false

  import ExUnit.Assertions, only: [flunk: 1]

  @spec until((-> as_boolean(term())), non_neg_integer()) :: :ok
  def until(condition, tries \\ 200) do
    cond do
      condition.() ->
        :ok

      tries == 0 ->
        flunk("the condition never held")

      true ->
        Process.sleep(10)
        until(condition, tries - 1)
    end
  end
end
