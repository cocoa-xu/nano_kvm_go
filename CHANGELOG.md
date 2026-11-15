# Changelog

## Unreleased

* The USB network's MAC addresses: `NanoKVM.USB.network/1` tells them and
  those by default (`NanoKVM.USB.default_network_addresses/1`, from the
  serial number, as the NanoKVM-Go system gives them at boot);
  `NanoKVM.USB.set_network_addresses/2` changes them at once and keeps them
  in the U-Boot environment for the next boots;
  `NanoKVM.USB.validate_network_addresses/2` checks them
* `NanoKVM.Video.edid/0` and `NanoKVM.Video.set_edid/1`: the EDID of the
  input, kept in the bridge's flash; `NanoKVM.EDID.decode/1` for its name and
  modes
* `NanoKVM.Audio` takes the sample rate from the bridge, through the video
  capture driver, and measures it only where the driver does not report it
* `NanoKVM.temperature/0`: the SoC temperature
* Two-way USB audio: the `:microphone` and `:speaker` functions of
  `NanoKVM.USB` (one UAC2 function), `NanoKVM.Microphone` to play to the
  target's microphone, and `source: :usb` for `NanoKVM.Audio` to capture
  what the target plays to the speaker
* `NanoKVM.Audio` messages name their source: `{NanoKVM.Audio, :hdmi, ...}`
  or `{NanoKVM.Audio, :usb, ...}`
* USB audio formats: `{:microphone, options}` and `{:speaker, options}` take
  `:channels` (1 to 8), `:rates` (up to 10, the target choosing) and
  `:sample_bits` (16, 24, 32); the microphone is stereo by default, as the
  speaker. `NanoKVM.USB.audio/1` tells the formats, `NanoKVM.USB.validate/1`
  checks functions without setting them up
* `NanoKVM.Microphone` and the USB speaker follow the rate the target
  chooses and apply its volume and mute; formats name their samples
  (`:sample_format`), and `NanoKVM.Microphone.subscribe/1` tells the format
  to play in
* `:relative_mouse`, a boot mouse, with `NanoKVM.HID.relative/2`; the
  `:mouse` function in the `:stylus` and `:touch` modes, with
  `NanoKVM.HID.touch/2`; five buttons and a horizontal wheel on both mice
  (`NanoKVM.HID.Report.mouse/5`)
* The keyboard has the usages up to 0xDD: F13 to F24, the international and
  language keys, the editing keys
* Input wakes a target that sleeps
* `NanoKVM.Display` and `NanoKVM.Display.Canvas`: pictures and text on the
  LCD, writing only the rows that change and carrying on when the panel's
  driver loads late or probes again; `NanoKVM.Touch`: its touch panel;
  `NanoKVM.Button`: the BOOT button
* `NanoKVM.Backlight`: the LCD's brightness on a lightness curve, and the
  frequency of the PWM that dims it, 25 kHz by default
* `NanoKVM.Hardware`: the board, its SoC, CPU and memory, its parts with
  the Linux device and driver of each, and the microSD card with its
  partitions and their use
* `NanoKVM.Metrics`: CPU, memory, temperature, network traffic, load and
  uptime each second, with five minutes of history, for subscribers
* `NanoKVM.USB.connection/1`: the state of the USB connection to the target
  and its speed

## v0.1.0

First version, moved out of the NanoKVM-Go test application:

* `NanoKVM.Video`: capture with H.264 and MJPEG
* `NanoKVM.Audio`: HDMI/DisplayPort audio as PCM
* `NanoKVM.USB`: keyboard, mouse and mass storage functions on the gadget
  the Nerves system sets up
* `NanoKVM.HID`: keyboard and absolute mouse input
* `NanoKVM.Storage`: disk images as a removable drive or a CD-ROM
