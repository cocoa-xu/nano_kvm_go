defmodule NanoKVMGo.Backlight do
  @moduledoc """
  The LCD's backlight: LEDs that PWM1 channel 2 dims, through the kernel's
  `pwm-backlight` driver. Brightness follows lightness: 50 looks half as
  bright as 100.

      NanoKVMGo.Backlight.set_brightness(40)
      NanoKVMGo.Backlight.off()
      NanoKVMGo.Backlight.on()

  The PWM runs at 25 kHz, or at a frequency of your own; brightness and
  power stay as they are:

      NanoKVMGo.Backlight.set_frequency(100_000)
      NanoKVMGo.Backlight.info()
      #=> {:ok, %{on: true, brightness: 40, period: 10_000, frequency: 100_000.0,
      #=>         default_period: 40_000}}
      NanoKVMGo.Backlight.set_frequency(:default)

  The frequency goes to the driver's `pwm_period_ns` attribute, which this
  system's kernel adds. The timer counts 24 MHz, so a period is a whole
  number of 41.7 ns steps, and fewer steps make coarser brightness. Below
  about 100 Hz the light flickers. If the LEDs are switched by a small
  bipolar transistor, as in the panel's reference design, each pulse lasts
  about 0.3 µs longer than asked, which brightens low levels noticeably
  from about 100 kHz.

  ## Options

    * `:name` - the name to register, `NanoKVMGo.Backlight` by default
    * `:backlight` - the backlight's sysfs directory,
      `/sys/class/backlight/backlight` by default
  """
  use GenServer

  @type info() :: %{
          on: boolean(),
          brightness: 0..100,
          period: pos_integer() | nil,
          frequency: float() | nil,
          default_period: pos_integer() | nil
        }

  @type option() :: {:name, GenServer.name()} | {:backlight, Path.t()}

  @doc """
  Starts the process. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Turns the light on, at the brightness it had.
  """
  @spec on(GenServer.server()) :: :ok | {:error, term()}
  def on(server \\ __MODULE__), do: GenServer.call(server, {:power, true})

  @doc """
  Turns the light off, keeping its brightness for `on/1`.
  """
  @spec off(GenServer.server()) :: :ok | {:error, term()}
  def off(server \\ __MODULE__), do: GenServer.call(server, {:power, false})

  @doc """
  Sets the brightness in percent: 0 is dark, 100 the brightest, and each
  step looks as much brighter as the one before.
  """
  @spec set_brightness(GenServer.server(), 0..100) :: :ok | {:error, term()}
  def set_brightness(server \\ __MODULE__, percent) when percent in 0..100 do
    GenServer.call(server, {:set_brightness, percent})
  end

  @doc """
  The brightness in percent, see `set_brightness/2`.
  """
  @spec brightness(GenServer.server()) :: {:ok, 0..100} | {:error, term()}
  def brightness(server \\ __MODULE__), do: GenServer.call(server, :brightness)

  @doc """
  Runs the PWM at a frequency in Hz, rounded to a period of whole
  nanoseconds, or at the device tree's with `:default`. The kernel refuses
  a period the timer cannot make with `{:error, :einval}`.
  """
  @spec set_frequency(GenServer.server(), number() | :default) :: :ok | {:error, term()}
  def set_frequency(server \\ __MODULE__, frequency)

  def set_frequency(server, :default), do: GenServer.call(server, {:set_period, :default})

  def set_frequency(server, hz) when is_number(hz) and hz > 0 do
    case round(1.0e9 / hz) do
      0 -> {:error, :invalid_frequency}
      period -> GenServer.call(server, {:set_period, period})
    end
  end

  def set_frequency(_server, _hz), do: {:error, :invalid_frequency}

  @doc """
  Whether the light is on, its brightness, and the PWM's period in ns and
  frequency in Hz, now and by default; `nil` for what the kernel does not
  tell.
  """
  @spec info(GenServer.server()) :: {:ok, info()} | {:error, term()}
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @impl GenServer
  def init(opts) do
    {:ok, %{backlight: Keyword.get(opts, :backlight, "/sys/class/backlight/backlight")}}
  end

  @impl GenServer
  def handle_call({:power, on}, _from, state) do
    {:reply, write(state.backlight, "bl_power", if(on, do: 0, else: 4)), state}
  end

  def handle_call({:set_brightness, percent}, _from, state) do
    reply =
      with {:ok, max} <- read_integer(state.backlight, "max_brightness") do
        write(state.backlight, "brightness", round(percent * max / 100))
      end

    {:reply, reply, state}
  end

  def handle_call(:brightness, _from, state), do: {:reply, read_brightness(state), state}

  def handle_call({:set_period, :default}, _from, state) do
    reply =
      case default_period(state) do
        nil -> {:error, :no_default_period}
        period -> write(device(state), "pwm_period_ns", period)
      end

    {:reply, reply, state}
  end

  def handle_call({:set_period, period}, _from, state) do
    {:reply, write(device(state), "pwm_period_ns", period), state}
  end

  def handle_call(:info, _from, state) do
    with {:ok, brightness} <- read_brightness(state),
         {:ok, power} <- read_integer(state.backlight, "bl_power") do
      period =
        case read_integer(device(state), "pwm_period_ns") do
          {:ok, period} when period > 0 -> period
          _ -> nil
        end

      info = %{
        on: power == 0,
        brightness: brightness,
        period: period,
        frequency: period && 1.0e9 / period,
        default_period: default_period(state)
      }

      {:reply, {:ok, info}, state}
    else
      error -> {:reply, error, state}
    end
  end

  defp device(state), do: Path.join(state.backlight, "device")

  # The period in the device tree's `pwms = <&pwm channel period flags>`.
  defp default_period(state) do
    case File.read(Path.join([device(state), "of_node", "pwms"])) do
      {:ok, <<_pwm::32, _channel::32, period::32, _rest::binary>>} when period > 0 -> period
      _ -> nil
    end
  end

  defp read_brightness(state) do
    with {:ok, max} <- read_integer(state.backlight, "max_brightness"),
         {:ok, level} <- read_integer(state.backlight, "brightness") do
      if max > 0, do: {:ok, round(level * 100 / max)}, else: {:error, :no_levels}
    end
  end

  defp write(dir, name, value), do: File.write(Path.join(dir, name), to_string(value))

  defp read_integer(dir, name) do
    with {:ok, text} <- File.read(Path.join(dir, name)),
         {value, _rest} <- Integer.parse(String.trim(text)) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, {:not_a_number, name}}
    end
  end
end
