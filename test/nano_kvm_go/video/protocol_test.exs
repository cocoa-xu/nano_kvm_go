defmodule NanoKVMGo.Video.ProtocolTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Video.Protocol

  test "decodes the packets of the port program" do
    assert Protocol.decode(<<0, "capture 1920x1080">>) == {:log, "capture 1920x1080"}
    assert Protocol.decode(<<1, 0, 0, 0, 1, 0x41>>) == {:h264, :delta, <<0, 0, 0, 1, 0x41>>}
    assert Protocol.decode(<<2, 0, 0, 0, 1, 0x67>>) == {:h264, :key, <<0, 0, 0, 1, 0x67>>}
    assert Protocol.decode(<<4, 0, 0, 0, 1, 0x02>>) == {:h265, :delta, <<0, 0, 0, 1, 0x02>>}
    assert Protocol.decode(<<5, 0, 0, 0, 1, 0x40>>) == {:h265, :key, <<0, 0, 0, 1, 0x40>>}

    assert Protocol.decode(<<3, "3840x2160@30">>) ==
             {:input, %{width: 3840, height: 2160, fps: 30}}

    assert Protocol.decode(<<3, "none">>) == {:input, :none}
    assert Protocol.decode(<<3, "unsupported">>) == {:input, :unsupported}
    assert Protocol.decode(<<3, "3840x2160">>) == :unknown

    assert Protocol.decode(<<6, 2::16, 1::16, "RGBrgb">>) ==
             {:snapshot, %{width: 2, height: 1, data: "RGBrgb"}}

    assert Protocol.decode(<<6, 0::16, 0::16>>) == {:snapshot, %{width: 0, height: 0, data: ""}}
    assert Protocol.decode(<<6, 2::16, 2::16, "RGBrgb">>) == :unknown
    assert Protocol.decode(<<9, "?">>) == :unknown
    assert Protocol.decode(<<>>) == :unknown
  end

  test "parses the input as reported" do
    assert Protocol.parse_input("1920x1080@60") == {:ok, %{width: 1920, height: 1080, fps: 60}}
    assert Protocol.parse_input("0x1080@60") == :error
    assert Protocol.parse_input("1920x1080@") == :error
    assert Protocol.parse_input("1920x1080@60fps") == :error
  end

  test "encodes commands and knows the input-changed exit" do
    assert Protocol.command(:start_stream) == "1"
    assert Protocol.command(:stop_stream) == "0"
    assert Protocol.command(:keyframe) == "k"
    assert Protocol.command({:snapshot, {10, 20, 300, 40}}) == "s 10 20 300 40"

    encoding = %{
      codec: :h265,
      rate_control: :constant_qp,
      bitrate: 8_000_000,
      qp: 30,
      keyframe_interval: 600,
      max_fps: 0,
      color_matrix: :bt601,
      color_range: :limited
    }

    assert Protocol.command({:encoding, encoding}) == "e h265 cq 8000000 30 600 0 bt601 limited"
    assert Protocol.input_changed?(3)
    refute Protocol.input_changed?(1)
  end
end
