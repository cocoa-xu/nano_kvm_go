defmodule NanoKVM.Video.Devices do
  @moduledoc false
  # The video devices of the NanoKVM-Go, found by the names of their drivers.

  @video4linux "/sys/class/video4linux"

  @capture "ax620e-vin"
  @jpeg "axera,ax620e-jenc-enc"
  @h264 "axera,ax620e-venc-enc"

  @spec capture() :: String.t() | nil
  def capture, do: find(@capture)

  @spec jpeg() :: String.t() | nil
  def jpeg, do: find(@jpeg)

  @spec h264() :: String.t() | nil
  def h264, do: find(@h264)

  @doc "The sysfs directory of the device behind a device node."
  @spec sysfs_dir(String.t()) :: String.t()
  def sysfs_dir("/dev/" <> node), do: Path.join([@video4linux, node, "device"])

  @doc "The device node of the video device with that name, `nil` without one."
  @spec find(String.t(), Path.t()) :: String.t() | nil
  def find(name, root \\ @video4linux) do
    root
    |> Path.join("video*")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.find_value(fn dir ->
      if device_name(dir) == name, do: "/dev/" <> Path.basename(dir)
    end)
  end

  defp device_name(dir) do
    case File.read(Path.join(dir, "name")) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end
end
