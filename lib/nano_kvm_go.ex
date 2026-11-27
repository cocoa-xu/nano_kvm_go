defmodule NanoKVMGo do
  @moduledoc """
  The hardware of the Sipeed NanoKVM-Go for Elixir, on its Nerves system.

    * `NanoKVMGo.Video` - capture of the HDMI/DisplayPort input, with the
      hardware H.264 and JPEG encoders, and the EDID it presents, which
      `NanoKVMGo.EDID` decodes
    * `NanoKVMGo.Audio` - the audio of the HDMI/DisplayPort input, or of the
      USB speaker, as PCM
    * `NanoKVMGo.Microphone` - sound for the target's USB microphone
    * `NanoKVMGo.USB` - the board's USB gadget, for a gadget library such as
      `Kuroneko.Gadget`, which gives the target computer a keyboard, a
      mouse, mass storage, a microphone and a speaker
    * `NanoKVMGo.Display`, `NanoKVMGo.Backlight`, `NanoKVMGo.Touch`,
      `NanoKVMGo.Button` - the LCD, its touch panel and the BOOT button
    * `NanoKVMGo.Expansion` - the two lines of the auxiliary USB-C port
    * `NanoKVMGo.Bluetooth` - BlueZ for the controller in the Wi-Fi chip,
      and `NanoKVMGo.Bluetooth.HID`, the board as a Bluetooth LE HID device
    * `NanoKVMGo.Hardware` - the board, its parts and drivers, its storage
    * `NanoKVMGo.Metrics` - CPU, memory, temperature and network each second
    * `NanoKVMGo.CMA` - the memory pools of video and the NPU, for the next
      boots

  The processes take their options when started; add them to your
  supervision tree, the USB gadget first:

      children = [
        {Kuroneko.Gadget, NanoKVMGo.USB.gadget_options() ++ [functions: [:keyboard, :mouse]]},
        NanoKVMGo.Video,
        NanoKVMGo.Audio
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  The input's EDID, the backlight, the SoC temperature, the hardware and the
  memory pools need no process: `NanoKVMGo.Video.edid/1`,
  `NanoKVMGo.Backlight`, `temperature/0`, `NanoKVMGo.Hardware` and
  `NanoKVMGo.CMA`.
  """

  @doc """
  The temperature of the SoC in degrees Celsius, from its on-die sensor.

  The Nerves system shuts the device down at 120 °C.
  """
  @spec temperature() :: {:ok, float()} | {:error, term()}
  def temperature, do: NanoKVMGo.Thermal.temperature()
end
