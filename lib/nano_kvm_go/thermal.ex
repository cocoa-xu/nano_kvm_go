defmodule NanoKVMGo.Thermal do
  @moduledoc false

  @zone "soc-thermal"

  @spec temperature(Path.t()) :: {:ok, float()} | {:error, term()}
  def temperature(root \\ "/") do
    with {:ok, dir} <- find_zone(Path.join(root, "sys/class/thermal")),
         {:ok, text} <- File.read(Path.join(dir, "temp")) do
      case Integer.parse(text) do
        {millidegrees, _rest} -> {:ok, millidegrees / 1000}
        :error -> {:error, :invalid_temperature}
      end
    end
  end

  defp find_zone(thermal) do
    thermal
    |> Path.join("thermal_zone*")
    |> Path.wildcard()
    |> Enum.find(fn dir -> File.read(Path.join(dir, "type")) == {:ok, @zone <> "\n"} end)
    |> case do
      nil -> {:error, :no_sensor}
      dir -> {:ok, dir}
    end
  end
end
