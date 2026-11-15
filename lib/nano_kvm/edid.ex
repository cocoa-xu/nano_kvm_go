defmodule NanoKVM.EDID do
  @moduledoc """
  Decodes an EDID, such as the one `NanoKVM.Video.edid/0` returns: who made
  the display it describes, its name and the modes it lists.

      {:ok, edid} = NanoKVM.Video.edid()
      {:ok, %{name: "NanoKVM-Go", modes: [%{width: 3840, height: 2160} | _]}} =
        NanoKVM.EDID.decode(edid)

  The modes are the detailed timings of the base block and of CTA-861
  extension blocks, the preferred mode first.
  """

  import Bitwise

  alias NanoKVM.Video.EDID, as: Check

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
         <<clock::little-16, ha_lo, hb_lo, h_hi, va_lo, vb_lo, v_hi, _sync::binary-size(4),
           _size::binary-size(3), _border::binary-size(2), flags>>
       )
       when clock > 0 do
    width = ha_lo + ((h_hi &&& 0xF0) <<< 4)
    hblank = hb_lo + ((h_hi &&& 0x0F) <<< 8)
    height = va_lo + ((v_hi &&& 0xF0) <<< 4)
    vblank = vb_lo + ((v_hi &&& 0x0F) <<< 8)
    interlaced = (flags &&& 0x80) != 0
    pixel_clock_khz = clock * 10
    total = (width + hblank) * (height + vblank)
    refresh = pixel_clock_khz * 1000 / total * if(interlaced, do: 2, else: 1)

    [
      %{
        width: width,
        height: if(interlaced, do: height * 2, else: height),
        refresh: Float.round(refresh, 2),
        pixel_clock_khz: pixel_clock_khz,
        interlaced: interlaced
      }
    ]
  end

  defp timing(_descriptor), do: []

  defp chunks(binary), do: for(<<chunk::binary-size(18) <- binary>>, do: chunk)
  defp blocks(binary), do: for(<<block::binary-size(128) <- binary>>, do: block)
end
