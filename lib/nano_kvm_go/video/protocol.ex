defmodule NanoKVMGo.Video.Protocol do
  @moduledoc false
  # The nano_kvm_go_video port program's side of the port: {:packet, 4} frames
  # of one type byte and a payload on its stdout, {:packet, 4} commands on
  # its stdin. The end of its stdin stops it. An access unit's payload starts
  # with its frame-end CLOCK_MONOTONIC timestamp in microseconds.

  @type packet() ::
          {:log, String.t()}
          | {:h264 | :h265, :key | :delta, binary(), non_neg_integer()}
          | {:input, NanoKVMGo.Video.input()}
          | {:snapshot, NanoKVMGo.Video.snapshot()}
          | {:stats, NanoKVMGo.Video.stats()}
          | :unknown

  @exit_input_changed 3

  @stats %{
    "seconds" => :seconds,
    "captured" => :captured,
    "encoded" => :encoded,
    "skipped" => :skipped,
    "encode_ms" => :encode_ms,
    "encode_max_ms" => :encode_max_ms,
    "dequeue_ms" => :dequeue_ms,
    "dequeue_max_ms" => :dequeue_max_ms,
    "ready_ms" => :ready_ms,
    "ready_max_ms" => :ready_max_ms,
    "bytes" => :bytes,
    "qp" => :qp,
    "qp_max" => :qp_max,
    "keys" => :keys,
    "writer_frames" => :writer_frames,
    "writer_queue_ms" => :writer_queue_ms,
    "writer_queue_max_ms" => :writer_queue_max_ms,
    "copy_ms" => :copy_ms,
    "copy_max_ms" => :copy_max_ms,
    "pipe_ms" => :pipe_ms,
    "pipe_max_ms" => :pipe_max_ms,
    "key_bytes" => :key_bytes,
    "key_max_bytes" => :key_max_bytes,
    "delta_max_bytes" => :delta_max_bytes
  }

  @spec decode(binary()) :: packet()
  def decode(<<0, line::binary>>), do: {:log, line}
  def decode(<<1, at::64, au::binary>>), do: {:h264, :delta, au, at}
  def decode(<<2, at::64, au::binary>>), do: {:h264, :key, au, at}
  def decode(<<4, at::64, au::binary>>), do: {:h265, :delta, au, at}
  def decode(<<5, at::64, au::binary>>), do: {:h265, :key, au, at}

  def decode(<<6, width::16, height::16, rgb::binary>>) when byte_size(rgb) == width * height * 3,
    do: {:snapshot, %{width: width, height: height, data: rgb}}

  def decode(<<3, text::binary>>) do
    case parse_input(text) do
      {:ok, input} -> {:input, input}
      :error -> :unknown
    end
  end

  def decode(<<7, text::binary>>), do: {:stats, parse_stats(text)}

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

  # "<name> <value>" pairs; names it does not know are left out.
  @spec parse_stats(String.t()) :: NanoKVMGo.Video.stats()
  def parse_stats(text) do
    text
    |> String.split()
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.reduce(%{}, fn [name, value], stats ->
      case {@stats[name], Float.parse(value)} do
        {nil, _number} ->
          stats

        {_key, :error} ->
          stats

        {key, {number, _rest}} ->
          Map.put(stats, key, if(number == trunc(number), do: trunc(number), else: number))
      end
    end)
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
