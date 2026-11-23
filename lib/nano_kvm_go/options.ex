defmodule NanoKVMGo.Options do
  @moduledoc false

  @spec validate!(keyword(), [atom() | {atom(), term()}], (atom(), term() -> boolean())) ::
          keyword()
  def validate!(opts, defaults, valid?) do
    opts = Keyword.validate!(opts, defaults)

    for {key, value} <- opts, not valid?.(key, value) do
      raise ArgumentError, "invalid #{inspect(key)} option: #{inspect(value)}"
    end

    opts
  end
end
