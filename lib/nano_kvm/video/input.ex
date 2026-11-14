defmodule NanoKVM.Video.Input do
  @moduledoc """
  The signal at the HDMI/DisplayPort input, as the LT7911EXC bridge reports
  it.
  """

  @typedoc """
  A mode the bridge passes on: the size of a frame in pixels and the frame
  rate.
  """
  @type mode() :: %{width: pos_integer(), height: pos_integer(), fps: non_neg_integer()}

  @typedoc """
  The input: a `t:mode/0`, `:none` without a signal, or `:unsupported` for a
  signal the bridge cannot pass on.
  """
  @type t() :: mode() | :none | :unsupported
end
