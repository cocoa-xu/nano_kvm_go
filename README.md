# NanoKVM

The hardware of the Sipeed NanoKVM-Go for Elixir, on its Nerves system
(`nerves_system_nano_kvm_go`):

* **Video** - capture of the HDMI/DisplayPort input (LT7911EXC bridge, up to
  3840x2160 at 30 fps), encoded by the hardware to H.264 for subscribers and
  to JPEG for an MJPEG stream
* **Audio** - the audio of that input, as 16-bit stereo PCM, at the rate the
  source sends
* **Two-way USB audio** - a microphone and a speaker for the target computer:
  sound for its microphone, and what it plays to the speaker, each mono to
  7.1, 16 to 32 bits, at the rates the target chooses from, with its volume
* **EDID** - the EDID the input presents to the source, to read or replace
* **Keyboard and mouse** - a boot keyboard, an absolute pointer (a mouse, a
  pen or a ten-finger touch screen) and a relative boot mouse for the target
  computer, over USB, waking it from sleep
* **Mass storage** - disk and CD-ROM images for the target computer, over USB
* **USB network** - to and from the target computer, with MAC addresses that
  stay the same from boot to boot and that you can choose
* **LCD, touch panel, button** - pictures and text on the 240 × 284 display,
  its backlight, touches, and the BOOT button
* **Expansion lines** - the two lines of the auxiliary USB-C port, off until
  you make them a UART, GPIOs, PWM outputs or an I2C bus
* **Temperature** - of the SoC, from its on-die sensor
* **The device itself** - its board, parts and drivers, microSD card and
  partitions, and what it is doing each second: CPU, memory, temperature,
  network traffic, load; the USB connection to the target

It drives the open mainline drivers of the Nerves system through the standard
kernel interfaces (V4L2, ALSA, configfs USB gadgets), with no vendor
libraries.

## Installation

```elixir
def deps do
  [
    {:nano_kvm, "~> 0.1"}
  ]
end
```

The programs (`nano_kvm_video`, `nano_kvm_audio`, `nano_kvm_playback` and
`nano_kvm_edid`, C) are built for the target by the Nerves toolchain; the audio
ones link alsa-lib, which the NanoKVM-Go system has. On hosts other than Linux they are not built, so the
rest of the library still compiles and its tests run.

## Usage

The processes take their options when started. Add them to your supervision
tree, `NanoKVM.USB` first:

```elixir
children = [
  {NanoKVM.USB, functions: [:keyboard, :mouse, :storage]},
  {NanoKVM.Video, mjpeg_port: 8088},
  NanoKVM.Audio,
  NanoKVM.HID
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Video

```elixir
NanoKVM.Video.input()
#=> %{width: 1920, height: 1080, fps: 60}

:ok = NanoKVM.Video.subscribe()

receive do
  {NanoKVM.Video, {:h264, :key, access_unit}} -> access_unit
end
```

The MJPEG stream is at `http://<device>:8088/stream.mjpg`.

```elixir
{:ok, edid} = NanoKVM.Video.edid()
{:ok, %{name: "NanoKVM-Go", modes: [%{width: 3840, height: 2160, refresh: 30.0} | _]}} =
  NanoKVM.EDID.decode(edid)

:ok = NanoKVM.Video.set_edid(other_edid)
```

The bridge keeps the EDID in its flash; the source reads a new one when it
next connects.

### Audio

```elixir
:ok = NanoKVM.Audio.subscribe()

receive do
  {NanoKVM.Audio, :hdmi, {:pcm, samples}} -> samples
end
```

Samples are interleaved signed 16-bit little endian stereo, at the rate in
the latest `{NanoKVM.Audio, source, {:format, format}}` message, and only
come while the source sends audio. The source, `:hdmi` or `:usb`, tells the
two captures apart.

### USB microphone and speaker

With the `:microphone` and `:speaker` USB functions the target computer sees
a USB sound card, stereo, 16-bit and 48 kHz by default. Each direction takes
its channels, the rates the target can choose from (starting with the first)
and its sample size:

```elixir
children = [
  {NanoKVM.USB,
   functions: [
     :storage,
     {:microphone, channels: 1, rates: [48_000, 44_100]},
     {:speaker, channels: 6, rates: [48_000, 96_000], sample_bits: 24}
   ]},
  NanoKVM.Microphone,
  {NanoKVM.Audio, source: :usb, name: MyApp.Speaker}
]

# What the target hears from its microphone, in the format it takes now.
:ok = NanoKVM.Microphone.subscribe()
receive do: ({NanoKVM.Microphone, {:format, format}} -> format)
#=> %{rate: 48000, channels: 1, sample_format: :s16_le}
NanoKVM.Microphone.play(pcm)

# What the target plays to the speaker, as with the HDMI/DisplayPort audio.
:ok = NanoKVM.Audio.subscribe(MyApp.Speaker)
```

The target chooses the rate (a Mac in Audio MIDI Setup) and sets the volume;
both directions follow. `NanoKVM.USB.validate/1` tells whether the USB
controller can carry a format.

### Keyboard and mouse

```elixir
children = [{NanoKVM.USB, functions: [:keyboard, :mouse, :relative_mouse]}, NanoKVM.HID]

NanoKVM.HID.key("KeyA", :down)
NanoKVM.HID.key("KeyA", :up)
NanoKVM.HID.pointer(x: 0.5, y: 0.5, buttons: [:left])
NanoKVM.HID.relative(dx: 10, dy: -5, wheel: 1)
NanoKVM.HID.release_all()
```

