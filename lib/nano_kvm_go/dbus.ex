defmodule NanoKVMGo.DBus do
  @moduledoc false
  # A connection to a D-Bus message bus over its Unix socket, authenticated
  # as the process's own user (EXTERNAL). `:wait` gives a bus that is still
  # starting that many milliseconds to appear.
  #
  # Calls wait for their reply in the caller. Signals go to the processes
  # that subscribed with a rule, as `{:dbus_signal, message}`. Method calls
  # to an exported object path go to its process as
  # `{:dbus_method_call, message}`, which answers with `reply/4` or
  # `error/4`; calls to other paths get UnknownObject.

  use GenServer

  require Logger

  alias NanoKVMGo.DBus.Message

  @system_bus "/run/dbus/system_bus_socket"
  @bus "org.freedesktop.DBus"

  @type rule() :: [
          sender: String.t(),
          path: String.t(),
          path_namespace: String.t(),
          interface: String.t(),
          member: String.t()
        ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The connection's unique name on the bus."
  @spec unique_name(GenServer.server()) :: String.t()
  def unique_name(conn), do: GenServer.call(conn, :unique_name)

  @spec call(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          list(),
          timeout()
        ) :: {:ok, list()} | {:error, {String.t(), String.t()} | :timeout | :closed}
  def call(
        conn,
        destination,
        path,
        interface,
        member,
        signature \\ "",
        args \\ [],
        timeout \\ 25_000
      ) do
    message = %Message{
      type: :method_call,
      destination: destination,
      path: path,
      interface: interface,
      member: member,
      signature: signature,
      body: args
    }

    GenServer.call(conn, {:call, message, timeout}, :infinity)
  end

  @doc "Sends a signal from an object path."
  @spec signal(GenServer.server(), String.t(), String.t(), String.t(), String.t(), list()) :: :ok
  def signal(conn, path, interface, member, signature \\ "", args \\ []) do
    message = %Message{
      type: :signal,
      path: path,
      interface: interface,
      member: member,
      signature: signature,
      body: args
    }

    GenServer.call(conn, {:send, message})
  end

  @doc "Delivers the bus's signals that match `rule` to the calling process."
  @spec subscribe(GenServer.server(), rule()) :: :ok | {:error, term()}
  def subscribe(conn, rule), do: GenServer.call(conn, {:subscribe, rule, self()}, :infinity)

  @doc "Sends method calls to `path` and the paths under it to the calling process."
  @spec export(GenServer.server(), String.t()) :: :ok
  def export(conn, path), do: GenServer.call(conn, {:export, path, self()})

  @spec unexport(GenServer.server(), String.t()) :: :ok
  def unexport(conn, path), do: GenServer.call(conn, {:unexport, path})

  @spec reply(GenServer.server(), Message.t(), String.t(), list()) :: :ok
  def reply(conn, %Message{} = call, signature \\ "", args \\ []) do
    if Message.reply_expected?(call) do
      message = %Message{
        type: :method_return,
        destination: call.sender,
        reply_serial: call.serial,
        signature: signature,
        body: args
      }

      GenServer.call(conn, {:send, message})
    else
      :ok
    end
  end

  @spec error(GenServer.server(), Message.t(), String.t(), String.t()) :: :ok
  def error(conn, %Message{} = call, name, text) do
    if Message.reply_expected?(call) do
      GenServer.call(conn, {:send, error_reply(call, name, text)})
    else
      :ok
    end
  end

  # Server

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :path, @system_bus)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait, 0)

    with {:ok, socket} <- connect(path, deadline),
         :ok <- authenticate(socket) do
      :ok = :inet.setopts(socket, packet: :raw, active: :once)

      state = %{
        socket: socket,
        serial: 0,
        buffer: <<>>,
        name: nil,
        pending: %{},
        subscribers: [],
        exports: %{}
      }

      hello = %Message{
        type: :method_call,
        destination: @bus,
        path: "/org/freedesktop/DBus",
        interface: @bus,
        member: "Hello"
      }

      {:ok, send_call(state, hello, {:hello, nil}, 25_000)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:unique_name, _from, state), do: {:reply, state.name, state}

  def handle_call({:call, message, timeout}, from, state),
    do: {:noreply, send_call(state, message, {:reply, from}, timeout)}

  def handle_call({:send, message}, _from, state) do
    {state, _serial} = transmit(state, message)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, rule, pid}, from, state) do
    add_match = %Message{
      type: :method_call,
      destination: @bus,
      path: "/org/freedesktop/DBus",
      interface: @bus,
      member: "AddMatch",
      signature: "s",
      body: [match_rule(rule)]
    }

    Process.monitor(pid)
    state = %{state | subscribers: [{pid, rule} | state.subscribers]}
    {:noreply, send_call(state, add_match, {:subscribed, from}, 25_000)}
  end

  def handle_call({:export, path, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | exports: Map.put(state.exports, path, pid)}}
  end

  def handle_call({:unexport, path}, _from, state),
    do: {:reply, :ok, %{state | exports: Map.delete(state.exports, path)}}

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: :once)
    receive_messages(%{state | buffer: state.buffer <> data})
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :closed, state}

  def handle_info({:timeout, serial}, state) do
    case Map.pop(state.pending, serial) do
      {nil, _pending} ->
        {:noreply, state}

      {{waiter, _timer}, pending} ->
        {:noreply, answer(%{state | pending: pending}, waiter, {:error, :timeout})}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &match?({^pid, _rule}, &1))
    exports = Map.reject(state.exports, &match?({_path, ^pid}, &1))
    {:noreply, %{state | subscribers: subscribers, exports: exports}}
  end

  defp receive_messages(state) do
    case Message.decode(state.buffer) do
      {:ok, message, rest} -> receive_messages(dispatch(%{state | buffer: rest}, message))
      :incomplete -> {:noreply, state}
      {:error, :malformed} -> {:stop, :malformed_message, state}
    end
  end

  defp dispatch(state, %Message{type: type, reply_serial: serial} = message)
       when type in [:method_return, :error] do
    case Map.pop(state.pending, serial) do
      {nil, _pending} ->
        state

      {{waiter, timer}, pending} ->
        _ = Process.cancel_timer(timer)
        answer(%{state | pending: pending}, waiter, result(message))
    end
  end

  defp dispatch(state, %Message{type: :signal} = message) do
    for {pid, rule} <- state.subscribers,
        matches?(rule, message),
        do: send(pid, {:dbus_signal, message})

    state
  end

  defp dispatch(state, %Message{type: :method_call} = message) do
    case exporter(state.exports, message.path) do
      nil ->
        reply =
          error_reply(
            message,
            "org.freedesktop.DBus.Error.UnknownObject",
            "No object at #{message.path}"
          )

        if Message.reply_expected?(message), do: elem(transmit(state, reply), 0), else: state

      pid ->
        send(pid, {:dbus_method_call, message})
        state
    end
  end

  defp result(%Message{type: :method_return, body: body}), do: {:ok, body}

  defp result(%Message{type: :error, error_name: name, body: body}),
    do: {:error, {name, List.first(body, "")}}

  defp answer(state, {:hello, _}, {:ok, [name]}), do: %{state | name: name}

  defp answer(state, {:hello, _}, other) do
    Logger.error("D-Bus: Hello failed: #{inspect(other)}")
    state
  end

  defp answer(state, {:reply, from}, result) do
    GenServer.reply(from, result)
    state
  end

  defp answer(state, {:subscribed, from}, {:ok, _body}) do
    GenServer.reply(from, :ok)
    state
  end

  defp answer(state, {:subscribed, from}, error) do
    GenServer.reply(from, error)
    state
  end

  defp send_call(state, message, waiter, timeout) do
    {state, serial} = transmit(state, message)
    timer = Process.send_after(self(), {:timeout, serial}, timeout)
    %{state | pending: Map.put(state.pending, serial, {waiter, timer})}
  end

  defp transmit(state, message) do
    serial = state.serial + 1
    :ok = :gen_tcp.send(state.socket, Message.encode(%{message | serial: serial}))
    {%{state | serial: serial}, serial}
  end

  defp error_reply(call, name, text) do
    %Message{
      type: :error,
      destination: call.sender,
      reply_serial: call.serial,
      error_name: name,
      signature: "s",
      body: [text]
    }
  end

  defp exporter(exports, path) do
    Enum.find_value(exports, fn {root, pid} ->
      if path == root or String.starts_with?(path, root <> "/"), do: pid
    end)
  end

  defp matches?(rule, message) do
    Enum.all?(rule, fn
      {:sender, _sender} ->
        true

      {:path, path} ->
        message.path == path

      {:path_namespace, root} ->
        message.path == root or String.starts_with?(message.path, root <> "/")

      {:interface, interface} ->
        message.interface == interface

      {:member, member} ->
        message.member == member
    end)
  end

  defp match_rule(rule) do
    ["type='signal'" | Enum.map(rule, fn {key, value} -> "#{key}='#{value}'" end)]
    |> Enum.join(",")
  end

  # The bus may still be starting: try again until the deadline.
  defp connect(path, deadline) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line]) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          connect(path, deadline)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # SASL EXTERNAL without an identity: the bus takes the socket's peer
  # credentials.
  defp authenticate(socket) do
    with :ok <- :gen_tcp.send(socket, "\0AUTH EXTERNAL\r\n"),
         {:ok, "DATA" <> _} <- :gen_tcp.recv(socket, 0, 5_000),
         :ok <- :gen_tcp.send(socket, "DATA\r\n"),
         {:ok, "OK " <> _guid} <- :gen_tcp.recv(socket, 0, 5_000) do
      :gen_tcp.send(socket, "BEGIN\r\n")
    else
      {:ok, line} -> {:error, {:auth, String.trim(line)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
