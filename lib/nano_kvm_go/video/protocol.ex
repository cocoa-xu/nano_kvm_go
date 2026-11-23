defmodule NanoKVMGo.Video.Protocol do
  @moduledoc false
  # The nano_kvm_go_video port program's side of the port: {:packet, 4} frames
  # of one type byte and a payload on its stdout, {:packet, 4} commands on
  # its stdin. The end of its stdin stops it.

  @type packet() ::
          {:log, String.t()}
          | {:h264, :key | :delta, binary()}
          | {:input, NanoKVMGo.Video.input()}
          | :unknown

  @exit_input_changed 3

  @spec decode(binary()) :: packet()
  def decode(<<0, line::binary>>), do: {:log, line}
  def decode(<<1, au::binary>>), do: {:h264, :delta, au}
  def decode(<<2, au::binary>>), do: {:h264, :key, au}

  def decode(<<3, text::binary>>) do
    case parse_input(text) do
      {:ok, input} -> {:input, input}
      :error -> :unknown
    end
  end

  def decode(_packet), do: :unknown

  @spec command(:h264_start | :h264_stop | :keyframe | {:encoding, NanoKVMGo.Video.encoding()}) ::
          String.t()
  def command(:h264_start), do: "1"
  def command(:h264_stop), do: "0"
  def command(:keyframe), do: "k"
  def command({:encoding, encoding}), do: "e " <> encoding(encoding)

  # "<cq|cbr|vbr> <bit/s> <QP> <keyframe interval> <max fps>"
  @spec encoding(NanoKVMGo.Video.encoding()) :: String.t()
  def encoding(encoding) do
    rate_control = Map.fetch!(%{constant_qp: "cq", cbr: "cbr", vbr: "vbr"}, encoding.rate_control)

    Enum.join(
      [rate_control, encoding.bitrate, encoding.qp, encoding.keyframe_interval, encoding.max_fps],
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
