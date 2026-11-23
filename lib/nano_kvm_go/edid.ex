defmodule NanoKVMGo.EDID do
  @moduledoc """
  Decodes an EDID, such as the one `NanoKVMGo.Video.edid/0` returns: who made
  the display it describes, its name and the modes it lists.

      {:ok, edid} = NanoKVMGo.Video.edid()
      {:ok, %{name: "NanoKVM-Go", modes: [%{width: 3840, height: 2160} | _]}} =
        NanoKVMGo.EDID.decode(edid)

  The modes are the detailed timings of the base block and of CTA-861
  extension blocks, the preferred mode first.
  """

  import Bitwise

  alias NanoKVMGo.Video.EDID, as: Check

  @typedoc "A detailed timing."
  @type mode() :: %{
          width: pos_integer(),
          height: pos_integer(),
          refresh: float(),
          pixel_clock_khz: pos_integer(),
          interlaced: boolean()
        }

  @type t() :: %{
          manufacturer: String.t(),
          product: non_neg_integer(),
          serial: non_neg_integer(),
          week: non_neg_integer(),
          year: pos_integer(),
          version: String.t(),
          name: String.t() | nil,
          modes: [mode()],
          extensions: non_neg_integer()
        }

  @doc """
  Decodes an EDID of one to four blocks with valid checksums.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_edid}
  def decode(edid) do
    with :ok <- Check.validate(edid) do
      <<_header::binary-size(8), manufacturer::big-16, product::little-16, serial::little-32,
        week, year, version, revision, _basic::binary-size(34), descriptors::binary-size(72),
        extensions, _checksum, rest::binary>> = edid

      {:ok,
       %{
         manufacturer: manufacturer_id(manufacturer),
         product: product,
         serial: serial,
         week: week,
         year: 1990 + year,
         version: "#{version}.#{revision}",
         name: monitor_name(descriptors),
         modes: timings(descriptors) ++ Enum.flat_map(blocks(rest), &extension_timings/1),
         extensions: extensions
       }}
    end
  end

  # Three letters of five bits, 1 for "A".
  defp manufacturer_id(id) do
    for shift <- [10, 5, 0], into: "", do: <<?A + (id >>> shift &&& 0x1F) - 1>>
  end

  defp monitor_name(descriptors) do
    Enum.find_value(chunks(descriptors), fn
      <<0, 0, 0, 0xFC, 0, text::binary-size(13)>> ->
        text |> String.split("\n") |> hd() |> String.trim_trailing()

      _ ->
        nil
    end)
  end

  defp timings(descriptors) do
    descriptors |> chunks() |> Enum.flat_map(&timing/1)
  end

  # Only the detailed timings of CTA-861 blocks: from the offset in byte 2 up
  # to the checksum.
  defp extension_timings(<<0x02, _revision, offset, _flags, _rest::binary>> = block)
       when offset >= 4 and offset <= 127 do
    block |> binary_part(offset, 127 - offset) |> timings()
  end

  defp extension_timings(_block), do: []

  defp timing(
         <<clock::little-16, ha_lo, hb_lo, ha_hi::4, hb_hi::4, va_lo, vb_lo, va_hi::4, vb_hi::4,
           _sync::binary-size(4), _size::binary-size(3), _border::binary-size(2), interlaced::1,
           _flags::7>>
       )
       when clock > 0 do
    width = ha_hi * 256 + ha_lo
    height = va_hi * 256 + va_lo
    fields = if interlaced == 1, do: 2, else: 1

    case (width + hb_hi * 256 + hb_lo) * (height + vb_hi * 256 + vb_lo) do
      0 ->
        []

      total ->
        [
          %{
            width: width,
            height: height * fields,
            refresh: Float.round(clock * 10_000 / total * fields, 2),
            pixel_clock_khz: clock * 10,
            interlaced: interlaced == 1
          }
        ]
    end
  end

  defp timing(_descriptor), do: []

  defp chunks(binary), do: for(<<chunk::binary-size(18) <- binary>>, do: chunk)
  defp blocks(binary), do: for(<<block::binary-size(128) <- binary>>, do: block)
end
