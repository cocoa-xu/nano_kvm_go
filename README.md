# NanoKVM

The hardware of the Sipeed NanoKVM-Go for Elixir, on its Nerves system
(`nerves_system_nano_kvm_go`):

* **Video** - capture of the HDMI/DisplayPort input (LT7911EXC bridge, up to
  3840x2160 at 30 fps), encoded by the hardware to H.264 for subscribers and
  to JPEG for an MJPEG stream
* **Audio** - the audio of that input, as 16-bit stereo PCM, at the rate the
  source sends
* **Two-way USB audio** - a microphone and a speaker for the target computer:
  sound for its microphone, and what it plays to the speaker
* **EDID** - the EDID the input presents to the source, to read or replace
* **Keyboard and mouse** - a boot keyboard and an absolute mouse for the
  target computer, over USB
* **Mass storage** - disk and CD-ROM images for the target computer, over USB
* **Temperature** - of the SoC, from its on-die sensor

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
  {NanoKVM.Audio, {:pcm, samples}} -> samples
end
```

Samples are interleaved signed 16-bit little endian stereo, at the rate in
the latest `{NanoKVM.Audio, {:format, format}}` message, and only come while
the source sends audio.

### USB microphone and speaker

With the `:microphone` and `:speaker` USB functions the target computer sees
a USB sound card (48 kHz; the microphone mono, the speaker stereo):

```elixir
children = [
  {NanoKVM.USB, functions: [:storage, :microphone, :speaker]},
  NanoKVM.Microphone,
  {NanoKVM.Audio, source: :usb, name: MyApp.Speaker}
]

# What the target hears from its microphone: 48 kHz mono S16_LE.
NanoKVM.Microphone.play(pcm)

# What the target plays to the speaker, as with the HDMI/DisplayPort audio.
:ok = NanoKVM.Audio.subscribe(MyApp.Speaker)
```

### Keyboard and mouse

```elixir
NanoKVM.HID.key("KeyA", :down)
NanoKVM.HID.key("KeyA", :up)
NanoKVM.HID.pointer(x: 0.5, y: 0.5, buttons: [:left])
NanoKVM.HID.release_all()
```

Keys are named like the browser's `KeyboardEvent.code`, so web clients can
pass them through.

### Mass storage

```elixir
NanoKVM.Storage.insert("/data/images/debian.iso")
NanoKVM.Storage.eject()
```

### Temperature

```elixir
NanoKVM.temperature()
#=> {:ok, 47.3}
```

## Changing USB functions

Adding or removing USB functions disconnects the NanoKVM from the target
computer for a moment, and with `:keyboard` and `:mouse` the target computer
takes input from it. Choose the functions once, at startup.

## License

Apache-2.0, see [LICENSE](LICENSE). `c_src/v4l2_h264_enc.h` is the proposed
V4L2 H.264 stateless encode uAPI under its own license.
