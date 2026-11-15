defmodule NanoKVMGo.Button do
  @moduledoc """
  The NanoKVM-Go's BOOT button, beside the USB port. Held at power-on it
  starts the stock firmware's recovery; while the system runs it is free for
  the application.

  Subscribers receive `{NanoKVMGo.Button, :down}` and `{NanoKVMGo.Button, :up}`.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Button` by default
    * `:device` - the input device, by default the one of the GPIO keys
  """
  use GenServer
  require Logger

  alias NanoKVMGo.Input

  @retry_delay 2_000
  @ev_key 1
  @key_prog1 148

  @type option() :: {:name, GenServer.name()} | {:device, Path.t()}

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
    Process.flag(:trap_exit, true)
    device = Keyword.get_lazy(opts, :device, fn -> Input.find("gpio-keys") end)
    {:ok, start_reader(%{device: device, reader: nil, subscribers: %{}})}
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
  def handle_info({:events, data}, state) do
    for <<_time::binary-size(8), @ev_key::little-16, @key_prog1::little-16,
          value::little-signed-32 <- data>>,
        value in [0, 1],
        {pid, _monitor} <- state.subscribers do
      send(pid, {__MODULE__, if(value == 1, do: :down, else: :up)})
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    Logger.warning("nano_kvm_go: button #{inspect(state.device)}: #{inspect(reason)}")
    Process.send_after(self(), :retry, @retry_delay)
    {:noreply, %{state | reader: nil}}
  end

  def handle_info(:retry, state) do
    {:noreply, start_reader(%{state | device: state.device || Input.find("gpio-keys")})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_reader(%{device: nil} = state) do
    Process.send_after(self(), :retry, @retry_delay)
    state
  end

  defp start_reader(state), do: %{state | reader: Input.start_reader(self(), state.device)}
end
