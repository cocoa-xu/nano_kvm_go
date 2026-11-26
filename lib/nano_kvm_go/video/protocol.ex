defmodule NanoKVMGo.Video.Protocol do
  @moduledoc false
  # The nano_kvm_go_video port program's side of the port: {:packet, 4} frames
  # of one type byte and a payload on its stdout, {:packet, 4} commands on
  # its stdin. The end of its stdin stops it.

  @type packet() ::
          {:log, String.t()}
          | {:h264 | :h265, :key | :delta, binary()}
          | {:input, NanoKVMGo.Video.input()}
          | {:snapshot, NanoKVMGo.Video.snapshot()}
          | :unknown

  @exit_input_changed 3

  @spec decode(binary()) :: packet()
  def decode(<<0, line::binary>>), do: {:log, line}
  def decode(<<1, au::binary>>), do: {:h264, :delta, au}
  def decode(<<2, au::binary>>), do: {:h264, :key, au}
  def decode(<<4, au::binary>>), do: {:h265, :delta, au}
  def decode(<<5, au::binary>>), do: {:h265, :key, au}

  def decode(<<6, width::16, height::16, rgb::binary>>) when byte_size(rgb) == width * height * 3,
    do: {:snapshot, %{width: width, height: height, data: rgb}}

  def decode(<<3, text::binary>>) do
    case parse_input(text) do
      {:ok, input} -> {:input, input}
      :error -> :unknown
    end
  end

  def decode(_packet), do: :unknown

  @spec command(
          :start_stream
          | :stop_stream
          | :keyframe
          | {:encoding, NanoKVMGo.Video.encoding()}
          | {:snapshot, NanoKVMGo.Video.region()}
        ) :: String.t()
  def command(:start_stream), do: "1"
  def command(:stop_stream), do: "0"
  def command(:keyframe), do: "k"
  def command({:encoding, encoding}), do: "e " <> encoding(encoding)
  def command({:snapshot, {x, y, width, height}}), do: "s #{x} #{y} #{width} #{height}"

  # "<h264|h265> <cq|cbr|vbr> <bit/s> <QP> <keyframe interval> <max fps>
  # <auto|bt601|bt709> <auto|full|limited>"
  @spec encoding(NanoKVMGo.Video.encoding()) :: String.t()
  def encoding(encoding) do
    rate_control = Map.fetch!(%{constant_qp: "cq", cbr: "cbr", vbr: "vbr"}, encoding.rate_control)

    Enum.join(
      [
        encoding.codec,
        rate_control,
        encoding.bitrate,
        encoding.qp,
        encoding.keyframe_interval,
        encoding.max_fps,
        encoding.color_matrix,
        encoding.color_range
      ],
      " "
    )
  end

  @spec input_changed?(non_neg_integer()) :: boolean()
  def input_changed?(status), do: status == @exit_input_changed

  @spec parse_input(String.t()) :: {:ok, NanoKVMGo.Video.input()} | :error
  def parse_input("none"), do: {:ok, :none}
  def parse_input("unsupported"), do: {:ok, :unsupported}

  def parse_input(text) do
    with [w, h, f] <- String.split(text, ["x", "@"]),
         {width, ""} when width > 0 <- Integer.parse(w),
         {height, ""} when height > 0 <- Integer.parse(h),
         {fps, ""} when fps >= 0 <- Integer.parse(f) do
      {:ok, %{width: width, height: height, fps: fps}}
    else
      _ -> :error
    end
  end
end
