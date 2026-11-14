defmodule NanoKVM.Storage do
  @moduledoc """
  Disk images for the target computer, through the `:storage` function of
  `NanoKVM.USB`: a removable drive, or a CD-ROM drive, with an image file as
  its medium.

      NanoKVM.Storage.insert("/data/images/debian.iso")
      NanoKVM.Storage.medium()
      #=> {:ok, %{image: "/data/images/debian.iso", cdrom: true, read_only: true}}
      NanoKVM.Storage.eject()

  ISO images become CD-ROMs by default, other images drives. The target
  computer can write to an image that is not read-only. Keep images in
  `/data`, the writable partition of a Nerves device.

  The functions take a `:gadget` option, see `NanoKVM.USB`.
  """

  @typedoc "The image in the drive and how the target computer sees it."
  @type medium() :: %{image: Path.t(), cdrom: boolean(), read_only: boolean()}

  @type insert_option() :: {:cdrom, boolean()} | {:read_only, boolean()} | {:gadget, Path.t()}

  @doc """
  Puts an image in the drive, in place of the one there.

  ## Options

    * `:cdrom` - a CD-ROM drive instead of a removable disk; by default for
      images ending in `.iso`
    * `:read_only` - the target computer cannot write; by default for CD-ROMs
  """
  @spec insert(Path.t(), [insert_option()]) :: :ok | {:error, term()}
  def insert(image, opts \\ []) do
    image = Path.expand(image)
    cdrom = Keyword.get_lazy(opts, :cdrom, fn -> iso?(image) end)
    read_only = Keyword.get(opts, :read_only, cdrom)
    lun = lun(opts)

    with :ok <- check_lun(lun),
         :ok <- check_image(image),
         :ok <- remove_medium(lun),
         :ok <- write(lun, "cdrom", flag(cdrom)),
         :ok <- write(lun, "ro", flag(read_only)) do
      write(lun, "file", image)
    end
  end

  @doc """
  Takes the image out of the drive, even when the target computer holds it.
  """
  @spec eject([{:gadget, Path.t()}]) :: :ok | {:error, term()}
  def eject(opts \\ []) do
    lun = lun(opts)

    with :ok <- check_lun(lun), do: remove_medium(lun)
  end

  @doc """
  The image in the drive, `nil` when there is none.
  """
  @spec medium([{:gadget, Path.t()}]) :: {:ok, medium() | nil} | {:error, term()}
  def medium(opts \\ []) do
    lun = lun(opts)

    with :ok <- check_lun(lun),
         {:ok, image} <- read(lun, "file"),
         {:ok, cdrom} <- read(lun, "cdrom"),
         {:ok, read_only} <- read(lun, "ro") do
      if image == "",
        do: {:ok, nil},
        else: {:ok, %{image: image, cdrom: cdrom == "1", read_only: read_only == "1"}}
    end
  end

  # forced_eject works even when the host has locked the medium (SCSI
  # "prevent removal"), where writing an empty file name fails.
  defp remove_medium(lun) do
    with {:ok, image} when image != "" <- read(lun, "file"),
         :ok <- write(lun, "forced_eject", "1"),
         {:ok, image} when image != "" <- read(lun, "file") do
      write(lun, "file", "")
    else
      {:ok, ""} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lun(opts), do: Path.join(NanoKVM.USB.function_dir(:storage, opts), "lun.0")

  defp check_lun(lun) do
    if File.dir?(lun), do: :ok, else: {:error, :no_storage}
  end

  defp check_image(image) do
    if File.regular?(image), do: :ok, else: {:error, :enoent}
  end

  defp iso?(image), do: String.downcase(Path.extname(image)) == ".iso"

  defp flag(true), do: "1"
  defp flag(false), do: "0"

  defp read(lun, attribute) do
    with {:ok, value} <- File.read(Path.join(lun, attribute)), do: {:ok, String.trim(value)}
  end

  defp write(lun, attribute, value), do: File.write(Path.join(lun, attribute), value)
end
