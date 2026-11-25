defmodule NanoKVMGo.Peer do
  @moduledoc false
  # Processes on another node, for the tests of subscribers there: the test
  # node turns distributed, with an epmd on the loopback interface if none
  # runs, and a peer node runs Elixir with this library.

  import ExUnit.Callbacks, only: [on_exit: 1]

  # A process on another node that evaluates `expression` with `binding`,
  # then sends what it receives to the caller as {NanoKVMGo.Peer, message}.
  @spec spawn_caller(String.t(), keyword()) :: pid()
  def spawn_caller(expression, binding) do
    node = start_peer()
    {:ok, _apps} = :erpc.call(node, :application, :ensure_all_started, [:elixir])

    {pid, _binding} =
      :erpc.call(node, Code, :eval_string, [
        """
        forward = fn forward ->
          receive do
            message ->
              send(test, {NanoKVMGo.Peer, message})
              forward.(forward)
          end
        end

        spawn(fn ->
          #{expression}
          forward.(forward)
        end)
        """,
        [{:test, self()} | binding]
      ])

    pid
  end

  defp start_peer do
    if not Node.alive?() do
      {_output, 0} = System.cmd("epmd", ["-address", "127.0.0.1", "-daemon"])
      {:ok, _pid} = Node.start(:"nano_kvm_go_test@127.0.0.1")
      on_exit(&Node.stop/0)
    end

    {:ok, _peer, node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        args: [
          ~c"-start_epmd",
          ~c"false",
          ~c"-pa",
          :code.lib_dir(:elixir) ++ ~c"/ebin",
          ~c"-pa",
          :code.lib_dir(:nano_kvm_go) ++ ~c"/ebin"
        ]
      })

    node
  end
end
