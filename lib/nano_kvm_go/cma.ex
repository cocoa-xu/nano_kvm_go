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

      NanoKVMGo.CMA.put_sizes(%{video: 160, npu: 96})
      #=> :ok

  Sizes are in MiB: multiples of 8, video's at least 8, the NPU's 0 to turn
  the NPU off, together at most half of the DRAM. `:default` stands for the
  device tree's size, 192 and 64 on the Go+. 4K capture with JPEG and H.264
  needs about 192 MiB.

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

  @doc """
  The sizes of the pools in this boot, in MiB. The NPU's is 0 when the NPU
  is off.

  ## Options

    * `:root` - the root of the file system to read, `"/"` by default
  """
  @spec sizes(keyword()) :: sizes()
  def sizes(opts \\ []) do
    opts = Options.validate!(opts, [root: "/"], &valid?/2)
    dt = device_tree(opts[:root])
    pools = reserved_memory(dt)
    video = Enum.find(pools, &File.exists?(Path.join(&1, "linux,cma-default")))

    %{video: pool_mb(video), npu: npu_mb(dt, pools)}
  end

  @doc """
  The sizes kept for the next boots, `:default` for the device tree's.
  During a trial, the sizes from before it: those the boots go back to unless
  the firmware is validated.

  ## Options

    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
  """
  @spec saved_sizes(keyword()) :: %{video: size(), npu: size()}
  def saved_sizes(opts \\ []) do
    kv = opts |> Options.validate!([kv: Nerves.Runtime.KV], &valid?/2) |> Keyword.fetch!(:kv)
    saved(kv, if(trial_state(kv), do: "_was", else: ""))
  end

  @doc """
  The trial of sizes, `nil` without one.
  """
  @spec trial(keyword()) :: trial() | nil
  def trial(opts \\ []) do
    kv = opts |> Options.validate!([kv: Nerves.Runtime.KV], &valid?/2) |> Keyword.fetch!(:kv)

    case trial_state(kv) do
      nil -> nil
      state -> %{state: state, sizes: saved(kv, "")}
    end
  end

  @doc """
  Keeps pool sizes for the next boots: `:video` and `:npu` in MiB, or
  `:default`. A size left out stays as it is, and a trial under way ends.

  ## Options

    * `:trial` - `true` to run the sizes at the next boot only, until the
      firmware is validated
    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
    * `:root` - the root of the file system, `"/"` by default, where the
      DRAM's size comes from
  """
  @spec put_sizes(%{optional(:video | :npu) => size()} | keyword(), keyword()) ::
          :ok | {:error, term()}
  def put_sizes(sizes, opts \\ []) do
    opts = Options.validate!(opts, [kv: Nerves.Runtime.KV, root: "/", trial: false], &valid?/2)
    kv = opts[:kv]
    sizes = Map.new(sizes)
    saved = saved_sizes(kv: kv)
    new = Map.merge(saved, sizes)
    half = with dram when is_integer(dram) <- dram_mb(device_tree(opts[:root])), do: div(dram, 2)

    with :ok <- check_pools(sizes),
         :ok <- check_size(:video, new.video, @align, half),
         :ok <- check_size(:npu, new.npu, 0, half),
         :ok <- check_total(new, half) do
      put(kv, variables(new, saved, opts[:trial]))
    end
  end

  @doc """
  Ends a trial of sizes: the next boots use the sizes from before it.

  ## Options

    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
  """
  @spec cancel_trial(keyword()) :: :ok | {:error, term()}
  def cancel_trial(opts \\ []) do
    kv = opts |> Options.validate!([kv: Nerves.Runtime.KV], &valid?/2) |> Keyword.fetch!(:kv)

    if trial_state(kv) do
      put(kv, variables(saved(kv, "_was"), nil, false))
    else
      :ok
    end
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
    case get(kv, "cma_try") do
      "1" -> :pending
      "2" -> :running
      _ -> nil
    end
  end

  defp saved(kv, suffix) do
    %{video: parse(get(kv, "cma_video" <> suffix)), npu: parse(get(kv, "cma_npu" <> suffix))}
  end

  defp get(kv, variable) do
    if Code.ensure_loaded?(kv), do: kv.get(variable)
  end

  defp put(kv, variables) do
    if Code.ensure_loaded?(kv), do: kv.put(variables), else: {:error, {:undefined, kv}}
  end

  defp parse(value) do
    case Integer.parse(value || "") do
      {mb, ""} when mb >= 0 -> mb
      _ -> :default
    end
  end

  defp format(:default), do: ""
  defp format(mb), do: Integer.to_string(mb)

  defp check_pools(sizes) do
    case Map.keys(sizes) -- [:video, :npu] do
      [] -> :ok
      [pool | _] -> {:error, {:unknown_pool, pool}}
    end
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
