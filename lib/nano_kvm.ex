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

  The processes take their options when started; add them to your
  supervision tree, `NanoKVM.USB` first:

      children = [
        {NanoKVM.USB, functions: [:keyboard, :mouse, :storage]},
        NanoKVM.Video,
        NanoKVM.Audio,
        NanoKVM.HID
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  The input's EDID and the SoC temperature need no process:
  `NanoKVM.Video.edid/0` and `temperature/0`.
  """

  @doc """
  The temperature of the SoC in degrees Celsius, from its on-die sensor.

  The Nerves system shuts the device down at 120 °C.
  """
  @spec temperature() :: {:ok, float()} | {:error, term()}
  def temperature, do: NanoKVM.Thermal.temperature()
end
