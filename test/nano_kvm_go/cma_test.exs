defmodule NanoKVMGo.CMATest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.CMA

  # The U-Boot environment of the test's process, as Nerves.Runtime.KV keeps
  # it on the device: put stores empty values, which U-Boot drops later.
  defmodule KV do
    def get(variable), do: Map.get(env(), variable)

    def put(variables) do
      Process.put(__MODULE__, Map.merge(env(), variables))
      :ok
    end

    def env, do: Process.get(__MODULE__, %{})
  end

  setup do
    Process.put(KV, %{})
    :ok
  end

  @moduletag :tmp_dir

  # The parts of the NanoKVM-Go's device tree that matter here.
  defp device_tree(root, opts \\ []) do
    dt = Path.join(root, "proc/device-tree")
    write(dt, "#address-cells", <<1::32>>)
    write(dt, "#size-cells", <<1::32>>)
    write(dt, "memory@40000000/reg", <<0x40000000::32, 0x20000000::32>>)

    write(
      dt,
      "reserved-memory/linux,cma/size",
      <<Keyword.get(opts, :video, 192) * 1_048_576::32>>
    )

    write(dt, "reserved-memory/linux,cma/linux,cma-default", "")
    write(dt, "reserved-memory/npu-memory/size", <<64 * 1_048_576::32>>)
    write(dt, "reserved-memory/npu-memory/phandle", <<0x2A::32>>)
    write(dt, "reserved-memory/ramlog@55f00000/reg", <<0x55F00000::32, 0x100000::32>>)
    write(dt, "soc/npu@3800000/compatible", "axera,ax620e-npu\0")
    write(dt, "soc/npu@3800000/memory-region", <<0x2A::32>>)

    if opts[:npu_off] do
      write(dt, "soc/npu@3800000/status", "disabled\0")
      write(dt, "reserved-memory/npu-memory/status", "disabled\0")
    end

    root
  end

  defp write(dt, file, data) do
    path = Path.join(dt, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
  end

  defp put_env(variables), do: Process.put(KV, variables)

  test "the sizes of this boot come from the device tree", %{tmp_dir: tmp_dir} do
    assert CMA.sizes(root: device_tree(tmp_dir, video: 160)) == %{video: 160, npu: 64}
  end

  test "the NPU's pool counts as 0 when the NPU is off", %{tmp_dir: tmp_dir} do
    assert CMA.sizes(root: device_tree(tmp_dir, npu_off: true)) == %{video: 192, npu: 0}
  end

  test "no device tree, no pools", %{tmp_dir: tmp_dir} do
    assert CMA.sizes(root: tmp_dir) == %{video: 0, npu: 0}
  end

  test "keeps sizes for the next boots", %{tmp_dir: tmp_dir} do
    opts = [kv: KV, root: device_tree(tmp_dir)]

    assert CMA.saved_sizes(opts) == %{video: :default, npu: :default}
    assert :ok = CMA.put_sizes(%{video: 160, npu: 96}, opts)
    assert %{"cma_video" => "160", "cma_npu" => "96", "cma_try" => ""} = KV.env()
    assert CMA.saved_sizes(opts) == %{video: 160, npu: 96}

    assert :ok = CMA.put_sizes([npu: 0], opts)
    assert CMA.saved_sizes(opts) == %{video: 160, npu: 0}

    assert :ok = CMA.put_sizes(%{video: :default}, opts)
    assert %{"cma_video" => "", "cma_npu" => "0"} = KV.env()
    assert CMA.saved_sizes(opts) == %{video: :default, npu: 0}
    assert CMA.trial(opts) == nil
  end

  test "refuses sizes U-Boot would not take", %{tmp_dir: tmp_dir} do
    opts = [kv: KV, root: device_tree(tmp_dir)]

    assert CMA.put_sizes(%{video: 100}, opts) == {:error, {:invalid_size, :video, 100}}
    assert CMA.put_sizes(%{video: 0}, opts) == {:error, {:invalid_size, :video, 0}}
    assert CMA.put_sizes(%{npu: -8}, opts) == {:error, {:invalid_size, :npu, -8}}
    assert CMA.put_sizes(%{npu: "64"}, opts) == {:error, {:invalid_size, :npu, "64"}}
    assert CMA.put_sizes(%{video: 264}, opts) == {:error, {:invalid_size, :video, 264}}
    assert CMA.put_sizes(%{video: 200, npu: 64}, opts) == {:error, {:too_large, 264, 256}}
    assert CMA.put_sizes(%{gpu: 8}, opts) == {:error, {:unknown_pool, :gpu}}
    assert KV.env() == %{}
  end

  test "leaves the total to U-Boot without the DRAM's size", %{tmp_dir: tmp_dir} do
    assert :ok = CMA.put_sizes(%{video: 1024, npu: 64}, kv: KV, root: tmp_dir)
  end

  test "tries sizes and goes back to the ones before", %{tmp_dir: tmp_dir} do
    opts = [kv: KV, root: device_tree(tmp_dir)]
    put_env(%{"cma_video" => "160"})

    assert :ok = CMA.put_sizes(%{npu: 96}, [trial: true] ++ opts)

    assert %{
             "cma_video" => "160",
             "cma_npu" => "96",
             "cma_video_was" => "160",
             "cma_npu_was" => "",
             "cma_try" => "1"
           } = KV.env()

    assert CMA.trial(opts) == %{state: :pending, sizes: %{video: 160, npu: 96}}
    assert CMA.saved_sizes(opts) == %{video: 160, npu: :default}

    # The boot that runs them; another trial still goes back to the same.
    put_env(%{KV.env() | "cma_try" => "2"})
    assert CMA.trial(opts) == %{state: :running, sizes: %{video: 160, npu: 96}}
    assert :ok = CMA.put_sizes(%{video: 200, npu: 56}, [trial: true] ++ opts)
    assert %{"cma_video_was" => "160", "cma_npu_was" => "", "cma_try" => "1"} = KV.env()

    assert :ok = CMA.cancel_trial(opts)

    assert %{"cma_video" => "160", "cma_npu" => "", "cma_try" => "", "cma_video_was" => ""} =
             KV.env()

    assert CMA.trial(opts) == nil
    assert :ok = CMA.cancel_trial(opts)
  end

  test "sizes kept without a trial end one", %{tmp_dir: tmp_dir} do
    opts = [kv: KV, root: device_tree(tmp_dir)]
    put_env(%{"cma_video" => "200", "cma_video_was" => "160", "cma_try" => "2"})

    assert :ok = CMA.put_sizes(%{npu: 32}, opts)

    assert %{"cma_video" => "160", "cma_npu" => "32", "cma_try" => "", "cma_video_was" => ""} =
             KV.env()
  end

  test "without the U-Boot environment" do
    assert CMA.saved_sizes(kv: NoSuchKV) == %{video: :default, npu: :default}
    assert CMA.trial(kv: NoSuchKV) == nil
    assert CMA.put_sizes(%{npu: 0}, kv: NoSuchKV) == {:error, {:undefined, NoSuchKV}}
  end
end