Keys are named like the browser's `KeyboardEvent.code`, so web clients can
pass them through. `{:mouse, mode: :stylus}` or `{:mouse, mode: :touch}`
turns the absolute pointer into a pen or a touch screen, for Android and
iPadOS targets; `NanoKVM.HID.touch/2` sends up to ten touches. The relative
mouse is a boot mouse, for BIOS setups and games. Input wakes a target that
sleeps.

### Mass storage

```elixir
NanoKVM.Storage.insert("/data/images/debian.iso")
NanoKVM.Storage.eject()
```

### LCD and touch panel

```elixir
alias NanoKVM.Display.Canvas

children = [NanoKVM.Display, NanoKVM.Backlight, NanoKVM.Touch, NanoKVM.Button]

Canvas.new(240, 284, Canvas.rgb(0, 0, 0))
|> Canvas.rect(0, 0, 240, 40, Canvas.rgb(0, 80, 160))
|> Canvas.text(8, 4, "NanoKVM-Go", Canvas.rgb(255, 255, 255), scale: 2)
|> NanoKVM.Display.show()

# Brightness on a lightness curve; the PWM at 25 kHz or at a frequency of your own
NanoKVM.Backlight.set_brightness(60)
NanoKVM.Backlight.set_frequency(100_000)
NanoKVM.Backlight.set_frequency(:default)

:ok = NanoKVM.Touch.subscribe()
receive do: ({NanoKVM.Touch, {:down, x, y}} -> {x, y})

:ok = NanoKVM.Button.subscribe()
receive do: ({NanoKVM.Button, :down} -> :pressed)
```

The font is Spleen 8 × 16 by Frederic Cambus (BSD-2-Clause, notice in
`lib/nano_kvm/display/font.ex`).

### Temperature

```elixir
NanoKVM.temperature()
#=> {:ok, 47.3}
```

### The device itself

```elixir
NanoKVM.Hardware.info()
#=> %{model: "Sipeed NanoKVM-Go", soc: "Axera AX620QE", cpu: %{model: "Cortex-A53", cores: 2}, ...}

# Each part with its Linux device and driver: a missing device or driver shows what failed.
NanoKVM.Hardware.components()
#=> [%{id: :video_bridge, chip: "Lontium LT7911EXC", bus: :i2c, device: "0-0041", driver: "lt7911exc"}, ...]

# The microSD card, its partitions and how full they are.
NanoKVM.Hardware.storage()

# Samples each second, with the last five minutes, to whoever subscribes.
children = [NanoKVM.Metrics]
NanoKVM.Metrics.current()
#=> %{cpu: %{total: 12.5, cores: [10.0, 15.0]}, temperature: 71.3, network: %{"wlan0" => ...}, ...}
:ok = NanoKVM.Metrics.subscribe()

# Whether the target computer has set the USB device up, and at what speed.
NanoKVM.USB.connection()
#=> {:ok, %{state: :configured, speed: :high_speed, controller: "8000000.usb"}}
```

## The USB network

The target computer reaches the NanoKVM over USB too, through a network
adapter it sees. Its MAC address and the NanoKVM's stay the same from boot
to boot, so that the computer keeps one network interface for the NanoKVM:
by default they are made from the serial number.

```elixir
NanoKVM.USB.network()
#=> {:ok, %{interface: "usb0", device_address: "ea:52:ab:b6:67:a7", host_address: "2e:53:95:27:a5:9d", ...}}

# Now and at the next boots; :default goes back to the address made from the serial number.
:ok = NanoKVM.USB.set_network_addresses(host_address: "02:12:34:56:78:9a")
:ok = NanoKVM.USB.set_network_addresses(host_address: :default)
```

## The expansion lines

The auxiliary USB-C port, the one with the lightning icon, carries two of
the SoC's pads besides power; Sipeed's Finger Robot is a servo on them.
They are inputs pulled down until you choose what they are, and the choice
is kept for the next boots:

```elixir
NanoKVM.Expansion.info()
#=> {:ok, %{mode: :off, modes: [:off, :uart, :gpio, :pwm, :pwm_gpio, :gpio_pwm, :i2c], ...}}

# A servo on line 0 at 50 Hz, and line 1 as an input whose edges come as messages.
:ok = NanoKVM.Expansion.set_mode(:pwm_gpio)
:ok = NanoKVM.Expansion.set_pwm(0, 20_000_000, 1_500_000)
:ok = NanoKVM.Expansion.subscribe()
NanoKVM.Expansion.read(1)
#=> {:ok, 0}
```

In the `:uart` mode the lines are `"ttyS3"` for `Circuits.UART`, and in the
`:i2c` mode `"i2c-2"` for `Circuits.I2C`. Which USB-C contacts carry the
lines, and at what voltage (most likely 3.3 V), is not known yet: measure
before connecting anything but the Finger Robot.

## Changing USB functions

Adding or removing USB functions, or changing the network's addresses,
disconnects the NanoKVM from the target computer for a moment, and with
the keyboard and mice the target computer takes input from it. The
controller has seven endpoints for data to the computer: the network takes
two, and each function one; all of them fit together.

## License

Apache-2.0, see [LICENSE](LICENSE). `c_src/v4l2_h264_enc.h` is the proposed
V4L2 H.264 stateless encode uAPI under its own license.
