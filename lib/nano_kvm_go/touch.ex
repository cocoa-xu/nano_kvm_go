defmodule NanoKVMGo.Touch do
  @moduledoc """
  The touch panel over the NanoKVM-Go's LCD.

  Subscribers receive, in the display's pixels from the top left corner:

    * `{NanoKVMGo.Touch, {:down, x, y}}` when a finger touches
    * `{NanoKVMGo.Touch, {:move, x, y}}` while it moves
    * `{NanoKVMGo.Touch, {:up, x, y}}` when it lets go, where it was last

  The panel reaches a little below the display: there `y` is past its last
  row.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Touch` by default
    * `:device` - the input device, by default the one of the panel's
      driver (`hynitron-cst816x`)
  """
  use GenServer
  require Logger

  alias NanoKVMGo.Input

  @driver_name "Hynitron CST816x Series Touchscreen"
  @retry_delay 2_000

  # The codes of struct input_event used here.
  @ev_syn 0
  @ev_key 1
  @ev_abs 3
  @btn_touch 0x14A
  @abs_x 0
  @abs_y 1

  @type event() :: {:down | :move | :up, non_neg_integer(), non_neg_integer()}

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
  Sends touches to the caller until it unsubscribes or exits.
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

    state = %{
      device: Keyword.get_lazy(opts, :device, &find_device/0),
      reader: nil,
      subscribers: %{},
      touching: false,
      x: 0,
      y: 0,
      reported: nil
    }

    {:ok, start_reader(state)}
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
    {:noreply,
     for(<<event::binary-size(16) <- data>>,
       reduce: state,
       do: (e -> handle_event(e, event))
     )}
  end

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    Logger.warning("nano_kvm_go: touch panel #{inspect(state.device)}: #{inspect(reason)}")
    Process.send_after(self(), :retry, @retry_delay)
    {:noreply, %{state | reader: nil}}
  end

  def handle_info(:retry, state) do
    {:noreply, start_reader(%{state | device: state.device || find_device()})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_event(
         state,
         <<_time::binary-size(8), type::little-16, code::little-16, value::little-signed-32>>
       ) do
    case {type, code} do
      {@ev_abs, @abs_x} -> %{state | x: value}
      {@ev_abs, @abs_y} -> %{state | y: value}
      {@ev_key, @btn_touch} -> %{state | touching: value == 1}
      {@ev_syn, 0} -> report(state)
      _other -> state
    end
  end

  # A report a frame, when the touch changed.
  defp report(state) do
    event = touch_event(state.touching, state.reported, {state.x, state.y})

    if event do
      Enum.each(state.subscribers, fn {pid, _monitor} -> send(pid, {__MODULE__, event}) end)
    end

    %{state | reported: last_reported(state.touching, event, state.reported)}
  end

  defp touch_event(true, nil, {x, y}), do: {:down, x, y}
  defp touch_event(true, {_kind, x, y}, {x, y}), do: nil
  defp touch_event(true, _last, {x, y}), do: {:move, x, y}
  defp touch_event(false, nil, _position), do: nil
  defp touch_event(false, _last, {x, y}), do: {:up, x, y}

  defp last_reported(false, _event, _last), do: nil
  defp last_reported(true, nil, last), do: last
  defp last_reported(true, event, _last), do: event

  defp start_reader(%{device: nil} = state) do
    Process.send_after(self(), :retry, @retry_delay)
    state
  end

  defp start_reader(state), do: %{state | reader: Input.start_reader(self(), state.device)}

  defp find_device, do: Input.find(@driver_name)
end
