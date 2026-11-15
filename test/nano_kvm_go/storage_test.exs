defmodule NanoKVMGo.StorageTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    gadget = Path.join(tmp_dir, "gadget")
    lun = Path.join(gadget, "functions/mass_storage.disk/lun.0")
    File.mkdir_p!(lun)
    for attribute <- ["file", "cdrom", "ro"], do: File.write!(Path.join(lun, attribute), "")

    iso = Path.join(tmp_dir, "install.ISO")
    disk = Path.join(tmp_dir, "disk.img")
    File.write!(iso, "")
    File.write!(disk, "")

    %{gadget: gadget, lun: lun, iso: iso, disk: disk}
  end

  test "an ISO image is a read-only CD-ROM", %{gadget: gadget, iso: iso} do
    assert :ok = Storage.insert(iso, gadget: gadget)
    assert Storage.medium(gadget: gadget) == {:ok, %{image: iso, cdrom: true, read_only: true}}
  end

  test "another image is a writable disk unless asked", %{gadget: gadget, disk: disk} do
    assert :ok = Storage.insert(disk, gadget: gadget)
    assert Storage.medium(gadget: gadget) == {:ok, %{image: disk, cdrom: false, read_only: false}}

    assert :ok = Storage.insert(disk, gadget: gadget, read_only: true)
    assert {:ok, %{read_only: true}} = Storage.medium(gadget: gadget)
  end

  test "ejecting forces the medium out", %{gadget: gadget, lun: lun, disk: disk} do
    assert :ok = Storage.insert(disk, gadget: gadget)
    assert :ok = Storage.eject(gadget: gadget)
    assert File.read!(Path.join(lun, "forced_eject")) == "1"
    assert Storage.medium(gadget: gadget) == {:ok, nil}
    assert :ok = Storage.eject(gadget: gadget)
  end

  test "errors without an image or a storage function", %{gadget: gadget, tmp_dir: tmp_dir} do
    assert Storage.insert(Path.join(tmp_dir, "missing.img"), gadget: gadget) == {:error, :enoent}

    assert Storage.insert(Path.join(tmp_dir, "disk.img"), gadget: tmp_dir) ==
             {:error, :no_storage}

    assert Storage.medium(gadget: tmp_dir) == {:error, :no_storage}
  end
end
