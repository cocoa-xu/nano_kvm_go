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

  The functions read and write the driver's attributes, with no process.

  ## Options

    * `:backlight` - the backlight's sysfs directory,
      `/sys/class/backlight/backlight` by default
  """

  alias NanoKVMGo.Options

  @type info() :: %{
          on: boolean(),
          brightness: 0..100,
          period: pos_integer() | nil,
          frequency: float() | nil,
          default_period: pos_integer() | nil
        }

  @type option() :: {:backlight, Path.t()}

  @doc """
  Turns the light on, at the brightness it had.
  """
  @spec on([option()]) :: :ok | {:error, File.posix()}
  def on(opts \\ []), do: write(backlight(opts), "bl_power", 0)

  @doc """
  Turns the light off, keeping its brightness for `on/1`.
  """
  @spec off([option()]) :: :ok | {:error, File.posix()}
  def off(opts \\ []), do: write(backlight(opts), "bl_power", 4)

  @doc """
  Sets the brightness in percent: 0 is dark, 100 the brightest, and each
  step looks as much brighter as the one before.
  """
  @spec set_brightness(0..100, [option()]) :: :ok | {:error, term()}
  def set_brightness(percent, opts \\ []) when percent in 0..100 do
    dir = backlight(opts)

    with {:ok, max} <- read_integer(dir, "max_brightness") do
      write(dir, "brightness", round(percent * max / 100))
    end
  end

  @doc """
  The brightness in percent, see `set_brightness/2`.
  """
  @spec brightness([option()]) :: {:ok, 0..100} | {:error, term()}
  def brightness(opts \\ []), do: read_brightness(backlight(opts))

  @doc """
  Runs the PWM at a frequency in Hz, up to 2 GHz, rounded to a period of
  whole nanoseconds, or at the device tree's with `:default`. The kernel
  refuses a period the timer cannot make with `{:error, :einval}`.
  """
  @spec set_frequency(number() | :default, [option()]) :: :ok | {:error, term()}
  def set_frequency(frequency, opts \\ [])

  def set_frequency(:default, opts) do
    dir = backlight(opts)

    case default_period(dir) do
      nil -> {:error, :no_default_period}
      period -> write(device(dir), "pwm_period_ns", period)
    end
  end

  def set_frequency(hz, opts) when is_number(hz) and hz > 0 and hz <= 2.0e9 do
    write(device(backlight(opts)), "pwm_period_ns", round(1.0e9 / hz))
  end

  @doc """
  Whether the light is on, its brightness, and the PWM's period in ns and
  frequency in Hz, now and by default; `nil` for what the kernel does not
  tell.
  """
  @spec info([option()]) :: {:ok, info()} | {:error, term()}
  def info(opts \\ []) do
    dir = backlight(opts)

    with {:ok, brightness} <- read_brightness(dir),
         {:ok, power} <- read_integer(dir, "bl_power") do
      {period, frequency} =
        case read_integer(device(dir), "pwm_period_ns") do
          {:ok, period} when period > 0 -> {period, 1.0e9 / period}
          _other -> {nil, nil}
        end

      {:ok,
       %{
         on: power == 0,
         brightness: brightness,
         period: period,
         frequency: frequency,
         default_period: default_period(dir)
       }}
    end
  end

  defp backlight(opts) do
    opts
    |> Options.validate!([backlight: "/sys/class/backlight/backlight"], &valid?/2)
    |> Keyword.fetch!(:backlight)
  end

  defp device(dir), do: Path.join(dir, "device")

  # The period in the device tree's `pwms = <&pwm channel period flags>`.
  defp default_period(dir) do
    case File.read(Path.join([device(dir), "of_node", "pwms"])) do
      {:ok, <<_pwm::32, _channel::32, period::32, _rest::binary>>} when period > 0 -> period
      _ -> nil
    end
  end

  defp read_brightness(dir) do
    with {:ok, max} <- read_integer(dir, "max_brightness"),
         {:ok, level} <- read_integer(dir, "brightness") do
      if max > 0, do: {:ok, round(level * 100 / max)}, else: {:error, :no_levels}
    end
  end

  defp write(dir, name, value), do: File.write(Path.join(dir, name), to_string(value))

  defp read_integer(dir, name) do
    with {:ok, text} <- File.read(Path.join(dir, name)) do
      case Integer.parse(String.trim(text)) do
        {value, _rest} -> {:ok, value}
        :error -> {:error, {:not_a_number, name}}
      end
    end
  end

  defp valid?(:backlight, backlight), do: is_binary(backlight)
end
