defmodule NanoKVMGo.Video.Clock do
  @moduledoc false

  def offset do
    1..3
    |> Enum.map(fn _ ->
      before = System.monotonic_time(:microsecond)
      source = :erlang.system_info(:os_monotonic_time_source)
      after_sample = System.monotonic_time(:microsecond)

      if :os.type() == {:unix, :linux} and source[:clock_id] != :CLOCK_MONOTONIC do
        raise "video timestamps require the VM to use CLOCK_MONOTONIC"
      end

      os_time = System.convert_time_unit(Keyword.fetch!(source, :time), :native, :microsecond)
      {after_sample - before, div(before + after_sample, 2) - os_time}
    end)
    |> Enum.min_by(&elem(&1, 0))
    |> elem(1)
  end
end
