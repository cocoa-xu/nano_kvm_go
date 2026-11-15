defmodule NanoKVM.HID do
  @moduledoc """
  Keyboard, mouse and touch input for the target computer.

  It needs the `:keyboard`, `:mouse` and `:relative_mouse` functions of
  `NanoKVM.USB`, those it uses. The process keeps the keys and buttons held
  and sends a report on each change, so callers only send changes:

      NanoKVM.HID.key("ShiftLeft", :down)
      NanoKVM.HID.key("KeyA", :down)
      NanoKVM.HID.key("KeyA", :up)
      NanoKVM.HID.key("ShiftLeft", :up)

      NanoKVM.HID.pointer(x: 0.5, y: 0.5)
      NanoKVM.HID.pointer(buttons: [:left])
      NanoKVM.HID.pointer(buttons: [])
      NanoKVM.HID.pointer(wheel: -1)

      NanoKVM.HID.type("Hello!\n")

      NanoKVM.HID.relative(dx: 10, dy: -3)
      NanoKVM.HID.touch([{0, 0.2, 0.3}, {1, 0.6, 0.3}])

  Keys are `KeyboardEvent.code` values (see `NanoKVM.HID.Keymap`) or HID
  usages. `pointer/2` and `touch/2` place the pointer from 0.0 (left, top)
  to 1.0 (right, bottom) across the target's screen, with the `:mouse`
  function in its mode: an absolute mouse, a pen (where the left button
  puts the tip down) or a touch screen (where it touches). `relative/2`
  moves the `:relative_mouse`, which BIOS setups and games take.

  Input wakes a target that sleeps, where it lets its USB devices wake it.
  Without a device (the function is missing, or went away while the gadget
  changed) reports are dropped, and the device is opened again a little
  later. While the target does not take reports (unplugged, asleep), only
  the newest report is kept for when it does: no key stays held.

  ## Options

    * `:name` - the name to register, `NanoKVM.HID` by default
    * `:keyboard`, `:mouse`, `:relative_mouse` - device paths; by default the
      devices of the `NanoKVM.USB` functions
    * `:gadget` - where to look the devices up, see `NanoKVM.USB`
  """
  use GenServer

  import Bitwise

  alias NanoKVM.HID.Descriptor
  alias NanoKVM.HID.Keymap
  alias NanoKVM.HID.Report
  alias NanoKVM.HID.Writer

  @retry_delay 2_000
  # Input wakes the target at most this often.
  @wake_every_ms 1_000
  # Between the reports of typed keys: hosts poll the keyboard each 1 ms.
  @type_delay_ms 8

  @kinds [:keyboard, :mouse, :relative_mouse]
  @buttons %{left: 1, right: 2, middle: 4, back: 8, forward: 16}

  @typedoc "A `KeyboardEvent.code` value or a HID usage."
  @type key() :: Keymap.code() | 0x04..0xDD | 0xE0..0xE7

  @type button() :: :left | :right | :middle | :back | :forward

  @type pointer_change() ::
          {:x, number()}
          | {:y, number()}
          | {:buttons, [button()]}
          | {:wheel, integer()}
          | {:pan, integer()}

  @type relative_change() ::
          {:dx, integer()}
          | {:dy, integer()}
          | {:buttons, [button()]}
          | {:wheel, integer()}
          | {:pan, integer()}

  @typedoc "A touch: an id from 0 to 9 and where, from 0.0 to 1.0."
  @type contact() :: {0..9, number(), number()}

  @type device_stats() :: %{
          device: Path.t() | nil,
          sent: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @type stats() :: %{
          keyboard: device_stats(),
          mouse: device_stats(),
          relative_mouse: device_stats()
        }

  @type option() ::
          {:name, GenServer.name()}
          | {:keyboard, Path.t()}
          | {:mouse, Path.t()}
          | {:relative_mouse, Path.t()}
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
  Types text on the target as a US keyboard would, a key at a time, and
  returns when done: some 60 characters a second. Characters that keyboard
  has no key for are left out.
  """
  @spec type(GenServer.server(), String.t()) :: :ok
  def type(server \\ __MODULE__, text) when is_binary(text) do
    for char <- String.to_charlist(text),
        {code, shift} = Keymap.character(char) || {nil, false},
        code do
      if shift, do: key(server, "ShiftLeft", :down)
      key(server, code, :down)
      Process.sleep(@type_delay_ms)
      key(server, code, :up)
      if shift, do: key(server, "ShiftLeft", :up)
      Process.sleep(@type_delay_ms)
    end

    :ok
  end

  @doc """
  Moves the absolute pointer, presses or releases buttons, turns the wheels
  (`:wheel` up, `:pan` right). What is not given stays as it is; the wheels
  turn only once.
  """
  @spec pointer(GenServer.server(), [pointer_change()]) :: :ok
  def pointer(server \\ __MODULE__, changes) when is_list(changes) do
    GenServer.cast(server, {:pointer, changes})
  end

  @doc """
  Moves the relative mouse by `:dx` and `:dy` (right, down), presses or
  releases its buttons, turns its wheels.
  """
  @spec relative(GenServer.server(), [relative_change()]) :: :ok
  def relative(server \\ __MODULE__, changes) when is_list(changes) do
    GenServer.cast(server, {:relative, changes})
  end

  @doc """
  The contacts touching the screen now, up to ten: on a touch screen each,
  else the first as the pointer with the left button.
  """
  @spec touch(GenServer.server(), [contact()]) :: :ok
  def touch(server \\ __MODULE__, contacts) when is_list(contacts) do
    GenServer.cast(server, {:touch, Enum.take(contacts, 10)})
  end

  @doc """
  Releases all keys, buttons and touches, for example when the user goes
  away. It does not wake the target.
  """
  @spec release_all(GenServer.server()) :: :ok
  def release_all(server \\ __MODULE__), do: GenServer.cast(server, :release_all)

  @doc """
  The devices in use and the reports sent and dropped for each.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc """
  The mode of the absolute pointer: `:absolute`, `:stylus` or `:touch`.
  """
  @spec pointer_mode(GenServer.server()) :: Descriptor.pointer_mode()
  def pointer_mode(server \\ __MODULE__), do: GenServer.call(server, :pointer_mode)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      gadget: Keyword.get(opts, :gadget, NanoKVM.USB.default_gadget()),
      # For tests: where the device controllers are listed.
      udc_class: Keyword.get(opts, :udc_class, "/sys/class/udc"),
      paths: Map.new(@kinds, &{&1, opts[&1]}),
      writers: Map.new(@kinds, &{&1, nil}),
      sent: Map.new(@kinds, &{&1, 0}),
      dropped: Map.new(@kinds, &{&1, 0}),
      retry: nil,
      woke: nil,
      mode: :absolute,
      modifiers: 0,
      keys: [],
      buttons: 0,
      x: 0,
      y: 0,
      relative_buttons: 0
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

    wheel = changes |> Keyword.get(:wheel, 0) |> clamp()
    pan = changes |> Keyword.get(:pan, 0) |> clamp()
    {:noreply, pointer_report(new, state, wheel, pan)}
  end

  def handle_cast({:relative, changes}, state) do
    buttons = changes |> Keyword.get(:buttons) |> button_bits(state.relative_buttons)
    state = %{state | relative_buttons: buttons}

    steps =
      steps(Keyword.get(changes, :dx, 0), Keyword.get(changes, :dy, 0))
      |> List.update_at(0, fn {dx, dy} ->
        {dx, dy, clamp(Keyword.get(changes, :wheel, 0)), clamp(Keyword.get(changes, :pan, 0))}
      end)

    {:noreply,
     Enum.reduce(steps, state, fn
       {dx, dy}, state ->
         send_report(state, :relative_mouse, Report.relative_mouse(buttons, dx, dy, 0, 0))

       {dx, dy, w, p}, state ->
         send_report(state, :relative_mouse, Report.relative_mouse(buttons, dx, dy, w, p))
     end)}
  end

  def handle_cast({:touch, contacts}, %{mode: :touch} = state) do
    report =
      Report.touch(for {id, x, y} <- contacts, do: {id, Report.absolute(x), Report.absolute(y)})

    {:noreply, send_report(state, :mouse, report)}
  end

  def handle_cast({:touch, contacts}, state) do
    changes =
      case contacts do
        [{_id, x, y} | _rest] -> [x: x, y: y, buttons: [:left]]
        [] -> [buttons: []]
      end

    handle_cast({:pointer, changes}, state)
  end

  def handle_cast(:release_all, state) do
    state = %{state | modifiers: 0, keys: [], buttons: 0, relative_buttons: 0}

    released =
      case state.mode do
        :absolute -> Report.mouse(0, state.x, state.y, 0, 0)
        :stylus -> Report.stylus(false, false, state.x, state.y)
        :touch -> Report.touch([])
      end

    state =
      state
      |> send_report(:keyboard, Report.keyboard(0, []), false)
      |> send_report(:mouse, released, false)
      |> send_report(:relative_mouse, Report.relative_mouse(0, 0, 0, 0, 0), false)

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

  def handle_call(:pointer_mode, _from, state), do: {:reply, state.mode, state}

  @impl GenServer
  def handle_info(:retry, state), do: {:noreply, open_devices(%{state | retry: nil})}

  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(@kinds, fn kind -> match?(%{pid: ^pid}, state.writers[kind]) end) do
      nil -> {:noreply, state}
      kind -> {:noreply, state |> put_in([:writers, kind], nil) |> schedule_retry()}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The absolute pointer's report, in its mode, when something changed.
  defp pointer_report(new, old, wheel, pan) do
    moved = {new.x, new.y, new.buttons} != {old.x, old.y, old.buttons}

    case mode_report(new.mode, new, old, moved, {wheel, pan}) do
      nil -> new
      report -> send_report(new, :mouse, report)
    end
  end

  defp mode_report(:absolute, new, _old, moved, {wheel, pan})
       when moved or wheel != 0 or pan != 0,
       do: Report.mouse(new.buttons, new.x, new.y, wheel, pan)

  defp mode_report(:stylus, new, _old, true, _wheels),
    do: Report.stylus(left?(new), true, new.x, new.y)

  # A touch screen has no pointer without a touch.
  defp mode_report(:touch, new, old, true, _wheels) do
    cond do
      left?(new) -> Report.touch([{0, new.x, new.y}])
      left?(old) -> Report.touch([])
      true -> nil
    end
  end

  defp mode_report(_mode, _new, _old, _moved, _wheels), do: nil

  defp left?(state), do: (state.buttons &&& 1) == 1

  # Movements beyond what a report carries, in steps.
  defp steps(dx, dy) do
    n = max(1, ceil(max(abs(dx), abs(dy)) / 127))

    for i <- 1..n do
      {div(dx * i, n) - div(dx * (i - 1), n), div(dy * i, n) - div(dy * (i - 1), n)}
    end
  end

  defp clamp(steps) when is_integer(steps), do: steps |> max(-127) |> min(127)
  defp clamp(_steps), do: 0

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
  defp classify(usage) when usage in 0x04..0xDD, do: {:usage, usage}
  defp classify(_key), do: :unknown

  # The keyboard reports six keys; more held keys are left out.
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
    Enum.reduce(buttons, 0, &(Map.get(@buttons, &1, 0) ||| &2))
  end

  defp send_report(state, kind, report, wake \\ true) do
    case state.writers[kind] do
      %{pid: writer} ->
        state = if wake, do: wake(state), else: state
        :ok = Writer.write(writer, report)
        update_in(state, [:sent, kind], &(&1 + 1))

      nil ->
        update_in(state, [:dropped, kind], &(&1 + 1))
    end
  end

  # Input asks the device controller to wake a target that suspended it;
  # the target allowed it when it went to sleep.
  defp wake(state) do
    now = System.monotonic_time(:millisecond)

    if state.woke && now - state.woke < @wake_every_ms do
      state
    else
      _result =
        with {:ok, udc} <- File.read(Path.join(state.gadget, "UDC")),
             dir = Path.join(state.udc_class, String.trim(udc)),
             {:ok, "suspended" <> _rest} <- File.read(Path.join(dir, "state")) do
          File.write(Path.join(dir, "srp"), "1")
        end

      %{state | woke: now}
    end
  end

  defp open_devices(state) do
    state =
      Enum.reduce(@kinds, state, fn kind, state ->
        if state.writers[kind],
          do: state,
          else: put_in(state, [:writers, kind], open(state, kind))
      end)

    state = %{state | mode: read_pointer_mode(state)}
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

  # The function's report descriptor tells the mode.
  defp read_pointer_mode(state) do
    path = Path.join(NanoKVM.USB.function_dir(:mouse, gadget: state.gadget), "report_desc")

    with {:ok, report_desc} <- File.read(path),
         mode when mode != nil <- Descriptor.pointer_mode(report_desc) do
      mode
    else
      _ -> :absolute
    end
  end

  defp schedule_retry(%{retry: nil} = state) do
    %{state | retry: Process.send_after(self(), :retry, @retry_delay)}
  end

  defp schedule_retry(state), do: state
end
