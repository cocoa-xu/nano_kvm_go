defmodule NanoKVM.Audio.Protocol do
  @moduledoc false
  # The nano_kvm_audio port program's output: {:packet, 4} frames of one
  # type byte and a payload. The end of its stdin stops it.

  @type packet() ::
          {:log, String.t()}
          | {:pcm, binary()}
          | {:format, %{rate: pos_integer(), channels: pos_integer()}}
          | :unknown

  @spec decode(binary()) :: packet()
  def decode(<<0, line::binary>>), do: {:log, line}
  def decode(<<1, pcm::binary>>), do: {:pcm, pcm}

  def decode(<<2, text::binary>>) do
    with [r, c] <- String.split(text, " "),
         {rate, ""} when rate > 0 <- Integer.parse(r),
         {channels, ""} when channels > 0 <- Integer.parse(c) do
      {:format, %{rate: rate, channels: channels}}
    else
      _ -> :unknown
    end
  end

  def decode(_packet), do: :unknown
end
