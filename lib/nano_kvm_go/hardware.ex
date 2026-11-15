defmodule NanoKVMGo.Hardware do
  @moduledoc """
  The NanoKVM-Go as Linux sees it: the board, its SoC, memory and microSD
  card, and the parts on the board with the drivers that run them.

      NanoKVMGo.Hardware.info()
      #=> %{
      #=>   model: "Sipeed NanoKVM-Go",
      #=>   compatible: ["sipeed,nanokvm-go", "axera,ax620qe"],
      #=>   soc: "Axera AX620QE",
      #=>   cpu: %{model: "Cortex-A53", cores: 2},
      #=>   memory: 510_390_272,
      #=>   serial_number: "6a1a78455040f186",
      #=>   linux: "7.3.0"
      #=> }

      NanoKVMGo.Hardware.components()
      #=> [
      #=>   %{id: :video_bridge, name: "Video input bridge", chip: "Lontium LT7911EXC",
      #=>     bus: :i2c, device: "0-0041", driver: "lt7911exc"},
      #=>   ...
      #=> ]

  A part whose `device` is `nil` is missing: the kernel made no device of
  it, because its driver is not built or its device tree node is off. A
  part with a device but no `driver` has none bound: the driver failed to
  probe, or was unbound.

  `storage/1` tells the microSD card, its partitions and how full their file
  systems are.

  The functions read procfs and sysfs, with no process.
  """

  @typedoc """
  The board: its model and device tree compatibles, the SoC, the CPU cores,
  the memory Linux has in bytes, the SoC's serial number and the Linux
  release.
  """
  @type info() :: %{
          model: String.t() | nil,
          compatible: [String.t()],
          soc: String.t() | nil,
          cpu: %{model: String.t() | nil, cores: non_neg_integer()},
          memory: non_neg_integer() | nil,
          serial_number: String.t() | nil,
          linux: String.t() | nil
        }

  @typedoc """
  A part of the board: what it does, its chip, and the bus, device and
  driver Linux has for it.
  """
  @type component() :: %{
          id: component_id(),
          name: String.t(),
          chip: String.t() | nil,
          bus: :platform | :i2c | :spi | :sdio | :mmc | nil,
          device: String.t() | nil,
          driver: String.t() | nil
        }

  @type component_id() ::
          :video_bridge
          | :video_capture
          | :h264_encoder
          | :jpeg_encoder
          | :input_audio
          | :usb
          | :usb_phy
          | :lcd
          | :backlight
          | :touch
          | :button
          | :wifi
          | :sd_card
          | :temperature
          | :watchdog

  @typedoc """
  The microSD card: SD or MMC, its name and manufacturer, the month it was
  made (`"2022-12"`) and its size in bytes.
  """
  @type card() :: %{
          type: String.t() | nil,
          name: String.t() | nil,
          manufacturer: String.t() | nil,
          manufacturer_id: non_neg_integer() | nil,
          date: String.t() | nil,
          size: non_neg_integer()
        }

  @typedoc """
  A partition of the card, in bytes, with its part in the Nerves system:
  the boot files, the two root file systems firmware updates alternate
  between, and the application's data. A mounted partition has its file
  system's type and use; the root file system is read-only and full.
  """
  @type partition() :: %{
          number: pos_integer(),
          role: :boot | :rootfs_a | :rootfs_b | :data | nil,
          start: non_neg_integer(),
          size: non_neg_integer(),
          mount: Path.t() | nil,
          filesystem: filesystem() | nil
        }

  @type filesystem() :: %{
          type: String.t(),
          size: non_neg_integer() | nil,
          used: non_neg_integer() | nil,
          available: non_neg_integer() | nil
        }

  @type storage() :: %{card: card() | nil, partitions: [partition()]}

  @components [
    {:video_bridge, "Video input bridge", "Lontium LT7911EXC",
     {:compatible, "lontium,lt7911exc"}},
    {:video_capture, "Video capture", "AX620QE VIN", {:compatible, "axera,ax620e-vin"}},
    {:h264_encoder, "H.264 encoder", "AX620QE VENC", {:compatible, "axera,ax620e-venc"}},
    {:jpeg_encoder, "JPEG encoder", "AX620QE JENC", {:compatible, "axera,ax620e-jenc"}},
    {:input_audio, "Input audio", "AX620QE I2S", {:compatible, "simple-audio-card"}},
    {:usb, "USB controller", "Synopsys DWC3", {:compatible, "snps,dwc3"}},
    {:usb_phy, "USB PHY", "AX620QE USB 2.0 PHY", {:compatible, "axera,ax620e-usb2-phy"}},
    {:lcd, "LCD", "240 × 284 MIPI DBI panel", {:compatible, "sipeed,nanokvm-go-lcd"}},
    {:backlight, "LCD backlight", "PWM", {:compatible, "pwm-backlight"}},
    {:touch, "Touch panel", "Hynitron CST816S", {:compatible, "hynitron,cst816s"}},
    {:button, "BOOT button", "GPIO", {:compatible, "gpio-keys"}},
    {:wifi, "Wi-Fi", "AICSemi AIC8800D80", {:sdio, 0xC8A1, 0x0082}},
    {:sd_card, "microSD card", nil, :sd_card},
    {:temperature, "Temperature sensor", "AX620QE", {:compatible, "axera,ax620e-tsensor"}},
    {:watchdog, "Watchdog", "AX620QE", {:compatible, "axera,ax620e-wdt"}}
  ]

  @buses [:platform, :i2c, :spi, :sdio, :mmc]

  # The NanoKVM-Go system's partitions (its fwup.conf).
  @roles %{1 => :boot, 2 => :rootfs_a, 3 => :rootfs_b, 4 => :data}

  # The SD Association does not publish the IDs; these are the well known.
  @manufacturers %{
    0x01 => "Panasonic",
    0x02 => "Toshiba",
    0x03 => "SanDisk",
    0x1B => "Samsung",
    0x1D => "ADATA",
    0x27 => "Phison",
    0x28 => "Lexar",
    0x31 => "Silicon Power",
    0x41 => "Kingston",
    0x74 => "Transcend",
    0x76 => "Patriot",
    0x82 => "Sony"
  }

  # Arm's part numbers in /proc/cpuinfo.
  @arm_cores %{
    0xC07 => "Cortex-A7",
    0xC09 => "Cortex-A9",
    0xD03 => "Cortex-A53",
    0xD04 => "Cortex-A35",
    0xD05 => "Cortex-A55",
    0xD08 => "Cortex-A72"
  }

  @vendors %{"axera" => "Axera"}

  @doc """
  The board, its SoC, CPU and memory, and the Linux release.
  """
  @spec info(keyword()) :: info()
  def info(opts \\ []) do
    root = Keyword.get(opts, :root, "/")
    compatible = read_strings(root, "proc/device-tree/compatible")
    cpuinfo = read(root, "proc/cpuinfo") || ""

    %{
      model: root |> read_strings("proc/device-tree/model") |> List.first(),
      compatible: compatible,
      soc: compatible |> List.last() |> soc_name(),
      cpu: %{model: core_model(cpuinfo), cores: core_count(cpuinfo)},
      memory: memory(root),
      serial_number: cpuinfo_field(cpuinfo, "Serial"),
      linux: read(root, "proc/sys/kernel/osrelease")
    }
  end

  @doc """
  The parts of the board, each with its device and driver.
  """
  @spec components(keyword()) :: [component()]
  def components(opts \\ []) do
    root = Keyword.get(opts, :root, "/")
    devices = devices(root)

    for {id, name, chip, finder} <- @components do
      component = %{id: id, name: name, chip: chip, bus: nil, device: nil, driver: nil}

      case find(finder, devices) do
        nil -> component
        device -> describe(component, device)
      end
    end
  end

  @doc """
  The microSD card and its partitions, with the use of the mounted ones.
  """
  @spec storage(keyword()) :: storage()
  def storage(opts \\ []) do
    root = Keyword.get(opts, :root, "/")

    case card_disk(root) do
      nil ->
        %{card: nil, partitions: []}

      disk ->
        mounts = mounts(root)
        usage = usage(Keyword.get(opts, :df, "df"))
        %{card: card(disk), partitions: partitions(disk, mounts, usage)}
    end
  end

  # ---- The board

  defp soc_name(nil), do: nil

  defp soc_name(compatible) do
    case String.split(compatible, ",", parts: 2) do
      [vendor, chip] -> "#{Map.get(@vendors, vendor, vendor)} #{String.upcase(chip)}"
      [chip] -> String.upcase(chip)
    end
  end

  defp core_model(cpuinfo) do
    with "0x41" <- cpuinfo_field(cpuinfo, "CPU implementer"),
         "0x" <> hex <- cpuinfo_field(cpuinfo, "CPU part"),
         {part, ""} <- Integer.parse(hex, 16) do
      Map.get(@arm_cores, part)
    else
      _ -> nil
    end
  end

  defp core_count(cpuinfo) do
    cpuinfo |> String.split("\n") |> Enum.count(&String.match?(&1, ~r/^processor\s*:/))
  end

  # The first line with that field.
  defp cpuinfo_field(cpuinfo, field) do
    case Regex.run(~r/^#{Regex.escape(field)}\s*:[ \t]*(.*?)\s*$/m, cpuinfo) do
      [_line, value] -> value
      nil -> nil
    end
  end

  defp memory(root) do
    with text when is_binary(text) <- read(root, "proc/meminfo"),
         [_line, kilobytes] <- Regex.run(~r/^MemTotal:\s+(\d+) kB/m, text) do
      String.to_integer(kilobytes) * 1024
    else
      _ -> nil
    end
  end

  # ---- The parts

  # The devices on the buses parts sit on, with their device tree
  # compatibles.
  defp devices(root) do
    for bus <- @buses,
        dir <- root |> Path.join("sys/bus/#{bus}/devices/*") |> Path.wildcard() |> Enum.sort() do
      %{bus: bus, dir: dir, compatible: read_strings(dir, "of_node/compatible")}
    end
  end

  defp find({:compatible, compatible}, devices) do
    Enum.find(devices, &(compatible in &1.compatible))
  end

  defp find({:sdio, vendor, device}, devices) do
    Enum.find(devices, fn %{bus: bus, dir: dir} ->
      bus == :sdio and hex(dir, "vendor") == vendor and hex(dir, "device") == device
    end)
  end

  defp find(:sd_card, devices) do
    Enum.find(devices, fn %{bus: bus, dir: dir} ->
      bus == :mmc and read(dir, "type") in ["SD", "MMC"]
    end)
  end

  defp describe(component, device) do
    driver =
      case File.read_link(Path.join(device.dir, "driver")) do
        {:ok, link} -> Path.basename(link)
        {:error, _reason} -> nil
      end

    chip = if component.id == :sd_card, do: card_name(device.dir), else: component.chip
    %{component | bus: device.bus, device: Path.basename(device.dir), driver: driver, chip: chip}
  end

  defp hex(dir, file) do
    with "0x" <> digits <- read(dir, file),
         {value, ""} <- Integer.parse(digits, 16) do
      value
    else
      _ -> nil
    end
  end

  # ---- Storage

  # The block device of the SD or MMC card.
  defp card_disk(root) do
    root
    |> Path.join("sys/block/mmcblk*")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.find(&(read(&1, "device/type") in ["SD", "MMC"]))
  end

  defp card(disk) do
    device = Path.join(disk, "device")
    manufacturer_id = hex(device, "manfid")

    %{
      type: read(device, "type"),
      name: read(device, "name"),
      manufacturer: Map.get(@manufacturers, manufacturer_id),
      manufacturer_id: manufacturer_id,
      date: card_date(read(device, "date")),
      size: sectors(disk, "size")
    }
  end

  defp card_name(device) do
    name = read(device, "name")

    case Map.get(@manufacturers, hex(device, "manfid")) do
      nil -> name
      manufacturer -> Enum.join(Enum.reject([manufacturer, name], &is_nil/1), " ")
    end
  end

  # "12/2022" to "2022-12".
  defp card_date(nil), do: nil

  defp card_date(date) do
    case String.split(date, "/") do
      [month, year] -> "#{year}-#{String.pad_leading(month, 2, "0")}"
      _ -> date
    end
  end

  defp partitions(disk, mounts, usage) do
    name = Path.basename(disk)

    partitions =
      for dir <- disk |> Path.join(name <> "p*") |> Path.wildcard(),
          {number, ""} <- [
            Integer.parse(String.replace_prefix(Path.basename(dir), name <> "p", ""))
          ] do
        mount = Map.get(mounts, read(dir, "dev"))

        %{
          number: number,
          role: Map.get(@roles, number),
          start: sectors(dir, "start"),
          size: sectors(dir, "size"),
          mount: mount && mount.path,
          filesystem: mount && filesystem(mount, usage)
        }
      end

    Enum.sort_by(partitions, & &1.number)
  end

  defp filesystem(mount, usage) do
    Map.merge(
      %{type: mount.type, size: nil, used: nil, available: nil},
      Map.get(usage, mount.path, %{})
    )
  end

  defp sectors(dir, file) do
    case Integer.parse(read(dir, file) || "") do
      {count, ""} -> count * 512
      _ -> 0
    end
  end

  # The mounts by device number ("179:4"): where, and the file system type.
  defp mounts(root) do
    for line <- String.split(read(root, "proc/self/mountinfo") || "", "\n"),
        [left, right] <- [String.split(line, " - ", parts: 2)],
        [_id, _parent, device, _root, path | _options] <- [String.split(left)],
        [type | _source] <- [String.split(right)],
        into: %{},
        do: {device, %{path: unescape(path), type: type}}
  end

  # Mount points have spaces and the like as octal escapes.
  defp unescape(path) do
    Regex.replace(~r/\\([0-7]{3})/, path, fn _, octal -> <<String.to_integer(octal, 8)>> end)
  end

  # The size, use and space left of each mounted file system, in bytes, from
  # df(1): Erlang has no statfs.
  defp usage(df) do
    with path when is_binary(path) <- System.find_executable(df),
         {text, 0} <- System.cmd(path, ["-kP"], stderr_to_stdout: true) do
      for line <- text |> String.split("\n") |> Enum.drop(1),
          [_source, size, used, available, _percent, mount] <- [String.split(line)],
          [{size, ""}, {used, ""}, {available, ""}] <-
            [Enum.map([size, used, available], &Integer.parse/1)],
          into: %{},
          do: {mount, %{size: size * 1024, used: used * 1024, available: available * 1024}}
    else
      _ -> %{}
    end
  end

  # ---- Files

  defp read(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} -> String.trim(text)
      {:error, _reason} -> nil
    end
  end

  # A device tree property of NUL-terminated strings.
  defp read_strings(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} -> String.split(text, <<0>>, trim: true)
      {:error, _reason} -> []
    end
  end
end
