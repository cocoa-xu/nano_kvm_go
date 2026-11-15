# Changelog

## Unreleased

* Renamed from `nano_kvm` (`NanoKVM`) to `nano_kvm_go` (`NanoKVMGo`): the
  library is for the NanoKVM-Go boards. The port programs are
  `nano_kvm_go_video`, `nano_kvm_go_audio`, `nano_kvm_go_playback` and
  `nano_kvm_go_edid`
* `NanoKVMGo.Expansion`: the two lines of the auxiliary USB-C port as a
  UART, GPIOs, PWM outputs or an I2C bus, through the NanoKVM-Go system's
  `nanokvm-go-expansion` driver; the mode is kept in the U-Boot environment,
  GPIO edges come as messages. Needs `circuits_gpio`
* The USB network's MAC addresses: `NanoKVMGo.USB.network/1` tells them and
  those by default (`NanoKVMGo.USB.default_network_addresses/1`, from the
  serial number, as the NanoKVM-Go system gives them at boot);
  `NanoKVMGo.USB.set_network_addresses/2` changes them at once and keeps them
  in the U-Boot environment for the next boots;
  `NanoKVMGo.USB.validate_network_addresses/2` checks them
* `NanoKVMGo.Video.edid/0` and `NanoKVMGo.Video.set_edid/1`: the EDID of the
  input, kept in the bridge's flash; `NanoKVMGo.EDID.decode/1` for its name and
  modes
* `NanoKVMGo.Audio` takes the sample rate from the bridge, through the video
  capture driver, and measures it only where the driver does not report it
* `NanoKVMGo.temperature/0`: the SoC temperature
* Two-way USB audio: the `:microphone` and `:speaker` functions of
  `NanoKVMGo.USB` (one UAC2 function), `NanoKVMGo.Microphone` to play to the
  target's microphone, and `source: :usb` for `NanoKVMGo.Audio` to capture
  what the target plays to the speaker
* `NanoKVMGo.Audio` messages name their source: `{NanoKVMGo.Audio, :hdmi, ...}`
  or `{NanoKVMGo.Audio, :usb, ...}`
* USB audio formats: `{:microphone, options}` and `{:speaker, options}` take
  `:channels` (1 to 8), `:rates` (up to 10, the target choosing) and
  `:sample_bits` (16, 24, 32); the microphone is stereo by default, as the
  speaker. `NanoKVMGo.USB.audio/1` tells the formats, `NanoKVMGo.USB.validate/1`
  checks functions without setting them up
* `NanoKVMGo.Microphone` and the USB speaker follow the rate the target
  chooses and apply its volume and mute; formats name their samples
  (`:sample_format`), and `NanoKVMGo.Microphone.subscribe/1` tells the format
  to play in
* `:relative_mouse`, a boot mouse, with `NanoKVMGo.HID.relative/2`; the
  `:mouse` function in the `:stylus` and `:touch` modes, with
  `NanoKVMGo.HID.touch/2`; five buttons and a horizontal wheel on both mice
  (`NanoKVMGo.HID.Report.mouse/5`)
* The keyboard has the usages up to 0xDD: F13 to F24, the international and
  language keys, the editing keys
* Input wakes a target that sleeps
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
* `NanoKVMGo.USB.connection/1`: the state of the USB connection to the target
  and its speed

## v0.1.0

First version, moved out of the NanoKVM-Go test application:

* `NanoKVMGo.Video`: capture with H.264 and MJPEG
* `NanoKVMGo.Audio`: HDMI/DisplayPort audio as PCM
* `NanoKVMGo.USB`: keyboard, mouse and mass storage functions on the gadget
  the Nerves system sets up
* `NanoKVMGo.HID`: keyboard and absolute mouse input
* `NanoKVMGo.Storage`: disk images as a removable drive or a CD-ROM
