defmodule NanoKVMGo do
  @moduledoc """
  The hardware of the Sipeed NanoKVM-Go for Elixir, on its Nerves system.

    * `NanoKVMGo.Video` - capture of the HDMI/DisplayPort input, with the
      hardware H.264 and JPEG encoders
    * `NanoKVMGo.Audio` - the audio of the HDMI/DisplayPort input, or of the
      USB speaker, as PCM
    * `NanoKVMGo.Microphone` - sound for the target's USB microphone
    * `NanoKVMGo.USB` - the USB functions the target computer sees: keyboard,
      mouse, mass storage, microphone and speaker
    * `NanoKVMGo.HID` - keyboard and mouse input for the target computer
    * `NanoKVMGo.Storage` - disk images in the mass storage drive
    * `NanoKVMGo.Display`, `NanoKVMGo.Backlight`, `NanoKVMGo.Touch`,
      `NanoKVMGo.Button` - the LCD, its touch panel and the BOOT button
    * `NanoKVMGo.Hardware` - the board, its parts and drivers, its storage
    * `NanoKVMGo.Metrics` - CPU, memory, temperature and network each second

  The processes take their options when started; add them to your
  supervision tree, `NanoKVMGo.USB` first:

      children = [
        {NanoKVMGo.USB, functions: [:keyboard, :mouse, :storage]},
        NanoKVMGo.Video,
        NanoKVMGo.Audio,
        NanoKVMGo.HID
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  The input's EDID, the SoC temperature and the hardware need no process:
  `NanoKVMGo.Video.edid/0`, `temperature/0` and `NanoKVMGo.Hardware`.
  """

  @doc """
  The temperature of the SoC in degrees Celsius, from its on-die sensor.

  The Nerves system shuts the device down at 120 °C.
  """
  @spec temperature() :: {:ok, float()} | {:error, term()}
  def temperature, do: NanoKVMGo.Thermal.temperature()
end
