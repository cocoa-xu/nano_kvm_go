defmodule NanoKVM.Backlight do
  @moduledoc """
  The LCD's backlight: an LED driver that PWM1 channel 2 dims.

  By default the kernel's `pwm-backlight` driver runs the PWM at stock's
  2.16 kHz, and brightness follows lightness: 50 looks half as bright as
  100.

      NanoKVM.Backlight.set_brightness(40)
      NanoKVM.Backlight.off()
      NanoKVM.Backlight.on()

  For more control, take the PWM from the kernel and choose its frequency
  and duty cycle yourself. Brightness keeps working on top of it, on the
  same curve, until a duty cycle of your own replaces it:

      NanoKVM.Backlight.set_pwm(frequency: 25_000)
      NanoKVM.Backlight.set_brightness(60)
      NanoKVM.Backlight.set_pwm(frequency: 200, duty: 0.5)
      NanoKVM.Backlight.info()
      #=> {:ok, %{control: :user, on: true, brightness: 76, frequency: 200.0,
      #=>         period: 5_000_000, duty: 0.5}}
      NanoKVM.Backlight.release()

  Taking the PWM unbinds `pwm-backlight` and drives the channel through the
  kernel's PWM sysfs interface; `release/1` binds the driver again, at the
  brightness set meanwhile. The timer counts 24 MHz, so a period is a whole
  number of 41.7 ns steps. Below about 100 Hz the light flickers visibly;
  how fast the LED driver follows is not known, stock stays at 2.16 kHz.
  Off is a duty cycle of 0: what the channel drives while disabled is not
  known.

  ## Options

    * `:name` - the name to register, `NanoKVM.Backlight` by default
    * `:backlight` - the backlight's sysfs directory,
      `/sys/class/backlight/backlight` by default
    * `:driver` - the sysfs directory of `pwm-backlight` and the backlight's
      device, `{"/sys/bus/platform/drivers/pwm-backlight", "backlight"}` by
      default
    * `:pwm` - the sysfs directory of the PWM chip and the channel, by
      default the chip of `6061000.pwm` and channel 2
  """
  use GenServer

  @pwm_classes "/sys/class/pwm"
  @pwm_device "6061000.pwm"
  @channel 2
  # The period of the kernel's driver, from the device tree.
  @kernel_period 462_963
  # Two counts of the 24 MHz timer (12 MHz) to 100 s (0.01 Hz).
  @min_period 84
  @max_period 100_000_000_000

  @type info() :: %{
          required(:control) => :kernel | :user,
          required(:on) => boolean(),
          required(:brightness) => 0..100,
          optional(:frequency) => float(),
          optional(:period) => pos_integer(),
          optional(:duty) => float()
        }

  @type option() ::
          {:name, GenServer.name()}
          | {:backlight, Path.t()}
          | {:driver, {Path.t(), String.t()}}
          | {:pwm, {Path.t(), non_neg_integer()}}

  @typedoc """
  For `set_pwm/2`: `:frequency` in Hz (0.01 to 12 MHz) or `:period` in ns
  (84 to 10¹¹; by default the period running), and `:duty` from 0.0 to 1.0
  (by default the brightness's).
  """
  @type pwm_option() ::
          {:frequency, number()} | {:period, pos_integer()} | {:duty, number()}

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
  Takes the PWM from the kernel's driver, if it has it, and runs it at a
  frequency and duty cycle of your own; see `t:pwm_option/0`.
  """
  @spec set_pwm(GenServer.server(), [pwm_option()]) :: :ok | {:error, term()}
  def set_pwm(server \\ __MODULE__, opts) when is_list(opts) do
    GenServer.call(server, {:set_pwm, opts})
  end

  @doc """
  Gives the PWM back to the kernel's driver, at the brightness it has.
  """
  @spec release(GenServer.server()) :: :ok | {:error, term()}
  def release(server \\ __MODULE__), do: GenServer.call(server, :release)

  @doc """
  Who drives the PWM (`:kernel` or `:user`), whether the light is on, its
  brightness, and with `:user` the frequency in Hz, period in ns and duty
  cycle.
  """
  @spec info(GenServer.server()) :: {:ok, info()} | {:error, term()}
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @impl GenServer
  def init(opts) do
    {driver, device} =
      Keyword.get(opts, :driver, {"/sys/bus/platform/drivers/pwm-backlight", "backlight"})

    {chip, channel} = Keyword.get_lazy(opts, :pwm, fn -> {find_chip(), @channel} end)

    state = %{
      backlight: Keyword.get(opts, :backlight, "/sys/class/backlight/backlight"),
      driver: driver,
      device: device,
      chip: chip,
      channel: channel,
      control: :kernel,
      period: nil,
      applied: nil,
      duty: nil,
      on: true
    }

    {:ok, adopt(state)}
  end

  @impl GenServer
  def handle_call({:power, on}, _from, %{control: :kernel} = state) do
    {:reply, write(state.backlight, "bl_power", if(on, do: 0, else: 4)), state}
  end

  def handle_call({:power, on}, _from, state), do: run(%{state | on: on}, state)

  def handle_call({:set_brightness, percent}, _from, %{control: :kernel} = state) do
    reply =
      with {:ok, max} <- read_integer(state.backlight, "max_brightness") do
        write(state.backlight, "brightness", round(percent * max / 100))
      end

    {:reply, reply, state}
  end

  def handle_call({:set_brightness, percent}, _from, state),
    do: run(%{state | duty: luminance(percent)}, state)

  def handle_call(:brightness, _from, %{control: :kernel} = state),
    do: {:reply, kernel_brightness(state), state}

  def handle_call(:brightness, _from, state),
    do: {:reply, {:ok, percent(state.duty)}, state}

  def handle_call({:set_pwm, opts}, _from, state) do
    with {:ok, period} <- period(opts, state),
         {:ok, duty} <- duty(opts),
         {:ok, taken} <- take(state) do
      run(%{taken | period: period, duty: duty || taken.duty}, taken)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:release, _from, %{control: :kernel} = state), do: {:reply, :ok, state}

  def handle_call(:release, _from, state) do
    with :ok <- write(state.chip, "unexport", state.channel),
         :ok <- write(state.driver, "bind", state.device),
         {:ok, max} <- read_integer(state.backlight, "max_brightness"),
         :ok <- write(state.backlight, "brightness", round(percent(state.duty) * max / 100)),
         :ok <- write(state.backlight, "bl_power", if(state.on, do: 0, else: 4)) do
      {:reply, :ok, %{state | control: :kernel, period: nil, applied: nil}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:info, _from, %{control: :kernel} = state) do
    with {:ok, brightness} <- kernel_brightness(state),
         {:ok, power} <- read_integer(state.backlight, "bl_power") do
      {:reply, {:ok, %{control: :kernel, on: power == 0, brightness: brightness}}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      control: :user,
      on: state.on,
      brightness: percent(state.duty),
      frequency: 1.0e9 / state.period,
      period: state.period,
      duty: state.duty
    }

    {:reply, {:ok, info}, state}
  end

  # A channel left exported (by an earlier run of this process) is ours.
  defp adopt(%{chip: chip} = state) when is_binary(chip) do
    dir = channel_dir(state)

    with true <- File.dir?(dir),
         {:ok, period} when period > 0 <- read_integer(dir, "period"),
         {:ok, duty_ns} <- read_integer(dir, "duty_cycle") do
      on = duty_ns > 0
      duty = if on, do: duty_ns / period, else: 1.0
      %{state | control: :user, period: period, applied: period, duty: duty, on: on}
    else
      _ -> state
    end
  end

  defp adopt(state), do: state

  # The channel from the kernel's driver, keeping its brightness and power.
  defp take(%{control: :user} = state), do: {:ok, state}
  defp take(%{chip: nil}), do: {:error, :no_pwm}

  defp take(state) do
    with {:ok, brightness} <- kernel_brightness(state),
         {:ok, power} <- read_integer(state.backlight, "bl_power"),
         :ok <- write(state.driver, "unbind", state.device),
         :ok <- export(state) do
      {:ok,
       %{
         state
         | control: :user,
           period: @kernel_period,
           duty: luminance(brightness),
           on: power == 0
       }}
    end
  end

  defp export(state) do
    case write(state.chip, "export", state.channel) do
      {:error, :ebusy} -> :ok
      other -> other
    end
  end

  # Writes the PWM for a new state, answering with it or, on an error, the
  # old one.
  defp run(new, old) do
    duty_ns = if new.on, do: round(new.period * new.duty), else: 0

    # A shorter period cannot hold the duty cycle running: 0 in between.
    writes =
      if new.applied == new.period,
        do: [duty_cycle: duty_ns, enable: 1],
        else: [duty_cycle: 0, period: new.period, duty_cycle: duty_ns, enable: 1]

    case write_all(channel_dir(new), writes) do
      :ok -> {:reply, :ok, %{new | applied: new.period}}
      error -> {:reply, error, old}
    end
  end

  defp write_all(dir, writes) do
    Enum.reduce_while(writes, :ok, fn {file, value}, :ok ->
      case write(dir, Atom.to_string(file), value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp period(opts, state) do
    case {Keyword.get(opts, :frequency), Keyword.get(opts, :period)} do
      {nil, nil} -> {:ok, state.period || @kernel_period}
      {hz, nil} when is_number(hz) and hz > 0 -> check_period(round(1.0e9 / hz))
      {nil, ns} when is_integer(ns) -> check_period(ns)
      _ -> {:error, :invalid_period}
    end
  end

  defp check_period(ns) when ns in @min_period..@max_period, do: {:ok, ns}
  defp check_period(_ns), do: {:error, :invalid_period}

  defp duty(opts) do
    case Keyword.get(opts, :duty) do
      nil -> {:ok, nil}
      duty when is_number(duty) and duty >= 0 and duty <= 1 -> {:ok, duty / 1}
      _ -> {:error, :invalid_duty}
    end
  end

  defp kernel_brightness(state) do
    with {:ok, max} <- read_integer(state.backlight, "max_brightness"),
         {:ok, level} <- read_integer(state.backlight, "brightness") do
      if max > 0, do: {:ok, round(level * 100 / max)}, else: {:error, :no_levels}
    end
  end

  # CIE 1976 lightness (0 to 100) to the share of the light (0 to 1), and back.
  defp luminance(lightness) when lightness > 8, do: :math.pow((lightness + 16) / 116, 3)
  defp luminance(lightness), do: lightness / 903.3

  defp percent(share) when share > 0.008856,
    do: min(round(116 * :math.pow(share, 1 / 3) - 16), 100)

  defp percent(share), do: round(903.3 * share)

  defp channel_dir(state), do: Path.join(state.chip, "pwm#{state.channel}")

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

  defp pwm1?(chip) do
    case File.read_link(Path.join(chip, "device")) do
      {:ok, target} -> Path.basename(target) == @pwm_device
      {:error, _reason} -> false
    end
  end

  # The chip of PWM1, whatever number it got.
  defp find_chip do
    case File.ls(@pwm_classes) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(@pwm_classes, &1))
        |> Enum.find(&pwm1?/1)

      {:error, _reason} ->
        nil
    end
  end
end
