defmodule NanoKVMGo.Expansion do
  @moduledoc """
  The two lines of the auxiliary USB-C port, the one with the lightning
  icon. They are the SoC's UART3 pads, which the NanoKVM-Go system's kernel
  makes a UART, GPIOs, PWM outputs or an I2C bus; Sipeed's Finger Robot is
  a servo on them. Both are inputs pulled down until a mode is set:

  | Mode        | Line 0                | Line 1                |
  | ----------- | --------------------- | --------------------- |
  | `:off`      | input, pulled down    | input, pulled down    |
  | `:uart`     | UART TXD (`"ttyS3"`)  | UART RXD              |
  | `:gpio`     | GPIO                  | GPIO                  |
  | `:pwm`      | PWM output            | PWM output            |
  | `:pwm_gpio` | PWM output            | GPIO                  |
  | `:gpio_pwm` | GPIO                  | PWM output            |
  | `:i2c`      | I2C SDA (`"i2c-2"`)   | I2C SCL               |

      NanoKVMGo.Expansion.set_mode(:pwm_gpio)
      NanoKVMGo.Expansion.set_pwm(0, 20_000_000, 1_500_000)
      NanoKVMGo.Expansion.subscribe()
      NanoKVMGo.Expansion.read(1)
      #=> {:ok, 0}

  Subscribers get `{NanoKVMGo.Expansion, {:edge, line, value, timestamp}}`
  for each edge of a GPIO input, the timestamp in nanoseconds of the
  monotonic clock. A line becomes an output with `write/3` and an input
  again with `read/2` or `subscribe/1`.

  The mode is kept in the U-Boot environment, `nanokvm_expansion`, and set
  again when this process starts; `persist: false` keeps it until the next
  boot only. The GPIOs and PWM channels this process opened are given back
  before the mode changes, and the kernel refuses a mode change with
  `{:error, :busy}` while other code holds them. Use `Circuits.UART` on
  `"ttyS3"` in the `:uart` mode and `Circuits.I2C` on `"i2c-2"` in the
  `:i2c` mode; the I2C bus is bit-banged at about 50 kHz and needs pull-ups
  on the other side.

  Which USB-C contacts carry the lines, SBU1/SBU2 or D+/D-, and at what
  voltage, most likely 3.3 V, is not known yet. Measure before connecting
  anything but the Finger Robot. On SBU, flipping the plug swaps the lines.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Expansion` by default
    * `:device` - the kernel driver's sysfs directory,
      `/sys/devices/platform/expansion` by default
    * `:pwm_chip` - the PWM chip's sysfs directory, by default the one of
      the SoC's PWM1 (`6061000.pwm`)
    * `:kv` - where the mode is kept, `Nerves.Runtime.KV` by default
    * `:gpio` - the GPIO library, `Circuits.GPIO` by default
  """
  use GenServer

  require Logger

  alias NanoKVMGo.Options

  @type mode() :: :off | :uart | :gpio | :pwm | :pwm_gpio | :gpio_pwm | :i2c
  @type line() :: 0 | 1
  @type role() :: :off | :uart_txd | :uart_rxd | :gpio | :pwm | :i2c_sda | :i2c_scl

  @type line_info() :: %{
          line: line(),
          role: role(),
          gpio: %{direction: :input | :output, value: 0 | 1} | nil,
          pwm: %{period: pos_integer(), duty_cycle: non_neg_integer()} | nil
        }

  @type info() :: %{
          mode: mode(),
          modes: [mode()],
          lines: [line_info()],
          uart: String.t(),
          i2c: String.t()
        }

  @typedoc "A message to subscribers, see the module documentation."
  @type message() :: {NanoKVMGo.Expansion, {:edge, line(), 0 | 1, integer()}}

  @type option() ::
          {:name, GenServer.name()}
          | {:device, Path.t()}
          | {:pwm_chip, Path.t()}
          | {:kv, module()}
          | {:gpio, module()}

  @roles %{
    off: {:off, :off},
    uart: {:uart_txd, :uart_rxd},
    gpio: {:gpio, :gpio},
    pwm: {:pwm, :pwm},
    pwm_gpio: {:pwm, :gpio},
    gpio_pwm: {:gpio, :pwm},
    i2c: {:i2c_sda, :i2c_scl}
  }

  @known_modes Map.keys(@roles)
  @modes Map.new(@known_modes, &{&1 |> Atom.to_string() |> String.replace("_", "-"), &1})
  @lines [0, 1]
  @gpio_names {"EXPANSION0", "EXPANSION1"}
  @variable "nanokvm_expansion"
  @pwm_device "6061000.pwm"

  @doc """
  Starts the process and sets the kept mode. See the module documentation
  for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Options.validate!(
        opts,
        [
          :pwm_chip,
          name: __MODULE__,
          device: "/sys/devices/platform/expansion",
          kv: Nerves.Runtime.KV,
          gpio: Circuits.GPIO
        ],
        &valid?/2
      )

    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  The mode, the modes the kernel offers and what each line is: a GPIO's
  direction and value, a PWM's period and duty cycle in nanoseconds, while
  this process has them.
  """
  @spec info(GenServer.server()) :: {:ok, info()} | {:error, term()}
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  Sets the mode, kept for the next boots unless `persist: false`:
  `set_mode(:uart)`, `set_mode(server, :uart)` or
  `set_mode(server, :uart, persist: false)`. A mode the kernel does not
  offer gives `{:error, {:unknown_mode, mode}}`.
  """
  @spec set_mode(GenServer.server(), mode(), [{:persist, boolean()}]) :: :ok | {:error, term()}
  def set_mode(server \\ __MODULE__, mode, opts \\ []) when mode in @known_modes do
    opts = Options.validate!(opts, [persist: true], &valid?/2)
    GenServer.call(server, {:set_mode, mode, opts[:persist]})
  end

  @doc """
  Reads a GPIO line, making it an input.
  """
  @spec read(GenServer.server(), line()) :: {:ok, 0 | 1} | {:error, term()}
  def read(server \\ __MODULE__, line) when line in @lines,
    do: GenServer.call(server, {:read, line})

  @doc """
  Drives a GPIO line, making it an output.
  """
  @spec write(GenServer.server(), line(), 0 | 1) :: :ok | {:error, term()}
  def write(server \\ __MODULE__, line, value) when line in @lines and value in [0, 1],
    do: GenServer.call(server, {:write, line, value})

  @doc """
  Sends the caller the edges of the GPIO inputs, now and after mode changes.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc """
  Stops sending the caller edges.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  @doc """
  Runs a PWM line: high for `duty_cycle` of every `period` nanoseconds. The
  timer counts 24 MHz, in steps of 41.7 ns; a change starts a new period.
  """
  @spec set_pwm(GenServer.server(), line(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def set_pwm(server \\ __MODULE__, line, period, duty_cycle)
      when line in @lines and is_integer(period) and period > 0 and is_integer(duty_cycle) and
             duty_cycle >= 0 and duty_cycle <= period do
    GenServer.call(server, {:set_pwm, line, period, duty_cycle})
  end

  @doc """
  Stops a PWM line and gives its channel back.
  """
  @spec stop_pwm(GenServer.server(), line()) :: :ok | {:error, term()}
  def stop_pwm(server \\ __MODULE__, line) when line in @lines,
    do: GenServer.call(server, {:stop_pwm, line})

  @impl GenServer
  def init(config) do
    # For terminate/2 to give the lines back when the supervisor stops it.
    Process.flag(:trap_exit, true)

    state = %{
      device: config.device,
      pwm_chip: Map.get_lazy(config, :pwm_chip, &find_pwm_chip/0),
      kv: config.kv,
      gpio: config.gpio,
      gpios: %{},
      pwms: %{},
      subscribers: %{}
    }

    {:ok, state, {:continue, :restore}}
  end

  @impl GenServer
  def handle_continue(:restore, state) do
    # PWM channels a crashed predecessor left exported would block mode changes.
    state = Enum.reduce(@lines, state, &stop_pwm_channel(&2, &1))
    :ok = restore_mode(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    with {:ok, mode} <- read_mode(state), {:ok, modes} <- read_modes(state) do
      lines = for line <- @lines, do: line_info(state, mode, line)
      info = %{mode: mode, modes: modes, lines: lines, uart: "ttyS3", i2c: "i2c-2"}
      {:reply, {:ok, info}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:set_mode, mode, persist}, _from, state) do
    with {:ok, modes} <- read_modes(state),
         :ok <- if(mode in modes, do: :ok, else: {:error, {:unknown_mode, mode}}) do
      change_mode(release(state), mode, persist)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:read, line}, _from, state) do
    case open_gpio(state, line, :input) do
      {:ok, state} -> {:reply, {:ok, state.gpio.read(state.gpios[line].handle)}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:write, line, value}, _from, state) do
    case open_gpio(state, line, {:output, value}) do
      {:ok, state} ->
        {:reply, state.gpio.write(state.gpios[line].handle, value),
         put_in(state.gpios[line].value, value)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid),
        do: state,
        else: put_in(state.subscribers[pid], Process.monitor(pid))

    {:reply, :ok, watch(state, current_mode(state))}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:set_pwm, line, period, duty_cycle}, _from, state) do
    with :ok <- check_role(state, line, :pwm),
         {:ok, dir} <- export_pwm(state, line),
         :ok <- write_pwm(dir, state.pwms[line], period, duty_cycle),
         :ok <- write_file(dir, "enable", 1) do
      {:reply, :ok, put_in(state.pwms[line], %{period: period, duty_cycle: duty_cycle})}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:stop_pwm, line}, _from, state) do
    {:reply, :ok, stop_pwm_channel(state, line)}
  end

  @impl GenServer
  def handle_info({:circuits_gpio, name, timestamp, value}, state) do
    case Enum.find(@lines, &(elem(@gpio_names, &1) == name)) do
      nil ->
        :ok

      line ->
        state.subscribers
        |> Map.keys()
        |> Enum.each(&send(&1, {__MODULE__, {:edge, line, value, timestamp}}))
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def terminate(_reason, state), do: release(state)

  # The mode the kernel has.

  defp read_mode(state) do
    with {:ok, text} <- File.read(Path.join(state.device, "mode")) do
      {:ok, to_mode(String.trim(text))}
    end
  end

  defp current_mode(state) do
    case read_mode(state) do
      {:ok, mode} -> mode
      {:error, _reason} -> :off
    end
  end

  defp read_modes(state) do
    with {:ok, text} <- File.read(Path.join(state.device, "modes")) do
      {:ok, for(name <- String.split(text), Map.has_key?(@modes, name), do: @modes[name])}
    end
  end

  # After release/1: the subscribers watch the mode there is afterwards.
  defp change_mode(state, mode, persist) do
    with :ok <- write_mode(state, mode),
         :ok <- if(persist, do: keep_mode(state, mode), else: :ok) do
      {:reply, :ok, watch(state, mode)}
    else
      error -> {:reply, error, watch(state, current_mode(state))}
    end
  end

  defp write_mode(state, mode) do
    case write_file(state.device, "mode", from_mode(mode)) do
      {:error, :ebusy} -> {:error, :busy}
      other -> other
    end
  end

  defp to_mode(name), do: Map.get(@modes, name, :off)
  defp from_mode(mode), do: mode |> Atom.to_string() |> String.replace("_", "-")

  # The mode kept in the U-Boot environment; "" is the mode at boot.

  defp kept_mode(state) do
    with true <- Code.ensure_loaded?(state.kv),
         name when is_binary(name) and name != "" <- state.kv.get(@variable),
         {:ok, mode} <- Map.fetch(@modes, name),
         {:ok, modes} <- read_modes(state),
         true <- mode in modes do
      {:ok, mode}
    else
      _ -> :none
    end
  end

  defp restore_mode(state) do
    with {:ok, kept} <- kept_mode(state),
         {:ok, mode} when mode != kept <- read_mode(state),
         {:error, reason} <- write_mode(state, kept) do
      Logger.warning("Expansion lines not set to #{inspect(kept)}: #{inspect(reason)}")
    else
      _ -> :ok
    end
  end

  defp keep_mode(state, mode) do
    value = if mode == :off, do: "", else: from_mode(mode)

    if Code.ensure_loaded?(state.kv) do
      with {:error, reason} <- state.kv.put(%{@variable => value}),
           do: {:error, {:not_kept, reason}}
    else
      {:error, {:not_kept, {:undefined, state.kv}}}
    end
  end

  # What each line is, and what this process holds of it.

  defp role(mode, line), do: @roles |> Map.fetch!(mode) |> elem(line)

  defp check_role(state, line, wanted) do
    case read_mode(state) do
      {:ok, mode} ->
        cond do
          role(mode, line) == wanted -> :ok
          wanted == :gpio -> {:error, {:not_gpio, line}}
          wanted == :pwm -> {:error, {:not_pwm, line}}
        end

      error ->
        error
    end
  end

  defp line_info(state, mode, line) do
    gpio =
      case state.gpios[line] do
        nil -> nil
        gpio -> %{direction: gpio.direction, value: state.gpio.read(gpio.handle)}
      end

    %{line: line, role: role(mode, line), gpio: gpio, pwm: state.pwms[line]}
  end

  # GPIO lines open as inputs with edges for the subscribers, or as outputs.

  defp open_gpio(state, line, direction) do
    with :ok <- check_role(state, line, :gpio) do
      case {state.gpios[line], direction} do
        {%{direction: :input}, :input} ->
          {:ok, state}

        {%{direction: :output}, {:output, _value}} ->
          {:ok, state}

        {nil, direction} ->
          open_new_gpio(state, line, direction)

        {%{handle: handle}, direction} ->
          :ok = state.gpio.close(handle)
          open_new_gpio(%{state | gpios: Map.delete(state.gpios, line)}, line, direction)
      end
    end
  end

  defp open_new_gpio(state, line, direction) do
    name = elem(@gpio_names, line)

    {circuits_direction, opts, value} =
      case direction do
        :input -> {:input, [], nil}
        {:output, value} -> {:output, [initial_value: value], value}
      end

    with {:ok, handle} <- state.gpio.open(name, circuits_direction, opts) do
      gpio = %{handle: handle, direction: circuits_direction, value: value, edges: false}
      {:ok, edges(put_in(state.gpios[line], gpio), line)}
    end
  end

  # Edges of an input line for the subscribers, if there are any.
  defp edges(state, line) do
    case state.gpios[line] do
      %{direction: :input, edges: false, handle: handle} when map_size(state.subscribers) > 0 ->
        :ok = state.gpio.set_interrupts(handle, :both, receiver: self())
        put_in(state.gpios[line].edges, true)

      _ ->
        state
    end
  end

  # Edges of a mode's GPIO inputs for the subscribers: unopened lines open
  # as inputs, outputs stay outputs.
  defp watch(state, mode) when map_size(state.subscribers) > 0,
    do: Enum.reduce(@lines, state, &watch_line(&2, mode, &1))

  defp watch(state, _mode), do: state

  defp watch_line(state, mode, line) do
    case {role(mode, line), state.gpios[line]} do
      {:gpio, nil} -> state |> open_gpio(line, :input) |> opened(state)
      {:gpio, %{direction: :input}} -> edges(state, line)
      _other -> state
    end
  end

  defp opened({:ok, state}, _state), do: state
  defp opened({:error, _reason}, state), do: state

  # PWM channels through the chip's sysfs directory.

  defp export_pwm(%{pwm_chip: nil}, _line), do: {:error, :no_pwm_chip}

  defp export_pwm(state, line) do
    dir = Path.join(state.pwm_chip, "pwm#{line}")

    cond do
      File.dir?(dir) -> {:ok, dir}
      (result = write_file(state.pwm_chip, "export", line)) != :ok -> busy(result)
      true -> {:ok, dir}
    end
  end

  defp busy({:error, :ebusy}), do: {:error, :busy}
  defp busy(other), do: other

  # The kernel refuses a duty cycle longer than the period: shorten first.
  defp write_pwm(dir, %{duty_cycle: old_duty}, period, duty_cycle) when old_duty > period do
    with :ok <- write_file(dir, "duty_cycle", duty_cycle),
         do: write_file(dir, "period", period)
  end

  defp write_pwm(dir, _old, period, duty_cycle) do
    with :ok <- write_file(dir, "period", period),
         do: write_file(dir, "duty_cycle", duty_cycle)
  end

  defp stop_pwm_channel(state, line) do
    :ok = unexport_pwm(state, line)
    %{state | pwms: Map.delete(state.pwms, line)}
  end

  defp unexport_pwm(%{pwm_chip: nil}, _line), do: :ok

  defp unexport_pwm(state, line) do
    dir = Path.join(state.pwm_chip, "pwm#{line}")

    with true <- File.dir?(dir),
         :ok <- write_file(dir, "enable", 0),
         {:error, reason} <- write_file(state.pwm_chip, "unexport", line) do
      Logger.warning("PWM line #{line} not given back: #{inspect(reason)}")
    else
      _ -> :ok
    end
  end

  defp find_pwm_chip do
    Enum.find(Path.wildcard("/sys/class/pwm/pwmchip*"), fn chip ->
      case File.read_link(Path.join(chip, "device")) do
        {:ok, target} -> Path.basename(target) == @pwm_device
        {:error, _reason} -> false
      end
    end)
  end

  # Gives back the GPIOs and PWM channels this process opened.
  defp release(state) do
    for {_line, %{handle: handle}} <- state.gpios, do: state.gpio.close(handle)
    Enum.reduce(Map.keys(state.pwms), %{state | gpios: %{}}, &stop_pwm_channel(&2, &1))
  end

  defp write_file(dir, name, value), do: File.write(Path.join(dir, name), to_string(value))

  defp valid?(:name, _name), do: true
  defp valid?(:device, device), do: is_binary(device)
  defp valid?(:pwm_chip, pwm_chip), do: is_binary(pwm_chip)
  defp valid?(:kv, kv), do: is_atom(kv)
  defp valid?(:gpio, gpio), do: is_atom(gpio)
  defp valid?(:persist, persist), do: is_boolean(persist)
end
