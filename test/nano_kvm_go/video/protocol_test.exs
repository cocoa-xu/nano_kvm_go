defmodule NanoKVMGo.Video.ProtocolTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Video.Protocol

  test "decodes the packets of the port program" do
    assert Protocol.decode(<<0, "capture 1920x1080">>) == {:log, "capture 1920x1080"}
    assert Protocol.decode(<<1, 0, 0, 0, 1, 0x41>>) == {:h264, :delta, <<0, 0, 0, 1, 0x41>>}
    assert Protocol.decode(<<2, 0, 0, 0, 1, 0x67>>) == {:h264, :key, <<0, 0, 0, 1, 0x67>>}

    assert Protocol.decode(<<3, "3840x2160@30">>) ==
             {:input, %{width: 3840, height: 2160, fps: 30}}

    assert Protocol.decode(<<3, "none">>) == {:input, :none}
    assert Protocol.decode(<<3, "unsupported">>) == {:input, :unsupported}
    assert Protocol.decode(<<3, "3840x2160">>) == :unknown
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
    assert Protocol.command(:h264_start) == "1"
    assert Protocol.command(:h264_stop) == "0"
    assert Protocol.command(:keyframe) == "k"
    assert Protocol.input_changed?(3)
    refute Protocol.input_changed?(1)
  end
end
