defmodule NanoKVMGo.DBus.Message do
  @moduledoc false
  # A D-Bus message: header fields and body, little-endian only.

  alias NanoKVMGo.DBus.Wire

  @no_reply_expected 0x1
  @max_size 128 * 1024 * 1024

  @types [method_call: 1, method_return: 2, error: 3, signal: 4]

  @fields [
    path: {1, "o"},
    interface: {2, "s"},
    member: {3, "s"},
    error_name: {4, "s"},
    reply_serial: {5, "u"},
    destination: {6, "s"},
    sender: {7, "s"},
    signature: {8, "g"},
    unix_fds: {9, "u"}
  ]

  defstruct type: :method_call,
            flags: 0,
            serial: 0,
            path: nil,
            interface: nil,
            member: nil,
            error_name: nil,
            reply_serial: nil,
            destination: nil,
            sender: nil,
            signature: "",
            unix_fds: nil,
            body: []

  @type t() :: %__MODULE__{
          type: :method_call | :method_return | :error | :signal,
          flags: non_neg_integer(),
          serial: non_neg_integer(),
          path: String.t() | nil,
          interface: String.t() | nil,
          member: String.t() | nil,
          error_name: String.t() | nil,
          reply_serial: non_neg_integer() | nil,
          destination: String.t() | nil,
          sender: String.t() | nil,
          signature: String.t(),
          unix_fds: non_neg_integer() | nil,
          body: [term()]
        }

  @spec reply_expected?(t()) :: boolean()
  def reply_expected?(%__MODULE__{type: :method_call, flags: flags}),
    do: Bitwise.band(flags, @no_reply_expected) == 0

  def reply_expected?(%__MODULE__{}), do: false

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = message) do
    body = Wire.encode(message.signature, message.body, <<>>)

    fields =
      for {key, {code, signature}} <- @fields,
          value = Map.fetch!(message, key),
          value not in [nil, ""],
          do: {code, {signature, value}}

    header =
      Wire.encode(
        "a(yv)",
        [fields],
        <<?l, Keyword.fetch!(@types, message.type), message.flags, 1, byte_size(body)::little-32,
          message.serial::little-32>>
      )

    <<header::binary, 0::size(Wire.align(byte_size(header), 8) - byte_size(header))-unit(8),
      body::binary>>
  end

  @doc """
  The first message of `bin`, with the bytes after it; `:incomplete` while
  `bin` holds only part of it.
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | :incomplete | {:error, :malformed}
  def decode(
        <<?l, type, flags, 1, body_length::little-32, serial::little-32, fields_length::little-32,
          _rest::binary>> = bin
      ) do
    header_end = Wire.align(16 + fields_length, 8)
    total = header_end + body_length

    cond do
      total > @max_size -> {:error, :malformed}
      byte_size(bin) < total -> :incomplete
      true -> decode(bin, total, header_end, type, flags, serial)
    end
  end

  def decode(<<?l, _type, _flags, 1, _rest::binary>> = bin) when byte_size(bin) < 16,
    do: :incomplete

  def decode(bin) when byte_size(bin) < 4, do: :incomplete
  def decode(_bin), do: {:error, :malformed}

  defp decode(bin, total, header_end, type, flags, serial) do
    message = binary_part(bin, 0, total)
    rest = binary_part(bin, total, byte_size(bin) - total)

    with {type, _code} <- List.keyfind(@types, type, 1),
         {:ok, [fields], _at} <- Wire.decode("a(yv)", message, 12),
         header = header(fields),
         {:ok, body, ^total} <- Wire.decode(header[:signature] || "", message, header_end) do
      {:ok, struct!(__MODULE__, [type: type, flags: flags, serial: serial, body: body] ++ header),
       rest}
    else
      _other -> {:error, :malformed}
    end
  end

  defp header(fields) do
    for {code, value} <- fields,
        {key, {^code, _signature}} <- @fields,
        do: {key, value}
  end
end
