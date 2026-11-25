defmodule NanoKVMGo.FakeProgram do
  @moduledoc false
  # Shell scripts that stand in for the port programs. They report to the
  # test that wrote them: a line a run writes with `event <text>` comes to the
  # test process as {NanoKVMGo.FakeProgram, text}. A run reports "start" as it
  # starts and "exit" when its script ends; a killed one reports nothing more.
  # Each run appends its PID to <program>.pids, and the runs are killed when
  # the test ends, whatever happened to their stdin.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec write!(Path.t(), String.t()) :: Path.t()
  def write!(program, script) do
    events = events!(Path.dirname(program))

    File.write!(program, """
    #!/bin/sh
    echo $$ >> '#{program}.pids'
    event() { env printf '%s\\n' "$*" > '#{events}'; }
    trap 'event exit' EXIT
    event start
    #{script}
    """)

    File.chmod!(program, 0o755)
    on_exit(fn -> kill(program) end)
    program
  end

  # The PIDs of the runs so far.
  @spec runs(Path.t()) :: [String.t()]
  def runs(program) do
    case File.read(program <> ".pids") do
      {:ok, pids} -> String.split(pids)
      {:error, :enoent} -> []
    end
  end

  @spec kill(Path.t()) :: :ok
  def kill(program) do
    Enum.each(runs(program), &System.cmd("kill", ["-9", &1], stderr_to_stdout: true))
  end

  # The port a process runs its program in.
  @spec port(pid()) :: port() | nil
  def port(pid) do
    {:links, links} = Process.info(pid, :links)
    Enum.find(links, &is_port/1)
  end

  # A FIFO for the runs of a directory, read for the test process by a
  # forwarder. The reader opens it for writing too: no run's end is the end
  # of the file. It ends with the test: its reader killed, the forwarder
  # gets the exit status.
  #
  # `event` runs printf apart: the shell's own keeps what it failed to write
  # to a closed stdout and writes it with the next line, to the FIFO.
  defp events!(dir) do
    fifo = Path.join(dir, "events")

    if not File.exists?(fifo) do
      {_output, 0} = System.cmd("mkfifo", [fifo])
      test = self()
      forwarder = spawn(fn -> forward(fifo, test) end)

      receive do
        {^forwarder, os_pid} ->
          on_exit(fn ->
            System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true)
          end)
      end
    end

    fifo
  end

  defp forward(fifo, test) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        line: 4096,
        args: ["-c", ~s(exec cat 0<>"$0"), fifo]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    send(test, {self(), os_pid})
    forward_lines(port, test)
  end

  defp forward_lines(port, test) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send(test, {__MODULE__, line})
        forward_lines(port, test)

      {^port, {:exit_status, _status}} ->
        :ok
    end
  end
end
