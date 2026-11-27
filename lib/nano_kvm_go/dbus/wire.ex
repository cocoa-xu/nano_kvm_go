defmodule NanoKVMGo.DBus.Wire do
  @moduledoc false
  # D-Bus marshalling in little-endian, values by their signature.
  #
  # Values: integers, booleans and floats as such; strings, object paths and
  # signatures as binaries; `ay` as a binary; other arrays as lists; dict
  # arrays as maps (a list of pairs also encodes); structs as tuples. A
  # variant encodes from `{signature, value}` and decodes to its value.
  #
  # Alignment counts from the start of the message: `encode/3` and
  # `decode/3` take the offset of their first byte.

  @type type() ::
          :byte
          | :boolean
          | :int16
          | :uint16
          | :int32
          | :uint32
          | :int64
          | :uint64
          | :double
          | :string
          | :object_path
          | :signature
          | :unix_fd
          | :variant
          | {:array, type()}
          | {:struct, [type()]}
          | {:dict_entry, type(), type()}

  @basic %{
    ?y => :byte,
    ?b => :boolean,
    ?n => :int16,
    ?q => :uint16,
    ?i => :int32,
    ?u => :uint32,
    ?x => :int64,
    ?t => :uint64,
    ?d => :double,
    ?s => :string,
    ?o => :object_path,
    ?g => :signature,
    ?h => :unix_fd,
    ?v => :variant
  }

  @max_array 64 * 1024 * 1024

  @doc "The complete types of a signature."
  @spec parse(String.t()) :: {:ok, [type()]} | {:error, :bad_signature}
  def parse(signature) do
    {:ok, parse_all(signature, [])}
  catch
    :bad_signature -> {:error, :bad_signature}
  end

  @spec parse!(String.t()) :: [type()]
  def parse!(signature) do
    case parse(signature) do
      {:ok, types} ->
        types

      {:error, :bad_signature} ->
        raise ArgumentError, "bad D-Bus signature: #{inspect(signature)}"
    end
  end

  defp parse_all("", acc), do: Enum.reverse(acc)

  defp parse_all(signature, acc) do
    {type, rest} = parse_one(signature)
    parse_all(rest, [type | acc])
  end

  defp parse_one(<<?a, ?{, rest::binary>>) do
    with {key, rest} when is_atom(key) and key != :variant <- parse_one(rest),
         {value, <<?}, rest::binary>>} <- parse_one(rest) do
      {{:array, {:dict_entry, key, value}}, rest}
    else
      _other -> throw(:bad_signature)
    end
  end

  defp parse_one(<<?a, rest::binary>>) do
    {element, rest} = parse_one(rest)
    {{:array, element}, rest}
  end

  defp parse_one(<<?(, rest::binary>>), do: parse_struct(rest, [])

  defp parse_one(<<code, rest::binary>>) when is_map_key(@basic, code),
    do: {Map.fetch!(@basic, code), rest}

  defp parse_one(_signature), do: throw(:bad_signature)

  defp parse_struct(<<?), _rest::binary>>, []), do: throw(:bad_signature)
  defp parse_struct(<<?), rest::binary>>, fields), do: {{:struct, Enum.reverse(fields)}, rest}

  defp parse_struct(signature, fields) do
    {field, rest} = parse_one(signature)
    parse_struct(rest, [field | fields])
  end

  @doc "The signature of types."
  @spec signature([type()] | type()) :: String.t()
  def signature(types) when is_list(types), do: Enum.map_join(types, &signature/1)
  def signature({:array, {:dict_entry, k, v}}), do: "a{" <> signature(k) <> signature(v) <> "}"
  def signature({:array, element}), do: "a" <> signature(element)
  def signature({:struct, fields}), do: "(" <> signature(fields) <> ")"

  for {code, type} <- @basic do
    def signature(unquote(type)), do: <<unquote(code)>>
  end

  @spec alignment(type()) :: pos_integer()
  def alignment(type) when type in [:byte, :signature, :variant], do: 1
  def alignment(type) when type in [:int16, :uint16], do: 2
  def alignment(type) when type in [:int64, :uint64, :double], do: 8
  def alignment({:struct, _fields}), do: 8
  def alignment({:dict_entry, _key, _value}), do: 8
  def alignment(_type), do: 4

  @doc "Appends values of a signature to the message bytes so far."
  @spec encode(String.t() | [type()], [term()], binary()) :: binary()
  def encode(signature, values, acc) when is_binary(signature),
    do: encode(parse!(signature), values, acc)

  def encode(types, values, acc) when length(types) == length(values) do
    Enum.zip_reduce(types, values, acc, &put/3)
  end

  def encode(types, values, _acc) do
    raise ArgumentError,
          "#{length(values)} values for the signature #{inspect(signature(types))}"
  end

  defp put(:byte, value, acc) when value in 0..255, do: <<acc::binary, value>>
  defp put(:boolean, true, acc), do: <<pad(acc, 4)::binary, 1::little-32>>
  defp put(:boolean, false, acc), do: <<pad(acc, 4)::binary, 0::little-32>>
  defp put(:int16, v, acc) when is_integer(v), do: <<pad(acc, 2)::binary, v::little-signed-16>>
  defp put(:uint16, v, acc) when is_integer(v), do: <<pad(acc, 2)::binary, v::little-16>>
  defp put(:int32, v, acc) when is_integer(v), do: <<pad(acc, 4)::binary, v::little-signed-32>>
  defp put(:uint32, v, acc) when is_integer(v), do: <<pad(acc, 4)::binary, v::little-32>>
  defp put(:unix_fd, v, acc) when is_integer(v), do: <<pad(acc, 4)::binary, v::little-32>>
  defp put(:int64, v, acc) when is_integer(v), do: <<pad(acc, 8)::binary, v::little-signed-64>>
  defp put(:uint64, v, acc) when is_integer(v), do: <<pad(acc, 8)::binary, v::little-64>>

  defp put(:double, v, acc) when is_number(v),
    do: <<pad(acc, 8)::binary, v * 1.0::little-float-64>>

  defp put(type, v, acc) when type in [:string, :object_path] and is_binary(v),
    do: <<pad(acc, 4)::binary, byte_size(v)::little-32, v::binary, 0>>

  defp put(:signature, v, acc) when is_binary(v) and byte_size(v) < 256,
    do: <<acc::binary, byte_size(v), v::binary, 0>>

  defp put(:variant, {signature, value}, acc) when is_binary(signature) do
    case parse!(signature) do
      [type] -> put(type, value, put(:signature, signature, acc))
      _types -> raise ArgumentError, "a variant holds one type, not #{inspect(signature)}"
    end
  end

  defp put({:array, :byte}, v, acc) when is_binary(v),
    do: <<pad(acc, 4)::binary, byte_size(v)::little-32, v::binary>>

  defp put({:array, {:dict_entry, _k, _v} = entry}, v, acc) when is_map(v),
    do: put({:array, entry}, Map.to_list(v), acc)

  defp put({:array, element}, values, acc) when is_list(values) do
    start = pad(<<pad(acc, 4)::binary, 0::32>>, alignment(element))
    filled = Enum.reduce(values, start, &put(element, &1, &2))
    length = byte_size(filled) - byte_size(start)
    at = byte_size(pad(acc, 4))

    <<binary_part(filled, 0, at)::binary, length::little-32,
      binary_part(filled, at + 4, byte_size(filled) - at - 4)::binary>>
  end

  defp put({:struct, fields}, value, acc) when is_tuple(value),
    do: encode(fields, Tuple.to_list(value), pad(acc, 8))

  defp put({:dict_entry, k, v}, {key, value}, acc),
    do: put(v, value, put(k, key, pad(acc, 8)))

  defp put(type, value, _acc) do
    raise ArgumentError, "#{inspect(value)} is not a D-Bus #{signature(type)}"
  end

  defp pad(acc, n) do
    case rem(byte_size(acc), n) do
      0 -> acc
      r -> <<acc::binary, 0::size((n - r) * 8)>>
    end
  end

  @doc """
  Reads values of a signature from `bin` at `at`, an offset from the start
  of the message `bin` begins it.
  """
  @spec decode(String.t() | [type()], binary(), non_neg_integer()) ::
          {:ok, [term()], non_neg_integer()} | {:error, :malformed}
  def decode(signature, bin, at) when is_binary(signature) do
    case parse(signature) do
      {:ok, types} -> decode(types, bin, at)
      {:error, :bad_signature} -> {:error, :malformed}
    end
  end

  def decode(types, bin, at) do
    {values, at} =
      Enum.map_reduce(types, at, fn type, at -> take(type, bin, at) end)

    {:ok, values, at}
  catch
    :malformed -> {:error, :malformed}
  end

  defp take(:byte, bin, at), do: {byte(bin, at), at + 1}

  defp take(:boolean, bin, at) do
    case fixed(bin, align(at, 4), 4) do
      <<0::little-32>> -> {false, align(at, 4) + 4}
      <<1::little-32>> -> {true, align(at, 4) + 4}
      _other -> throw(:malformed)
    end
  end

  defp take(:int16, bin, at), do: number(bin, at, 2, fn <<v::little-signed-16>> -> v end)
  defp take(:uint16, bin, at), do: number(bin, at, 2, fn <<v::little-16>> -> v end)
  defp take(:int32, bin, at), do: number(bin, at, 4, fn <<v::little-signed-32>> -> v end)
  defp take(:uint32, bin, at), do: number(bin, at, 4, fn <<v::little-32>> -> v end)
  defp take(:unix_fd, bin, at), do: number(bin, at, 4, fn <<v::little-32>> -> v end)
  defp take(:int64, bin, at), do: number(bin, at, 8, fn <<v::little-signed-64>> -> v end)
  defp take(:uint64, bin, at), do: number(bin, at, 8, fn <<v::little-64>> -> v end)

  defp take(:double, bin, at) do
    number(bin, at, 8, fn
      <<v::little-float-64>> -> v
      _nan_or_infinity -> throw(:malformed)
    end)
  end

  defp take(type, bin, at) when type in [:string, :object_path] do
    {length, at} = take(:uint32, bin, at)
    string = fixed(bin, at, length)
    if byte(bin, at + length) != 0, do: throw(:malformed)
    {string, at + length + 1}
  end

  defp take(:signature, bin, at) do
    length = byte(bin, at)
    string = fixed(bin, at + 1, length)
    if byte(bin, at + 1 + length) != 0, do: throw(:malformed)
    {string, at + length + 2}
  end

  defp take(:variant, bin, at) do
    {signature, at} = take(:signature, bin, at)

    case parse(signature) do
      {:ok, [type]} -> take(type, bin, at)
      _other -> throw(:malformed)
    end
  end

  defp take({:array, element}, bin, at) do
    {length, at} = take(:uint32, bin, at)
    if length > @max_array, do: throw(:malformed)
    start = align(at, alignment(element))
    fixed(bin, start, length)
    array(element, bin, start, start + length)
  end

  defp take({:struct, fields}, bin, at) do
    {values, at} = Enum.map_reduce(fields, align(at, 8), &take(&1, bin, &2))
    {List.to_tuple(values), at}
  end

  defp take({:dict_entry, k, v}, bin, at) do
    {key, at} = take(k, bin, align(at, 8))
    {value, at} = take(v, bin, at)
    {{key, value}, at}
  end

  defp array(:byte, bin, start, stop), do: {fixed(bin, start, stop - start), stop}

  defp array({:dict_entry, _k, _v} = entry, bin, start, stop) do
    {pairs, at} = elements(entry, bin, start, stop, [])
    {Map.new(pairs), at}
  end

  defp array(element, bin, start, stop), do: elements(element, bin, start, stop, [])

  defp elements(_element, _bin, at, stop, acc) when at >= stop do
    if at > stop, do: throw(:malformed)
    {Enum.reverse(acc), at}
  end

  defp elements(element, bin, at, stop, acc) do
    {value, next} = take(element, bin, at)
    elements(element, bin, next, stop, [value | acc])
  end

  defp number(bin, at, size, read) do
    at = align(at, size)
    {read.(fixed(bin, at, size)), at + size}
  end

  defp byte(bin, at) when at < byte_size(bin), do: :binary.at(bin, at)
  defp byte(_bin, _at), do: throw(:malformed)

  defp fixed(bin, at, size) when at + size <= byte_size(bin), do: binary_part(bin, at, size)
  defp fixed(_bin, _at, _size), do: throw(:malformed)

  @spec align(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def align(at, n), do: at + rem(n - rem(at, n), n)
end
