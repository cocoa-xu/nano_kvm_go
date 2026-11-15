defmodule NanoKVM.Video.EDID do
  @moduledoc false
  # Reads and stores the EDID of the video input with nano_kvm_edid.

  @block 128
  @max_blocks 4
  @header <<0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>>

  @spec read(Path.t(), String.t() | nil) :: {:ok, binary()} | {:error, term()}
  def read(_program, nil), do: {:error, :no_device}

  def read(program, device) do
    with {:ok, edid} <- run(program, [device]),
         :ok <- validate(edid) do
      {:ok, edid}
    end
  end

  @spec write(Path.t(), String.t() | nil, binary()) :: :ok | {:error, term()}
  def write(program, device, edid) do
    cond do
      validate(edid) != :ok -> {:error, :invalid_edid}
      device == nil -> {:error, :no_device}
      true -> with {:ok, _output} <- run(program, [device, Base.encode16(edid)]), do: :ok
    end
  end

  @doc "Checks the size, the header and the checksum of every block."
  @spec validate(term()) :: :ok | {:error, :invalid_edid}
  def validate(<<@header, _rest::binary>> = edid)
      when rem(byte_size(edid), @block) == 0 and byte_size(edid) <= @block * @max_blocks do
    if checksums_valid?(edid), do: :ok, else: {:error, :invalid_edid}
  end

  def validate(_edid), do: {:error, :invalid_edid}

  defp checksums_valid?(<<>>), do: true

  defp checksums_valid?(<<block::binary-size(@block), rest::binary>>) do
    rem(Enum.sum(:binary.bin_to_list(block)), 256) == 0 and checksums_valid?(rest)
  end

  defp run(program, args) do
    if File.regular?(program) do
      case System.cmd(program, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _status} -> {:error, String.trim(output)}
      end
    else
      {:error, {:missing_program, program}}
    end
  end
end
