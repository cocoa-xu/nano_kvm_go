# Changelog

## Unreleased

* `NanoKVMGo.Video.snapshot/3`: a region of the next captured picture, or
  all of it, as RGB in the colours the streams declare, for reading the text
  in it and the like
* The encoding's `:color_matrix` and `:color_range` set the colour the HDMI
  bridge turns the picture into, where the capture can convert it (the
  system's bridge driver from linux-ax620e 4bd74a0 on), instead of only
  labelling the samples; `:auto` keeps the bridge's own, BT.709 at full
  range. `:bt601` shows the MJPEG stream's strongest colours right, as JPEG
  decoders assume BT.601. The H.264 and H.265 streams declare BT.709
  primaries whatever the matrix (BT.601 declared SMPTE 170M's)

## v0.3.0 (2026-11-27)

* H.265 from `NanoKVMGo.Video` as well as H.264: the encoding's `:codec`,
  `:auto` by default, takes H.265 while every subscriber decodes it.
  `subscribe/2` takes the codecs the caller decodes, `[:h264]` by default,
  and `codec/1` tells the stream's. A subscriber's messages are
  `{NanoKVMGo.Video, {codec, :key | :delta, data}}`; when the codec
  changes, the next access unit is a keyframe of the new one. The encoder
  device is `:encoder` in `:devices`, instead of `:h264`
* The stream declares its colour: BT.709 at full range, as the HDMI bridge
  hands the samples over, instead of nothing, which decoders took for
  limited range. The encoding's `:color_matrix` and `:color_range` label
  them otherwise
* `NanoKVMGo.Video` takes its `:encoding` from a `{module, function, args}`
  too, called each time the process starts: a restart by its supervisor
  takes the encoding saved last
* The NanoKVM-Go with 256 MiB: `NanoKVMGo.Video` holds three capture
  buffers with a video CMA pool under 176 MiB, as the Go's 128 MiB, and four
  otherwise (the `:capture_buffers` option); `NanoKVMGo.CMA` takes pools that
  leave Linux 96 MiB of the DRAM, as the system's U-Boot does, instead of
  half of it, and `:default` stands for the board's sizes, 128 MiB for video
  on the Go
* The encoders' output buffers hold a picture of one byte a pixel for JPEG
  and half a byte for H.264 and H.265, instead of the driver's two: at 4K,
  41 MB less of the video pool, which on the Go left the video encoder no
  room for its references. A bigger picture is dropped
* A `nano_kvm_go_video` that keeps exiting starts again after 2 s, then
  twice as long each time up to a minute, instead of every 2 s
* H.264 rate control in `NanoKVMGo.Video`: the `:encoding` option, and
  `set_encoding/2`, which changes it while the capture runs. A constant QP,
  a constant bitrate, or VBR: a QP, with a higher one where the bitrate
  would go over a cap; a keyframe interval, and a frame rate cap. VBR of up
  to 8 Mbit/s at QP 24 by default, instead of a constant QP of 30; the
  `:h264_qp` option is gone
* Needs Elixir 1.20, the version it is tested with
* `NanoKVMGo.Metrics` takes the clock it measures the traffic against,
  `:clock`
* `NanoKVMGo.Video` and `NanoKVMGo.Microphone` carry on when a keyframe
  request or samples come as their program exits, instead of crashing
* `NanoKVMGo.Display.show/2` keeps the framebuffer open after a picture of
  the wrong size, instead of opening it again for each
* `NanoKVMGo.Video` and `NanoKVMGo.Audio` send to subscribers on other
  nodes, instead of crashing on their first message
* `NanoKVMGo.Expansion` leaves a persisted mode the kernel does not offer,
  instead of writing the mode `nil`
* `NanoKVMGo.Expansion` gives its GPIOs and PWM channels back when its
  supervisor stops it, stopping the PWM outputs
* `NanoKVMGo.EDID.decode/1` skips a detailed timing without a size, instead
  of raising `ArithmeticError`
* `NanoKVMGo.Display.Canvas.text_width/2` counts code points, as
  `NanoKVMGo.Display.Canvas.text/6` draws them, not graphemes
* `NanoKVMGo.Touch` and `NanoKVMGo.Button` read their devices with a port
  program, `nano_kvm_go_input`, instead of a read that held one of the VM's
  dirty I/O schedulers each; `:program` names another
* Options are checked in the caller: an unknown option or a wrong value
  raises `ArgumentError`, instead of being left out or stopping the process
* `NanoKVMGo.Display` and `NanoKVMGo.Metrics` take `:root`, the root of the
  file system they read, as `NanoKVMGo.Hardware` and `NanoKVMGo.CMA` do;
  the port programs (`:program`), the video devices (`:devices`,
  `:video_device`), `NanoKVMGo.Expansion`'s GPIO library (`:gpio`) and
  `NanoKVMGo.Hardware.storage/1`'s `df` (`:df`) are documented options
* `NanoKVMGo.Backlight` is functions with no process, each with the
  `:backlight` option instead of a server: take it out of the supervision
  tree. `set_frequency/2` raises for a frequency without a period of whole
  nanoseconds, instead of returning `{:error, :invalid_frequency}`
* `NanoKVMGo.Expansion.set_mode/3` takes the server first, as the other
  functions do: `set_mode(mode)`, `set_mode(server, mode)` or
  `set_mode(server, mode, persist: false)`, no longer `set_mode(mode,
  persist: false)`. A mode that is none of the modes raises
  `FunctionClauseError`, instead of returning `{:error, {:unknown_mode,
  mode}}`, which now means one the kernel does not offer
* `NanoKVMGo.EDID.valid?/1` tells an EDID that `NanoKVMGo.Video.set_edid/2`
  takes; `set_edid/2` raises `ArgumentError` for another, instead of
  returning `{:error, :invalid_edid}`
* `NanoKVMGo.Video.edid/1` and `NanoKVMGo.Video.set_edid/2` take the
  `:device` and the `:program` as options, and tell a failure of the EDID
  program as `{:error, {:exit_status, status, output}}` instead of a string
* The input's type is `t:NanoKVMGo.Video.input/0`, instead of
  `t:NanoKVMGo.Video.Input.t/0`
* `NanoKVMGo.Audio`'s messages are `{NanoKVMGo.Audio, {:format, source,
  format}}` and `{NanoKVMGo.Audio, {:pcm, source, data}}`, a module and an
  event as the other processes send, instead of `{NanoKVMGo.Audio, source,
  event}`; each process that sends messages has their type, `message()`
* `NanoKVMGo.Video` tells a subscriber the input once it knows it, instead
  of `{NanoKVMGo.Video, {:input, nil}}`
* One verb for the U-Boot environment, as in `persist: false`:
  `NanoKVMGo.CMA.persist_sizes/2` and `NanoKVMGo.CMA.persisted_sizes/1`
  instead of `put_sizes/2` and `saved_sizes/1`, and
  `NanoKVMGo.USB.persist_network_addresses/2`, with the `:kv` option,
  instead of `keep_network_addresses/2` with the module as its second
  argument
* `NanoKVMGo.CMA.persist_sizes/2` takes a map, and raises `ArgumentError`
  for a pool other than `:video` and `:npu` or a size of another kind,
  instead of returning `{:error, {:unknown_pool, pool}}` or `{:error,
  {:invalid_size, pool, size}}`
* `nerves_runtime` is an optional dependency, and `Nerves.Runtime.KV` is
  called as it is: without it, `{:error, {:undefined, kv}}` and the
  fallbacks are gone, and `NanoKVMGo.Expansion` does not start
* `NanoKVMGo.Display.Canvas.text/6` and `NanoKVMGo.Display.Canvas.render/2`
  check their options: a `:scale` that is not a positive integer, a
  `:rotate` other than 0 and 180, or an unknown option raise
  `ArgumentError`
* `NanoKVMGo.Display` tells a framebuffer attribute it cannot read as
  `{:error, {:invalid_attribute, name, value}}`, instead of raising

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
