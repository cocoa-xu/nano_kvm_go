# Changelog

## Unreleased

* `NanoKVM.Video.edid/0` and `NanoKVM.Video.set_edid/1`: the EDID of the
  input, kept in the bridge's flash
* `NanoKVM.Audio` takes the sample rate from the bridge, through the video
  capture driver, and measures it only where the driver does not report it
* `NanoKVM.temperature/0`: the SoC temperature

## v0.1.0

First version, moved out of the NanoKVM-Go test application:

* `NanoKVM.Video`: capture with H.264 and MJPEG
* `NanoKVM.Audio`: HDMI/DisplayPort audio as PCM
* `NanoKVM.USB`: keyboard, mouse and mass storage functions on the gadget
  the Nerves system sets up
* `NanoKVM.HID`: keyboard and absolute mouse input
* `NanoKVM.Storage`: disk images as a removable drive or a CD-ROM
