# NanoKVM

The hardware of the Sipeed NanoKVM-Go for Elixir, on its Nerves system
(`nerves_system_nano_kvm_go`):

* **Video** - capture of the HDMI/DisplayPort input (LT7911EXC bridge, up to
  3840x2160 at 30 fps), encoded by the hardware to H.264 for subscribers and
  to JPEG for an MJPEG stream
* **Keyboard and mouse** - a boot keyboard and an absolute mouse for the
  target computer, over USB
* **Mass storage** - disk and CD-ROM images for the target computer, over USB

It drives the open mainline drivers of the Nerves system through the standard
kernel interfaces (V4L2, configfs USB gadgets), with no vendor libraries.

## Installation

```elixir
def deps do
  [
    {:nano_kvm, "~> 0.1"}
  ]
end
```

The video port program (`nano_kvm_video`, C) is built for the target by the
Nerves toolchain. On hosts other than Linux it is not built, so the rest of
the library still compiles and its tests run.

## Usage

The processes take their options when started. Add them to your supervision
tree, `NanoKVM.USB` first:

```elixir
children = [
  {NanoKVM.USB, functions: [:keyboard, :mouse, :storage]},
  {NanoKVM.Video, mjpeg_port: 8088},
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

## Changing USB functions

Adding or removing USB functions disconnects the NanoKVM from the target
computer for a moment, and with `:keyboard` and `:mouse` the target computer
takes input from it. Choose the functions once, at startup.

## License

Apache-2.0, see [LICENSE](LICENSE). `c_src/v4l2_h264_enc.h` is the proposed
V4L2 H.264 stateless encode uAPI under its own license.
