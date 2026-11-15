defmodule NanoKVM do
  @moduledoc """
  The hardware of the Sipeed NanoKVM-Go for Elixir, on its Nerves system.

    * `NanoKVM.Video` - capture of the HDMI/DisplayPort input, with the
      hardware H.264 and JPEG encoders
    * `NanoKVM.Audio` - the audio of the HDMI/DisplayPort input, or of the
      USB speaker, as PCM
    * `NanoKVM.Microphone` - sound for the target's USB microphone
    * `NanoKVM.USB` - the USB functions the target computer sees: keyboard,
      mouse, mass storage, microphone and speaker
    * `NanoKVM.HID` - keyboard and mouse input for the target computer
    * `NanoKVM.Storage` - disk images in the mass storage drive
    * `NanoKVM.Display`, `NanoKVM.Backlight`, `NanoKVM.Touch`,
      `NanoKVM.Button` - the LCD, its touch panel and the BOOT button
    * `NanoKVM.Hardware` - the board, its parts and drivers, its storage
    * `NanoKVM.Metrics` - CPU, memory, temperature and network each second

  The processes take their options when started; add them to your
  supervision tree, `NanoKVM.USB` first:

      children = [
        {NanoKVM.USB, functions: [:keyboard, :mouse, :storage]},
        NanoKVM.Video,
        NanoKVM.Audio,
        NanoKVM.HID
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  The input's EDID, the SoC temperature and the hardware need no process:
  `NanoKVM.Video.edid/0`, `temperature/0` and `NanoKVM.Hardware`.
  """

  @doc """
  The temperature of the SoC in degrees Celsius, from its on-die sensor.

  The Nerves system shuts the device down at 120 °C.
  """
  @spec temperature() :: {:ok, float()} | {:error, term()}
  def temperature, do: NanoKVM.Thermal.temperature()
end
