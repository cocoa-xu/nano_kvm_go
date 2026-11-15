defmodule NanoKVMGo.Video.EDIDTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Video.EDID

  @moduletag :tmp_dir

  @header <<0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>>

  # A block with the given bytes after the header and a valid checksum.
  defp block(fill, extensions \\ 0) do
    body = @header <> :binary.copy(<<fill>>, 118) <> <<extensions>>
    body <> <<rem(256 - rem(Enum.sum(:binary.bin_to_list(body)), 256), 256)>>
  end

  defp extension(fill) do
    body = :binary.copy(<<fill>>, 127)
    body <> <<rem(256 - rem(Enum.sum(:binary.bin_to_list(body)), 256), 256)>>
  end

  defp fake_program(tmp_dir, script) do
    program = Path.join(tmp_dir, "fake_edid")
    File.write!(program, "#!/bin/sh\n" <> script)
    File.chmod!(program, 0o755)
    program
  end

  test "accepts one to four blocks with valid checksums" do
    assert EDID.validate(block(1)) == :ok
    assert EDID.validate(block(1, 1) <> extension(2)) == :ok
    assert EDID.validate(block(1, 3) <> extension(2) <> extension(3) <> extension(4)) == :ok
  end

  test "refuses anything else" do
    assert EDID.validate(<<>>) == {:error, :invalid_edid}
    assert EDID.validate(binary_part(block(1), 0, 127)) == {:error, :invalid_edid}
    assert EDID.validate(:binary.copy(<<0>>, 128)) == {:error, :invalid_edid}
    assert EDID.validate(block(1) <> extension(2) <> <<1>>) == {:error, :invalid_edid}

    <<start::binary-size(20), byte, rest::binary>> = block(1)
    assert EDID.validate(start <> <<byte + 1>> <> rest) == {:error, :invalid_edid}

    five = block(1, 4) <> extension(2) <> extension(3) <> extension(4) <> extension(5)
    assert EDID.validate(five) == {:error, :invalid_edid}
    assert EDID.validate(nil) == {:error, :invalid_edid}
  end

  test "reads the EDID of the device", %{tmp_dir: tmp_dir} do
    edid = block(7, 1) <> extension(8)
    File.write!(Path.join(tmp_dir, "edid.bin"), edid)
    program = fake_program(tmp_dir, ~s([ "$1" = /dev/video0 ] && cat "#{tmp_dir}/edid.bin"\n))

    assert EDID.read(program, "/dev/video0") == {:ok, edid}
    assert EDID.read(program, nil) == {:error, :no_device}
  end

  test "reports why a read failed", %{tmp_dir: tmp_dir} do
    program = fake_program(tmp_dir, "echo 'VIDIOC_G_EDID: Inappropriate ioctl' >&2\nexit 1\n")
    assert EDID.read(program, "/dev/video0") == {:error, "VIDIOC_G_EDID: Inappropriate ioctl"}

    missing = Path.join(tmp_dir, "missing")
    assert EDID.read(missing, "/dev/video0") == {:error, {:missing_program, missing}}
  end

  test "stores a valid EDID in hex", %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "stored")
    program = fake_program(tmp_dir, ~s(printf '%s %s' "$1" "$2" > "#{out}"\n))
    edid = block(9)

    assert EDID.write(program, "/dev/video0", edid) == :ok
    assert File.read!(out) == "/dev/video0 " <> Base.encode16(edid)

    File.rm!(out)
    assert EDID.write(program, "/dev/video0", <<1, 2, 3>>) == {:error, :invalid_edid}
    assert EDID.write(program, nil, edid) == {:error, :no_device}
    refute File.exists?(out)
  end
end
