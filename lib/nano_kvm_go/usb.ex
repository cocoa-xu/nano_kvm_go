defmodule NanoKVMGo.USB do
  @gadget "/sys/kernel/config/usb_gadget/nanokvm"

  @moduledoc """
  The NanoKVM-Go's USB gadget, as its Nerves system sets it up at boot.

  The system makes the gadget `#{@gadget}` with a network (NCM) function and
  binds it to the device controller; a gadget library such as
  `Kuroneko.Gadget` adds the KVM functions. `gadget_options/1` gives such a
  library what this board needs:

    * the largest packets its USB controller (DWC3) takes: its smallest
      transmit FIFO holds 832 bytes of one, and its receive FIFO three of
      682
    * the names the target computer sees: "NanoKVM-Go Audio" and its
      directions, and the drive "NanoKVM Virtual Media"
    * the network function and its addresses

  The network's addresses stay the same from boot to boot, so that the
  computer keeps one network interface for the NanoKVM: the system gives it
  those in the U-Boot environment's `usbnet_devaddr` and `usbnet_hostaddr`,
  else addresses made from the serial number
  (`default_network_addresses/1`). `persist_network_addresses/2` puts new
  ones there, through `Nerves.Runtime.KV` or another module with its
  `put/1` (the `:kv` option).

      children = [
        {Kuroneko.Gadget, NanoKVMGo.USB.gadget_options() ++ [functions: [:keyboard, :mouse]]}
      ]

  The microphone and the speaker of the USB audio function play and record
  through `NanoKVMGo.Microphone` and `NanoKVMGo.Audio`.
  """
  import Bitwise

  alias NanoKVMGo.Options

  # The U-Boot variables the system reads the addresses from at boot
  # (U-Boot's own names).
  @address_variables %{device_address: "usbnet_devaddr", host_address: "usbnet_hostaddr"}

  @typedoc "A MAC address, such as `\"02:12:34:56:78:9a\"`."
  @type mac_address() :: String.t()

  @type network_addresses() :: %{device_address: mac_address(), host_address: mac_address()}

  @type option() :: {:serial_number, String.t() | nil} | {:kv, module()}

  @doc """
  The configfs directory of the gadget the NanoKVM-Go system sets up.
  """
  @spec gadget() :: Path.t()
  def gadget, do: @gadget

  @doc """
  The options of the gadget on this board, for `Kuroneko.Gadget`: `:gadget`,
  `:endpoints`, `:max_packet`, `:names` and `:network`. The AX620E's DWC3 has
  eight IN and eight OUT endpoints, seven of each besides endpoint 0.

  ## Options

    * `:serial_number` - what the default network addresses are made from,
      by default the board's (`boardid`'s); `nil` for no default addresses
    * `:kv` - the U-Boot environment, where the network addresses persist,
      `Nerves.Runtime.KV` by default
  """
  @spec gadget_options([option()]) :: keyword()
  def gadget_options(opts \\ []) do
    opts = Options.validate!(opts, [:serial_number, kv: Nerves.Runtime.KV], &valid?/2)
    serial_number = Keyword.get_lazy(opts, :serial_number, &serial_number/0)
    kv = opts[:kv]

    [
      gadget: @gadget,
      endpoints: %{in: 7, out: 7},
      max_packet: %{microphone: 832, speaker: 682},
      names: [
        audio: "NanoKVM-Go Audio",
        microphone: "NanoKVM-Go Microphone",
        speaker: "NanoKVM-Go Speaker",
        storage: {"NanoKVM", "Virtual Media", "0100"}
      ],
      network: [
        function: "ncm.usb0",
        default_addresses: serial_number && default_network_addresses(serial_number),
        persist: &persist_network_addresses(&1, kv: kv)
      ]
    ]
  end

  @doc """
  The addresses the NanoKVM-Go system gives the USB network when the U-Boot
  environment has none: the first six bytes of the SHA-256 of the serial
  number (`boardid`'s) for the NanoKVM's end and the next six for the
  computer's, as locally administered unicast addresses.

      iex> NanoKVMGo.USB.default_network_addresses("0123456789abcdef")
      %{device_address: "9e:9f:51:11:f7:b2", host_address: "7a:78:1f:1f:1d:dd"}
  """
  @spec default_network_addresses(String.t()) :: network_addresses()
  def default_network_addresses(serial_number) when is_binary(serial_number) do
    <<device::binary-6, host::binary-6, _rest::binary>> = :crypto.hash(:sha256, serial_number)
    %{device_address: local_address(device), host_address: local_address(host)}
  end

  @doc """
  Persists USB network addresses in the U-Boot environment, where the
  NanoKVM-Go system reads them at the next boots: `:device_address` (the
  NanoKVM's end), `:host_address` (the computer's), each an address or
  `:default` for the one made from the serial number.

  ## Options

    * `:kv` - the U-Boot environment, `Nerves.Runtime.KV` by default
  """
  @spec persist_network_addresses(
          %{optional(:device_address | :host_address) => mac_address() | :default},
          [{:kv, module()}]
        ) :: :ok | {:error, term()}
  def persist_network_addresses(addresses, opts \\ []) when is_map(addresses) do
    opts = Options.validate!(opts, [kv: Nerves.Runtime.KV], &valid?/2)

    variables =
      for {key, address} <- addresses, into: %{} do
        {Map.fetch!(@address_variables, key), if(address == :default, do: "", else: address)}
      end

    opts[:kv].put(variables)
  end

  defp local_address(<<first, rest::binary-5>>) do
    <<(first &&& 0xFC) ||| 0x02, rest::binary>>
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>, case: :lower))
  end

  # The serial number the NanoKVM-Go system makes the default addresses
  # from, as its shell takes it: without the newlines at the end.
  defp serial_number do
    with boardid when is_binary(boardid) <- System.find_executable("boardid"),
         {id, 0} <- System.cmd(boardid, []),
         id when id != "" <- String.trim_trailing(id, "\n") do
      id
    else
      _ -> nil
    end
  end

  defp valid?(:serial_number, serial_number),
    do: is_binary(serial_number) or is_nil(serial_number)

  defp valid?(:kv, kv), do: is_atom(kv)
end
