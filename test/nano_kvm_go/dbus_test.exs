defmodule NanoKVMGo.DBusTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.DBus.{Message, Wire}

  describe "signatures" do
    test "parse complete types" do
      assert Wire.parse("a{sv}") == {:ok, [{:array, {:dict_entry, :string, :variant}}]}

      assert Wire.parse("(ia(yv))") ==
               {:ok, [{:struct, [:int32, {:array, {:struct, [:byte, :variant]}}]}]}

      assert Wire.parse("aayo") == {:ok, [{:array, {:array, :byte}}, :object_path]}
    end

    test "refuse what D-Bus does not allow" do
      for bad <- ["a", "()", "a{vs}", "a{(i)s}", "a{si", "(i", "z"] do
        assert Wire.parse(bad) == {:error, :bad_signature}, bad
      end
    end

    test "print back" do
      for signature <- ["a{sv}", "(ia(yv))", "aayo", "a{oa{sa{sv}}}"],
          do: assert(Wire.signature(Wire.parse!(signature)) == signature)
    end
  end

  describe "values" do
    test "round trip with alignment" do
      signature = "ya{sv}(nqx)aysdbaa{sv}"

      values = [
        7,
        %{"Powered" => true, "Name" => "kuroneko"},
        {-2, 65_535, -1},
        <<1, 2, 3>>,
        "héllo",
        1.5,
        false,
        [%{}, %{"A" => 1}]
      ]

      encoded = Wire.encode(signature, encode_variants(values), <<>>)
      assert {:ok, decoded, at} = Wire.decode(signature, encoded, 0)
      assert at == byte_size(encoded)
      assert decoded == values
    end

    test "an array's length leaves out the padding before its first element" do
      # a(i) at offset 1: 3 bytes of padding, the length, 0 bytes up to the
      # 8-aligned first struct, then one int32
      assert Wire.encode("a(i)", [[{5}]], <<9>>) ==
               <<9, 0, 0, 0, 4::little-32, 5::little-32>>

      assert Wire.encode("ax", [[1]], <<>>) == <<8::little-32, 0::32, 1::little-64>>
      assert Wire.encode("ax", [[]], <<>>) == <<0::little-32, 0::32>>
    end

    test "malformed input is an error, not a crash" do
      assert Wire.decode("s", <<5::little-32, "abc">>, 0) == {:error, :malformed}
      assert Wire.decode("b", <<2::little-32>>, 0) == {:error, :malformed}
      assert Wire.decode("ai", <<0xFFFFFFFF::little-32>>, 0) == {:error, :malformed}
    end
  end

  describe "messages" do
    test "Hello as the bus expects it" do
      hello = %Message{
        type: :method_call,
        serial: 1,
        destination: "org.freedesktop.DBus",
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        member: "Hello"
      }

      field = fn code, signature, value ->
        Wire.encode("(yv)", [{code, {signature, value}}], <<>>)
      end

      fields =
        [
          field.(1, "o", "/org/freedesktop/DBus"),
          field.(2, "s", "org.freedesktop.DBus"),
          field.(3, "s", "Hello"),
          field.(6, "s", "org.freedesktop.DBus")
        ]
        |> Enum.reduce(<<>>, fn f, acc -> pad8(acc) <> f end)

      expected =
        <<?l, 1, 0, 1, 0::little-32, 1::little-32, byte_size(fields)::little-32, fields::binary>>

      encoded = Message.encode(hello)
      assert byte_size(fields) == 109
      assert encoded == pad8(expected)
      assert byte_size(encoded) == 128
      assert {:ok, ^hello, ""} = Message.decode(encoded)
    end

    test "a reply with a body, split across reads" do
      reply = %Message{
        type: :method_return,
        serial: 9,
        reply_serial: 3,
        sender: ":1.4",
        destination: ":1.7",
        signature: "a{oa{sa{sv}}}",
        body: [%{"/org/bluez/hci0" => %{"org.bluez.Adapter1" => %{"Powered" => {"b", true}}}}]
      }

      encoded = Message.encode(reply) <> "next"
      <<head::binary-size(20), _::binary>> = encoded
      assert Message.decode(head) == :incomplete
      assert Message.decode(<<?l, 2>>) == :incomplete

      assert {:ok, decoded, "next"} = Message.decode(encoded)

      assert decoded.body == [
               %{"/org/bluez/hci0" => %{"org.bluez.Adapter1" => %{"Powered" => true}}}
             ]

      assert %{decoded | body: reply.body} == reply
    end

    test "big-endian and garbage are malformed" do
      assert Message.decode(<<?B, 1, 0, 1, 0::128>>) == {:error, :malformed}
      assert Message.decode("hello world, not D-Bus") == {:error, :malformed}
    end
  end

  defp encode_variants([byte, dict, struct, bytes, string, double, bool, list]) do
    variants = fn map -> Map.new(map, fn {k, v} -> {k, {variant_type(v), v}} end) end
    [byte, variants.(dict), struct, bytes, string, double, bool, Enum.map(list, variants)]
  end

  defp variant_type(v) when is_boolean(v), do: "b"
  defp variant_type(v) when is_integer(v), do: "i"
  defp variant_type(v) when is_binary(v), do: "s"

  defp pad8(bin), do: <<bin::binary, 0::size(rem(8 - rem(byte_size(bin), 8), 8) * 8)>>
end
