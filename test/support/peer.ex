defmodule NanoKVMGo.Peer do
  @moduledoc false
  # Processes on another node, for the tests of subscribers there: the test
  # node turns distributed, with epmd, and a peer node runs Elixir.

  import ExUnit.Callbacks, only: [on_exit: 1]

  # A process on another node that calls `server` with `request`, then
  # keeps what it is sent.
  @spec spawn_caller(GenServer.server(), term()) :: pid()
  def spawn_caller(server, request) do
    node = start_peer()
    {:ok, _apps} = :erpc.call(node, :application, :ensure_all_started, [:elixir])

    {pid, _binding} =
      :erpc.call(node, Code, :eval_string, [
        "spawn(fn -> GenServer.call(server, request); Process.sleep(:infinity) end)",
        [server: server, request: request]
      ])

    pid
  end

  @spec message_queue_len(pid()) :: non_neg_integer()
  def message_queue_len(pid) do
    {:message_queue_len, length} =
      :erpc.call(node(pid), Process, :info, [pid, :message_queue_len])

    length
  end

  defp start_peer do
    if not Node.alive?() do
      {_output, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _pid} = Node.start(:"nano_kvm_go_test@127.0.0.1")
      on_exit(&Node.stop/0)
    end

    {:ok, _peer, node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-pa", :code.lib_dir(:elixir) ++ ~c"/ebin"]
      })

    node
  end
end
