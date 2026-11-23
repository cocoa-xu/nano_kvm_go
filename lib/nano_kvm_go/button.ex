defmodule NanoKVMGo.Button do
  @moduledoc """
  The NanoKVM-Go's BOOT button, beside the USB port. Held at power-on it
  starts the stock firmware's recovery; while the system runs it is free for
  the application.

  Subscribers receive `{NanoKVMGo.Button, :down}` and `{NanoKVMGo.Button, :up}`.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Button` by default
    * `:device` - the input device, by default the one of the GPIO keys
    * `:program` - the port program that reads it, the library's
      `nano_kvm_go_input` by default
  """
  use GenServer
  require Logger

  alias NanoKVMGo.Input

  @retry_delay 2_000
  @ev_key 1
  @key_prog1 148

  @type option() :: {:name, GenServer.name()} | {:device, Path.t()} | {:program, Path.t()}

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends presses to the caller until it unsubscribes or exits.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)

  @doc """
  Stops sending to the caller.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, :unsubscribe)

  @impl GenServer
  def init(opts) do
    state = %{
      device: Keyword.get(opts, :device),
      program: Keyword.get_lazy(opts, :program, &Input.program/0),
      port: nil,
      reading: nil,
      subscribers: %{}
    }

    if File.regular?(state.program),
      do: {:ok, start_reader(state)},
      else: {:stop, {:missing_program, state.program}}
  end

  @impl GenServer
  def handle_call(:subscribe, {pid, _tag}, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    {monitor, subscribers} = Map.pop(state.subscribers, pid)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Input.decode(data) do
      {:events, events} -> Enum.each(events, &press(&1, state.subscribers))
      {:log, line} -> Logger.debug("nano_kvm_go_input: " <> line)
      :unknown -> :ok
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "nano_kvm_go: reading the button from #{state.reading} stopped (#{status}), trying again"
    )

    Process.send_after(self(), :retry, @retry_delay)
    {:noreply, %{state | port: nil, reading: nil}}
  end

  def handle_info(:retry, state), do: {:noreply, start_reader(state)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp press({@ev_key, @key_prog1, value}, subscribers) when value in [0, 1] do
    event = if value == 1, do: :down, else: :up
    Enum.each(subscribers, fn {pid, _monitor} -> send(pid, {__MODULE__, event}) end)
  end

  defp press(_event, _subscribers), do: :ok

  defp start_reader(state) do
    case state.device || Input.find("gpio-keys") do
      nil ->
        Process.send_after(self(), :retry, @retry_delay)
        state

      device ->
        %{state | port: Input.open(state.program, device), reading: device}
    end
  end
end
