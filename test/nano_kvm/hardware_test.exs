defmodule NanoKVM.HardwareTest do
  use ExUnit.Case, async: true

  alias NanoKVM.Hardware

  @moduletag :tmp_dir

  defp write(dir, file, contents) do
    path = Path.join(dir, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  # A device on a bus, with its device tree compatibles and its driver.
  defp device(root, bus, name, opts) do
    dir = Path.join(root, "sys/bus/#{bus}/devices/#{name}")
    File.mkdir_p!(dir)

    if compatible = opts[:compatible],
      do: write(dir, "of_node/compatible", Enum.map_join(List.wrap(compatible), &(&1 <> <<0>>)))

    if driver = opts[:driver] do
      drivers = Path.join(root, "sys/bus/#{bus}/drivers/#{driver}")
      File.mkdir_p!(drivers)
      File.ln_s!(drivers, Path.join(dir, "driver"))
    end

    for {file, contents} <- Keyword.get(opts, :files, []),
        do: write(dir, to_string(file), contents)

    dir
  end

  @card [type: "SD\n", name: "SN128\n", manfid: "0x000003\n", date: "12/2022\n"]

  test "the board, its SoC, CPU and memory", %{tmp_dir: root} do
    write(root, "proc/device-tree/model", "Sipeed NanoKVM-Go\0")
    write(root, "proc/device-tree/compatible", "sipeed,nanokvm-go\0axera,ax620qe\0")

    core = """
    model name\t: ARMv7 Processor rev 4 (v7l)
    CPU implementer\t: 0x41
    CPU part\t: 0xd03
    """

    write(root, "proc/cpuinfo", """
    processor\t: 0
    #{core}
    processor\t: 1
    #{core}
    Hardware\t: Generic DT based system
    Serial\t\t: 6a1a78455040f186
    """)

    write(root, "proc/meminfo", "MemTotal:         498428 kB\nMemFree:          217612 kB\n")
    write(root, "proc/sys/kernel/osrelease", "7.3.0\n")

    assert Hardware.info(root: root) == %{
             model: "Sipeed NanoKVM-Go",
             compatible: ["sipeed,nanokvm-go", "axera,ax620qe"],
             soc: "Axera AX620QE",
             cpu: %{model: "Cortex-A53", cores: 2},
             memory: 510_390_272,
             serial_number: "6a1a78455040f186",
             linux: "7.3.0"
           }
  end

  test "without procfs, what is known", %{tmp_dir: root} do
    assert Hardware.info(root: root) == %{
             model: nil,
             compatible: [],
             soc: nil,
             cpu: %{model: nil, cores: 0},
             memory: nil,
             serial_number: nil,
             linux: nil
           }
  end

  test "parts with their devices and drivers, missing or unbound ones too", %{tmp_dir: root} do
    device(root, :i2c, "0-0041", compatible: "lontium,lt7911exc", driver: "lt7911exc")
    # Probing failed: a device without a driver.
    device(root, :i2c, "1-0015", compatible: "hynitron,cst816s")

    device(root, :spi, "spi0.0",
      compatible: ["sipeed,nanokvm-go-lcd", "panel-mipi-dbi-spi"],
      driver: "panel-mipi-dbi-spi"
    )

    device(root, :platform, "8000000.usb", compatible: "snps,dwc3", driver: "dwc3")

    device(root, :sdio, "mmc1:390b:1",
      driver: "aicwf_sdio",
      files: [vendor: "0xc8a1\n", device: "0x0082\n"]
    )

    device(root, :sdio, "mmc1:390b:2", files: [vendor: "0xc8a1\n", device: "0x0182\n"])
    device(root, :mmc, "mmc1:390b", files: [type: "SDIO\n"])
    device(root, :mmc, "mmc0:aaaa", driver: "mmcblk", files: @card)

    components = Map.new(Hardware.components(root: root), &{&1.id, &1})

    assert components.video_bridge == %{
             id: :video_bridge,
             name: "Video input bridge",
             chip: "Lontium LT7911EXC",
             bus: :i2c,
             device: "0-0041",
             driver: "lt7911exc"
           }

    assert %{bus: :i2c, device: "1-0015", driver: nil} = components.touch
    assert %{bus: :spi, device: "spi0.0", driver: "panel-mipi-dbi-spi"} = components.lcd
    assert %{bus: :platform, device: "8000000.usb", driver: "dwc3"} = components.usb
    assert %{bus: :sdio, device: "mmc1:390b:1", driver: "aicwf_sdio"} = components.wifi

    assert %{bus: :mmc, device: "mmc0:aaaa", driver: "mmcblk", chip: "SanDisk SN128"} =
             components.sd_card

    assert %{bus: nil, device: nil, driver: nil, chip: "Lontium LT7911EXC"} =
             Hardware.components(root: Path.join(root, "none")) |> hd()

    assert %{device: nil, driver: nil} = components.h264_encoder

    assert Enum.map(Hardware.components(root: root), & &1.id) == [
             :video_bridge,
             :video_capture,
             :h264_encoder,
             :jpeg_encoder,
             :input_audio,
             :usb,
             :usb_phy,
             :lcd,
             :backlight,
             :touch,
             :button,
             :wifi,
             :sd_card,
             :temperature,
             :watchdog
           ]
  end

  test "the card, its partitions and the use of the mounted ones", %{tmp_dir: root} do
    disk = Path.join(root, "sys/block/mmcblk0")
    write(disk, "size", "249737216\n")
    for {file, value} <- @card, do: write(disk, "device/#{file}", value)

    for {n, start, size} <- [{1, 8192, 262_144}, {2, 401_408, 524_288}, {4, 1_449_984, 1_048_576}] do
      write(disk, "mmcblk0p#{n}/start", "#{start}\n")
      write(disk, "mmcblk0p#{n}/size", "#{size}\n")
      write(disk, "mmcblk0p#{n}/dev", "179:#{n}\n")
    end

    # Not a card: left out.
    write(root, "sys/block/mmcblk1/device/type", "SDIO\n")

    write(root, "proc/self/mountinfo", """
    22 1 179:2 / / ro,relatime shared:1 - squashfs /dev/root ro,errors=continue
    23 22 0:5 / /dev rw,nosuid,noexec,relatime shared:2 - devtmpfs devtmpfs rw,size=1024k
    30 22 179:4 / /root rw,lazytime,nodev,relatime shared:9 - f2fs /dev/mmcblk0p4 rw,discard
    """)

    df = Path.join(root, "df")

    File.write!(df, """
    #!/bin/sh
    [ "$1" = "-kP" ] || exit 1
    echo 'Filesystem           1024-blocks    Used Available Capacity Mounted on'
    echo '/dev/root                25600     25600         0 100% /'
    echo 'devtmpfs                  1024         0      1024   0% /dev'
    echo '/dev/mmcblk0p4          522240     65624    456616  13% /root'
    """)

    File.chmod!(df, 0o755)

    assert Hardware.storage(root: root, df: df) == %{
             card: %{
               type: "SD",
               name: "SN128",
               manufacturer: "SanDisk",
               manufacturer_id: 3,
               date: "2022-12",
               size: 127_865_454_592
             },
             partitions: [
               %{
                 number: 1,
                 role: :boot,
                 start: 4_194_304,
                 size: 134_217_728,
                 mount: nil,
                 filesystem: nil
               },
               %{
                 number: 2,
                 role: :rootfs_a,
                 start: 205_520_896,
                 size: 268_435_456,
                 mount: "/",
                 filesystem: %{type: "squashfs", size: 26_214_400, used: 26_214_400, available: 0}
               },
               %{
                 number: 4,
                 role: :data,
                 start: 742_391_808,
                 size: 536_870_912,
                 mount: "/root",
                 filesystem: %{
                   type: "f2fs",
                   size: 534_773_760,
                   used: 67_198_976,
                   available: 467_574_784
                 }
               }
             ]
           }

    # Without df, the file systems without their use.
    assert %{partitions: [_boot, %{filesystem: %{type: "squashfs", used: nil}} | _]} =
             Hardware.storage(root: root, df: Path.join(root, "no-df"))

    assert Hardware.storage(root: Path.join(root, "none")) == %{card: nil, partitions: []}
  end
end
