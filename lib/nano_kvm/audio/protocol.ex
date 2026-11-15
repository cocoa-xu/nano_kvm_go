defmodule NanoKVM.Audio.Protocol do
  @moduledoc false
  # The output of the nano_kvm_audio and nano_kvm_playback port programs:
  # {:packet, 4} frames of one type byte and a payload. The end of their
  # stdin stops them.

  @sample_formats %{
    "S16_LE" => :s16_le,
    "S24_3LE" => :s24_3le,
    "S24_LE" => :s24_le,
    "S32_LE" => :s32_le
  }

  @type packet() ::
          {:log, String.t()}
          | {:pcm, binary()}
          | {:format, NanoKVM.Audio.format()}
          | :unknown

  @spec decode(binary()) :: packet()
  def decode(<<0, line::binary>>), do: {:log, line}
  def decode(<<1, pcm::binary>>), do: {:pcm, pcm}

  def decode(<<2, text::binary>>) do
    with [r, c | sample_format] <- String.split(text, " "),
         {rate, ""} when rate > 0 <- Integer.parse(r),
         {channels, ""} when channels > 0 <- Integer.parse(c),
         {:ok, sample_format} <- sample_format(sample_format) do
      {:format, %{rate: rate, channels: channels, sample_format: sample_format}}
    else
      _ -> :unknown
    end
  end

  def decode(_packet), do: :unknown

  defp sample_format([]), do: {:ok, :s16_le}
  defp sample_format([name]), do: Map.fetch(@sample_formats, name)
  defp sample_format(_other), do: :error
end
