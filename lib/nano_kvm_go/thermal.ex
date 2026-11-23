defmodule NanoKVMGo.Thermal do
  @moduledoc false
  # The SoC temperature, from the thermal zone of its on-die sensor.

  @zone "soc-thermal"

  @spec temperature(Path.t()) :: {:ok, float()} | {:error, term()}
  def temperature(root \\ "/") do
    with {:ok, dir} <- find_zone(Path.join(root, "sys/class/thermal")),
         {:ok, text} <- File.read(Path.join(dir, "temp")),
         {millidegrees, _rest} <- Integer.parse(text) do
      {:ok, millidegrees / 1000}
    else
      :error -> {:error, :invalid_temperature}
      {:error, _reason} = error -> error
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
