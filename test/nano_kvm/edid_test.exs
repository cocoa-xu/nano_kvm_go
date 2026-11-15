defmodule NanoKVM.EDIDTest do
  use ExUnit.Case, async: true

  # The EDID of the NanoKVM-Go's LT7911EXC, as shipped.
  @stock Base.decode16!(
           """
           00ffffffffffff004e0405333930000006240103813c22782eee91a3544c9926
           0f5054210800d1c0a9c0d1008180814081c00101010104740030f2705a80b058
           8a0055502100001e332d0050a0a015500820780055502100001a000000fc004e
           616e6f4b564d2d476f0a2020000000fd00176416a03c000a202020202020012a
           02032cf1485f0104133e1f2210230907078301000067030c001000184467d85d
           c401788000e305e301e200cba35b0050a0a029500820b80455502100001a7589
           0050a0a029500820b80455502100001a00000000000000000000000000000000
           0000000000000000000000000000000000000000000000000000000000000088
           """
           |> String.replace(~r/\s/, ""),
           case: :lower
         )

  test "decodes the identity and the name" do
    assert {:ok, edid} = NanoKVM.EDID.decode(@stock)
    assert edid.manufacturer == "SPD"
    assert edid.product == 0x3305
    assert edid.serial == 12_345
    assert {edid.week, edid.year} == {6, 2026}
    assert edid.version == "1.3"
    assert edid.name == "NanoKVM-Go"
    assert edid.extensions == 1
  end

  test "lists the detailed timings, the preferred one first" do
    assert {:ok, %{modes: modes}} = NanoKVM.EDID.decode(@stock)

    assert Enum.map(modes, &{&1.width, &1.height, &1.refresh}) == [
             {3840, 2160, 30.0},
             {2560, 1440, 30.0},
             {2560, 1440, 60.0},
             {2560, 1440, 90.0}
           ]

    assert hd(modes).pixel_clock_khz == 297_000
    refute Enum.any?(modes, & &1.interlaced)
  end

  test "refuses what is not an EDID" do
    assert NanoKVM.EDID.decode(<<1, 2, 3>>) == {:error, :invalid_edid}
    assert NanoKVM.EDID.decode(binary_part(@stock, 0, 127)) == {:error, :invalid_edid}
  end
end
