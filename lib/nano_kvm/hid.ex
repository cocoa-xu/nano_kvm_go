defmodule NanoKVM.HID do
  @moduledoc """
  Keyboard and mouse input for the target computer.

  It needs the `:keyboard` and `:mouse` functions of `NanoKVM.USB`. The
  process keeps the keys and buttons held and sends a boot keyboard report or
  an absolute mouse report on each change, so callers only send changes:

      NanoKVM.HID.key("ShiftLeft", :down)
      NanoKVM.HID.key("KeyA", :down)
      NanoKVM.HID.key("KeyA", :up)
      NanoKVM.HID.key("ShiftLeft", :up)

      NanoKVM.HID.pointer(x: 0.5, y: 0.5)
      NanoKVM.HID.pointer(buttons: [:left])
      NanoKVM.HID.pointer(buttons: [])
      NanoKVM.HID.pointer(wheel: -1)

  Keys are `KeyboardEvent.code` values (see `NanoKVM.HID.Keymap`) or HID
  usages. The pointer's `:x` and `:y` go from 0.0 (left, top) to 1.0 (right,
  bottom) across the target's screen; `:wheel` steps are positive upwards.

  Without a device (the function is missing, or went away while the gadget
  changed) reports are dropped, and the device is opened again a little
  later. While the target computer does not take reports (unplugged, asleep),
  only the newest report is kept for when it does: no key stays held.

  ## Options

    * `:name` - the name to register, `NanoKVM.HID` by default
    * `:keyboard`, `:mouse` - device paths; by default the devices of the
      `NanoKVM.USB` functions
    * `:gadget` - where to look the devices up, see `NanoKVM.USB`
  """
  use GenServer

  import Bitwise

  alias NanoKVM.HID.Keymap
  alias NanoKVM.HID.Report
  alias NanoKVM.HID.Writer

  @retry_delay 2_000

  @kinds [:keyboard, :mouse]

  @typedoc "A `KeyboardEvent.code` value or a HID usage."
  @type key() :: Keymap.code() | 0x04..0x65 | 0xE0..0xE7

  @type button() :: :left | :right | :middle

  @type pointer_change() ::
          {:x, number()} | {:y, number()} | {:buttons, [button()]} | {:wheel, integer()}

  @type device_stats() :: %{
          device: Path.t() | nil,
          sent: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @type stats() :: %{keyboard: device_stats(), mouse: device_stats()}

  @type option() ::
          {:name, GenServer.name()}
          | {:keyboard, Path.t()}
          | {:mouse, Path.t()}
          | {:gadget, Path.t()}

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Presses or releases a key.
  """
  @spec key(GenServer.server(), key(), :down | :up) :: :ok
  def key(server \\ __MODULE__, key, action) when action in [:down, :up] do
    GenServer.cast(server, {:key, key, action})
  end

  @doc """
  Moves the pointer, presses or releases buttons, turns the wheel. What is
  not given stays as it is; the wheel turns only once.
  """
  @spec pointer(GenServer.server(), [pointer_change()]) :: :ok
  def pointer(server \\ __MODULE__, changes) when is_list(changes) do
    GenServer.cast(server, {:pointer, changes})
  end

  @doc """
  Releases all keys and buttons, for example when the user goes away.
  """
  @spec release_all(GenServer.server()) :: :ok
  def release_all(server \\ __MODULE__), do: GenServer.cast(server, :release_all)

  @doc """
  The devices in use and the reports sent and dropped for each.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      gadget: Keyword.get(opts, :gadget, NanoKVM.USB.default_gadget()),
      paths: %{keyboard: opts[:keyboard], mouse: opts[:mouse]},
      writers: %{keyboard: nil, mouse: nil},
      sent: %{keyboard: 0, mouse: 0},
      dropped: %{keyboard: 0, mouse: 0},
      retry: nil,
      modifiers: 0,
      keys: [],
      buttons: 0,
      x: 0,
      y: 0
    }

    {:ok, open_devices(state)}
  end

  @impl GenServer
  def handle_cast({:key, key, action}, state) do
    {:noreply, state |> press(key, action) |> keyboard_report_if_changed(state)}
  end

  def handle_cast({:pointer, changes}, state) do
    new = %{
      state
      | x: changes |> Keyword.get(:x) |> absolute(state.x),
        y: changes |> Keyword.get(:y) |> absolute(state.y),
        buttons: changes |> Keyword.get(:buttons) |> button_bits(state.buttons)
    }

    wheel = changes |> Keyword.get(:wheel, 0) |> max(-127) |> min(127)

    if wheel != 0 or {new.x, new.y, new.buttons} != {state.x, state.y, state.buttons},
      do: {:noreply, send_report(new, :mouse, Report.mouse(new.buttons, new.x, new.y, wheel))},
      else: {:noreply, state}
  end

  def handle_cast(:release_all, state) do
    state = %{state | modifiers: 0, keys: [], buttons: 0}

    state =
      state
      |> send_report(:keyboard, Report.keyboard(0, []))
      |> send_report(:mouse, Report.mouse(0, state.x, state.y, 0))

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats =
      Map.new(@kinds, fn kind ->
        device = with %{path: path} <- state.writers[kind], do: path
        {kind, %{device: device, sent: state.sent[kind], dropped: state.dropped[kind]}}
      end)

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:retry, state), do: {:noreply, open_devices(%{state | retry: nil})}

  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(@kinds, fn kind -> match?(%{pid: ^pid}, state.writers[kind]) end) do
      nil -> {:noreply, state}
      kind -> {:noreply, state |> put_in([:writers, kind], nil) |> schedule_retry()}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp press(state, key, action) do
    case classify(key) do
      {:modifier, bit} when action == :down -> %{state | modifiers: state.modifiers ||| bit}
      {:modifier, bit} -> %{state | modifiers: state.modifiers &&& bnot(bit)}
      {:usage, usage} when action == :down -> %{state | keys: add_key(state.keys, usage)}
      {:usage, usage} -> %{state | keys: List.delete(state.keys, usage)}
      :unknown -> state
    end
  end

  defp classify(code) when is_binary(code) do
    case {Keymap.modifier(code), Keymap.usage(code)} do
      {nil, nil} -> :unknown
      {nil, usage} -> {:usage, usage}
      {bit, _usage} -> {:modifier, bit}
    end
  end

  defp classify(usage) when usage in 0xE0..0xE7, do: {:modifier, 1 <<< (usage - 0xE0)}
  defp classify(usage) when usage in 0x04..0x65, do: {:usage, usage}
  defp classify(_key), do: :unknown

  # The boot keyboard reports six keys; more held keys are left out.
  defp add_key(keys, usage) do
    if usage in keys or length(keys) >= 6, do: keys, else: keys ++ [usage]
  end

  defp keyboard_report_if_changed(new, old) do
    if {new.modifiers, new.keys} == {old.modifiers, old.keys},
      do: new,
      else: send_report(new, :keyboard, Report.keyboard(new.modifiers, new.keys))
  end

  defp absolute(nil, current), do: current
  defp absolute(position, _current) when is_number(position), do: Report.absolute(position)

  defp button_bits(nil, current), do: current

  defp button_bits(buttons, _current) when is_list(buttons) do
    Enum.reduce(buttons, 0, fn
      :left, bits -> bits ||| 1
      :right, bits -> bits ||| 2
      :middle, bits -> bits ||| 4
    end)
  end

  defp send_report(state, kind, report) do
    case state.writers[kind] do
      %{pid: writer} ->
        :ok = Writer.write(writer, report)
        update_in(state, [:sent, kind], &(&1 + 1))

      nil ->
        update_in(state, [:dropped, kind], &(&1 + 1))
    end
  end

  defp open_devices(state) do
    state =
      Enum.reduce(@kinds, state, fn kind, state ->
        if state.writers[kind],
          do: state,
          else: put_in(state, [:writers, kind], open(state, kind))
      end)

    if Enum.all?(@kinds, &state.writers[&1]), do: state, else: schedule_retry(state)
  end

  defp open(state, kind) do
    with {:ok, path} <- device_path(state, kind),
         {:ok, pid} <- Writer.start_link(path) do
      %{path: path, pid: pid}
    else
      _ -> nil
    end
  end

  defp device_path(%{paths: paths} = state, kind) do
    case paths[kind] do
      nil -> NanoKVM.USB.hid_device(kind, gadget: state.gadget)
      path -> {:ok, path}
    end
  end

  defp schedule_retry(%{retry: nil} = state) do
    %{state | retry: Process.send_after(self(), :retry, @retry_delay)}
  end

  defp schedule_retry(state), do: state
end
