# Changelog

## Unreleased

* `NanoKVMGo.Video` and `NanoKVMGo.Microphone` carry on when a keyframe
  request or samples come as their program exits, instead of crashing
* `NanoKVMGo.Display.show/2` keeps the framebuffer open after a picture of
  the wrong size, instead of opening it again for each
* `NanoKVMGo.Video` and `NanoKVMGo.Audio` send to subscribers on other
  nodes, instead of crashing on their first message
* `NanoKVMGo.Expansion` leaves a kept mode the kernel does not offer,
  instead of writing the mode `nil`
* `NanoKVMGo.Expansion` gives its GPIOs and PWM channels back when its
  supervisor stops it, stopping the PWM outputs
* `NanoKVMGo.EDID.decode/1` skips a detailed timing without a size, instead
  of raising `ArithmeticError`
* `NanoKVMGo.Display.Canvas.text_width/2` counts code points, as
  `NanoKVMGo.Display.Canvas.text/6` draws them, not graphemes

## v0.2.1 (2026-11-23)

* `NanoKVMGo.USB.gadget_options/1` gives the device controller's endpoints,
  seven IN and seven OUT, for `Kuroneko.Gadget` to count functions against

## v0.2.0 (2026-11-21)

* Renamed from `nano_kvm` (`NanoKVM`) to `nano_kvm_go` (`NanoKVMGo`): the
  library is for the NanoKVM-Go boards. The port programs are
  `nano_kvm_go_video`, `nano_kvm_go_audio`, `nano_kvm_go_playback` and
  `nano_kvm_go_edid`
* The USB gadget's functions, the keyboard and mouse input and the mass
  storage moved to `kuroneko_gadget` (`Kuroneko.Gadget`,
  `Kuroneko.Gadget.HID`, `Kuroneko.Gadget.Storage`). `NanoKVMGo.USB` gives
  it the board's settings (`NanoKVMGo.USB.gadget_options/1`), with the
  network addresses made from the serial number and kept in the U-Boot
  environment (`NanoKVMGo.USB.keep_network_addresses/2`)
* `NanoKVMGo.Expansion`: the two lines of the auxiliary USB-C port as a
  UART, GPIOs, PWM outputs or an I2C bus, through the NanoKVM-Go system's
  `nanokvm-go-expansion` driver; the mode is kept in the U-Boot environment,
  GPIO edges come as messages. Needs `circuits_gpio`
* `NanoKVMGo.Video.edid/0` and `NanoKVMGo.Video.set_edid/1`: the EDID of
  the input, kept in the bridge's flash; `NanoKVMGo.EDID.decode/1` for its
  name and modes
* `NanoKVMGo.Audio` takes the sample rate from the bridge, through the video
  capture driver, and measures it only where the driver does not report it
* `NanoKVMGo.temperature/0`: the SoC temperature
* Two-way USB audio, with the `:microphone` and `:speaker` functions of the
  USB gadget: `NanoKVMGo.Microphone` to play to the target's microphone, and
  `source: :usb` for `NanoKVMGo.Audio` to capture what the target plays to
  the speaker
* `NanoKVMGo.Audio` messages name their source: `{NanoKVMGo.Audio, :hdmi,
  ...}` or `{NanoKVMGo.Audio, :usb, ...}`
* `NanoKVMGo.Microphone` and the USB speaker follow the rate the target
  chooses and apply its volume and mute; formats name their samples
  (`:sample_format`), and `NanoKVMGo.Microphone.subscribe/1` tells the format
  to play in
* `NanoKVMGo.Display` and `NanoKVMGo.Display.Canvas`: pictures and text on the
  LCD, writing only the rows that change and carrying on when the panel's
  driver loads late or probes again; `NanoKVMGo.Touch`: its touch panel;
  `NanoKVMGo.Button`: the BOOT button
* `NanoKVMGo.Backlight`: the LCD's brightness on a lightness curve, and the
  frequency of the PWM that dims it, 25 kHz by default
* `NanoKVMGo.Hardware`: the board, its SoC, CPU and memory, its parts with
  the Linux device and driver of each, and the microSD card with its
  partitions and their use
* `NanoKVMGo.Metrics`: CPU, memory, temperature, network traffic, load and
  uptime each second, with five minutes of history, for subscribers
* `NanoKVMGo.CMA`: the sizes of the contiguous memory pools of video and the
  NPU, kept in the U-Boot environment for the next boots, and an opt-in
  trial that the boots after it revert unless the firmware is validated

## v0.1.0

First version, as `nano_kvm`, moved out of the NanoKVM-Go test application:

* `NanoKVM.Video`: capture with H.264 and MJPEG
* `NanoKVM.Audio`: HDMI/DisplayPort audio as PCM
* `NanoKVM.USB`: keyboard, mouse and mass storage functions on the gadget
  the Nerves system sets up
* `NanoKVM.HID`: keyboard and absolute mouse input
* `NanoKVM.Storage`: disk images as a removable drive or a CD-ROM
