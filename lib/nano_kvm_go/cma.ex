defmodule NanoKVMGo.CMA do
  @moduledoc """
  The contiguous memory (CMA) pools of video and the NPU.

  Video capture with its encoders and the NPU need physically contiguous
  buffers, which Linux keeps in CMA pools: video uses the default pool, the
  NPU has its own. Movable pages use what a pool does not hold, so an idle
  pool costs little. The NanoKVM-Go system's U-Boot sizes both at every boot
  from its environment, so new sizes apply at the next boot:

      NanoKVMGo.CMA.sizes()
      #=> %{video: 192, npu: 64}

      NanoKVMGo.CMA.persist_sizes(%{video: 160, npu: 96})
      #=> :ok

  Sizes are in MiB: multiples of 8, video's at least 8, the NPU's 0 to turn
  the NPU off, together at most half of the DRAM. `:default` stands for the
  device tree's size, 192 and 64 on the Go+. 4K capture with JPEG and H.264
  needs about 192 MiB.

  The sizes for the next boots are in the U-Boot environment, through
  `Nerves.Runtime.KV` or another module with its `get/1` and `put/1` (the
  `:kv` option).

  ## Trying sizes first

  With `trial: true` the next boot runs the new sizes once. Validating the
  firmware, `Nerves.Runtime.validate_firmware/0`, keeps them; any boot
  before that, after a crash, the watchdog or a plain reboot, goes back to
  the sizes before. `trial/1` tells where a trial stands and
  `cancel_trial/1` drops it.
  """

  alias NanoKVMGo.Options

  # Linux aligns CMA pools to its page blocks: 2^11 pages of 4 KiB.
  @align 8

  @typedoc "A pool size in MiB, or `:default` for the device tree's."
  @type size() :: non_neg_integer() | :default

  @type sizes() :: %{video: non_neg_integer(), npu: non_neg_integer()}

  @typedoc """
  A trial of sizes: `:pending` until the boot that runs them, then
  `:running`.
  """
  @type trial() :: %{state: :pending | :running, sizes: %{video: size(), npu: size()}}

  @type persist_option() :: {:kv, module()} | {:root, Path.t()} | {:trial, boolean()}

  @doc """
  The sizes of the pools in this boot, in MiB. The NPU's is 0 when the NPU
  is off.

  ## Options

    * `:root` - the root of the file system to read, `"/"` by default
  """
  @spec sizes([{:root, Path.t()}]) :: sizes()
  def sizes(opts \\ []) do
    opts = Options.validate!(opts, [root: "/"], &valid?/2)
    dt = device_tree(opts[:root])
    pools = reserved_memory(dt)
    video = Enum.find(pools, &File.exists?(Path.join(&1, "linux,cma-default")))

    %{video: pool_mb(video), npu: npu_mb(dt, pools)}
  end

  @doc """
  The sizes persisted for the next boots, `:default` for the device tree's.
  During a trial, the sizes from before it: those the boots go back to unless
  the firmware is validated.

  ## Options

    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
  """
  @spec persisted_sizes([{:kv, module()}]) :: %{video: size(), npu: size()}
  def persisted_sizes(opts \\ []) do
    kv = kv(opts)
    read_sizes(kv, if(trial_state(kv), do: "_was", else: ""))
  end

  @doc """
  The trial of sizes, `nil` without one.

  ## Options

    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
  """
  @spec trial([{:kv, module()}]) :: trial() | nil
  def trial(opts \\ []) do
    kv = kv(opts)

    case trial_state(kv) do
      nil -> nil
      state -> %{state: state, sizes: read_sizes(kv, "")}
    end
  end

  @doc """
  Persists pool sizes for the next boots: `:video` and `:npu` in MiB, or
  `:default`. A size left out stays as it is, and a trial under way ends.

  A size U-Boot would not take gives `{:error, {:invalid_size, pool,
  size}}`, and sizes together over half the DRAM `{:error, {:too_large,
  total, half}}`. A pool other than `:video` and `:npu`, or a size that is
  neither a non-negative integer nor `:default`, raises `ArgumentError`.

  ## Options

    * `:trial` - `true` to run the sizes at the next boot only, until the
      firmware is validated
    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
    * `:root` - the root of the file system, `"/"` by default, where the
      DRAM's size comes from
  """
  @spec persist_sizes(%{optional(:video | :npu) => size()}, [persist_option()]) ::
          :ok | {:error, term()}
  def persist_sizes(sizes, opts \\ []) when is_map(sizes) do
    opts = Options.validate!(opts, [kv: Nerves.Runtime.KV, root: "/", trial: false], &valid?/2)
    Enum.each(sizes, &check_pool!/1)
    kv = opts[:kv]
    persisted = persisted_sizes(kv: kv)
    new = Map.merge(persisted, sizes)
    half = half_dram_mb(opts[:root])

    with :ok <- check_size(:video, new.video, @align, half),
         :ok <- check_size(:npu, new.npu, 0, half),
         :ok <- check_total(new, half) do
      kv.put(variables(new, persisted, opts[:trial]))
    end
  end

  @doc """
  Ends a trial of sizes: the next boots use the sizes from before it.

  ## Options

    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
  """
  @spec cancel_trial([{:kv, module()}]) :: :ok | {:error, term()}
  def cancel_trial(opts \\ []) do
    kv = kv(opts)

    if trial_state(kv) do
      kv.put(variables(read_sizes(kv, "_was"), nil, false))
    else
      :ok
    end
  end

  defp kv(opts) do
    opts |> Options.validate!([kv: Nerves.Runtime.KV], &valid?/2) |> Keyword.fetch!(:kv)
  end

  # U-Boot's variables (uboot/uboot.env of nerves_system_nano_kvm_go):
  # cma_video and cma_npu are the sizes, a trial keeps the ones before it in
  # cma_*_was and sets cma_try to 1, which the boot that runs it makes 2.
  # Empty means unset: U-Boot drops empty variables.
  defp variables(new, _before, false) do
    %{"cma_video" => format(new.video), "cma_npu" => format(new.npu)}
    |> Map.merge(%{"cma_try" => "", "cma_video_was" => "", "cma_npu_was" => ""})
  end

  defp variables(new, before, true) do
    %{
      "cma_video" => format(new.video),
      "cma_npu" => format(new.npu),
      "cma_video_was" => format(before.video),
      "cma_npu_was" => format(before.npu),
      "cma_try" => "1"
    }
  end

  defp trial_state(kv) do
    case kv.get("cma_try") do
      "1" -> :pending
      "2" -> :running
      _ -> nil
    end
  end

  defp read_sizes(kv, suffix) do
    %{video: parse(kv.get("cma_video" <> suffix)), npu: parse(kv.get("cma_npu" <> suffix))}
  end

  defp parse(value) do
    case Integer.parse(value || "") do
      {mb, ""} when mb >= 0 -> mb
      _ -> :default
    end
  end

  defp format(:default), do: ""
  defp format(mb), do: Integer.to_string(mb)

  defp check_pool!({pool, size})
       when pool in [:video, :npu] and (size == :default or (is_integer(size) and size >= 0)),
       do: :ok

  defp check_pool!(pool_size) do
    raise ArgumentError, "invalid pool size: #{inspect(pool_size)}"
  end

  # As U-Boot checks them; without the DRAM's size (half: nil) it alone
  # checks the upper bound.
  defp check_size(_pool, :default, _min, _half), do: :ok

  defp check_size(_pool, mb, min, half)
       when is_integer(mb) and mb >= min and rem(mb, @align) == 0 and (half == nil or mb <= half),
       do: :ok

  defp check_size(pool, mb, _min, _half), do: {:error, {:invalid_size, pool, mb}}

  # U-Boot keeps the device tree's sizes when both together take more than
  # half of the DRAM. With a default size the total is up to U-Boot.
  defp check_total(%{video: video, npu: npu}, half)
       when is_integer(video) and is_integer(npu) and is_integer(half) and video + npu > half,
       do: {:error, {:too_large, video + npu, half}}

  defp check_total(_sizes, _half), do: :ok

  defp device_tree(root), do: Path.join(root, "proc/device-tree")

  defp half_dram_mb(root) do
    case dram_mb(device_tree(root)) do
      nil -> nil
      dram -> div(dram, 2)
    end
  end

  defp reserved_memory(dt) do
    dt
    |> Path.join("reserved-memory/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  # The NPU's pool is the one its node's memory-region points at.
  defp npu_mb(dt, pools) do
    with npu when npu != nil <- npu_node(dt),
         true <- available?(npu),
         {:ok, phandle} <- File.read(Path.join(npu, "memory-region")),
         pool when pool != nil <-
           Enum.find(pools, &(File.read(Path.join(&1, "phandle")) == {:ok, phandle})),
         true <- available?(pool) do
      pool_mb(pool)
    else
      _ -> 0
    end
  end

  defp npu_node(dt) do
    [Path.join(dt, "*/compatible"), Path.join(dt, "*/*/compatible")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.find_value(fn compatible ->
      if "axera,ax620e-npu" in strings(compatible), do: Path.dirname(compatible)
    end)
  end

  defp available?(node) do
    case strings(Path.join(node, "status")) do
      [] -> true
      [status | _] -> status in ["okay", "ok"]
    end
  end

  defp pool_mb(nil), do: 0

  defp pool_mb(node) do
    case File.read(Path.join(node, "size")) do
      {:ok, <<size::32>>} -> div(size, 1_048_576)
      {:ok, <<size::64>>} -> div(size, 1_048_576)
      _ -> 0
    end
  end

  # All of /memory's banks; unknown (nil) without a device tree.
  defp dram_mb(dt) do
    with [_ | _] = banks <- Path.wildcard(Path.join(dt, "memory*/reg")),
         {:ok, <<address_cells::32>>} <- File.read(Path.join(dt, "#address-cells")),
         {:ok, <<size_cells::32>>} <- File.read(Path.join(dt, "#size-cells")) do
      banks
      |> Enum.map(&File.read!/1)
      |> Enum.map(&bank_sizes(&1, address_cells * 32, size_cells * 32))
      |> Enum.sum()
      |> div(1_048_576)
    else
      _ -> nil
    end
  end

  defp bank_sizes(reg, address_bits, size_bits) do
    for <<_address::size(^address_bits), size::size(^size_bits) <- reg>>, reduce: 0 do
      total -> total + size
    end
  end

  defp strings(path) do
    case File.read(path) do
      {:ok, data} -> data |> String.split(<<0>>) |> Enum.reject(&(&1 == ""))
      {:error, _reason} -> []
    end
  end

  defp valid?(:root, root), do: is_binary(root)
  defp valid?(:kv, kv), do: is_atom(kv)
  defp valid?(:trial, trial), do: is_boolean(trial)
end
