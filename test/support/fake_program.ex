defmodule NanoKVMGo.FakeProgram do
  @moduledoc false
  # Shell scripts that stand in for the port programs. Each run appends its
  # PID to <program>.pids, and the runs are killed when the test ends,
  # whatever happened to their stdin.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec write!(Path.t(), String.t()) :: Path.t()
  def write!(program, script) do
    File.write!(program, "#!/bin/sh\necho $$ >> '#{program}.pids'\n" <> script)
    File.chmod!(program, 0o755)
    on_exit(fn -> kill(program) end)
    program
  end

  @spec running?(Path.t()) :: boolean()
  def running?(program) do
    Enum.any?(pids(program), &match?({_output, 0}, signal(&1, "-0")))
  end

  @spec kill(Path.t()) :: :ok
  def kill(program), do: Enum.each(pids(program), &signal(&1, "-9"))

  # The port a process runs its program in.
  @spec port(pid()) :: port() | nil
  def port(pid) do
    {:links, links} = Process.info(pid, :links)
    Enum.find(links, &is_port/1)
  end

  defp pids(program) do
    case File.read(program <> ".pids") do
      {:ok, pids} -> String.split(pids)
      {:error, :enoent} -> []
    end
  end

  defp signal(pid, signal), do: System.cmd("kill", [signal, pid], stderr_to_stdout: true)
end
