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
    * `:program` - the port program that reads it, the library's
      `nano_kvm_go_input` by default
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
    state = %{
      device: Keyword.get(opts, :device),
      program: Keyword.get_lazy(opts, :program, &Input.program/0),
      port: nil,
      reading: nil,
      subscribers: %{},
      touching: false,
      x: 0,
      y: 0,
      reported: nil
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
      {:events, events} ->
        {:noreply, Enum.reduce(events, state, &handle_event/2)}

      {:log, line} ->
        Logger.debug("nano_kvm_go_input: " <> line)
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "nano_kvm_go: reading the touch panel from #{state.reading} stopped (#{status}), trying again"
    )

    Process.send_after(self(), :retry, @retry_delay)
    {:noreply, %{state | port: nil, reading: nil}}
  end

  def handle_info(:retry, state), do: {:noreply, start_reader(state)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_event({@ev_abs, @abs_x, x}, state), do: %{state | x: x}
  defp handle_event({@ev_abs, @abs_y, y}, state), do: %{state | y: y}
  defp handle_event({@ev_key, @btn_touch, value}, state), do: %{state | touching: value == 1}
  defp handle_event({@ev_syn, 0, _value}, state), do: report(state)
  defp handle_event(_event, state), do: state

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

  defp start_reader(state) do
    case state.device || Input.find(@driver_name) do
      nil ->
        Process.send_after(self(), :retry, @retry_delay)
        state

      device ->
        %{state | port: Input.open(state.program, device), reading: device}
    end
  end
end
