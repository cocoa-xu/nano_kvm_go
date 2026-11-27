defmodule NanoKVMGo.Bluetooth do
  @moduledoc """
  Bluetooth through BlueZ: the controller in the board's AIC8800 Wi-Fi
  chip, its pairings and the devices it knows.

  The supervisor starts the system's D-Bus and bluetoothd, then talks to
  BlueZ over D-Bus. Pairings are kept on the data partition. Other devices
  pair only while pairing is open (`open_pairing/1`), so the KVM does not
  take a keyboard or a host that nobody let in.

      children = [NanoKVMGo.Bluetooth]

  Events go to the processes that `subscribe/0`, as
  `{NanoKVMGo.Bluetooth, event}`:

    * `{:adapter, info}` - `info/0` changed
    * `{:device, device}` - a device appeared or changed
    * `{:device_removed, address}` - a device was forgotten or went away

  `NanoKVMGo.Bluetooth.HID` makes the board a Bluetooth LE keyboard, mouse
  or other HID device.

  ## Options

    * `:name` - the name other devices see, the host name by default
  """

  use Supervisor

  alias NanoKVMGo.Bluetooth.Adapter

  @bus NanoKVMGo.Bluetooth.Bus
  @socket "/run/dbus/system_bus_socket"
  @storage "/data/bluetooth"
  @state_dir "/var/lib/bluetooth"

  @typedoc "A Bluetooth address, `\"AA:BB:CC:DD:EE:FF\"`."
  @type address() :: String.t()

  @type info() :: %{
          name: String.t(),
          address: address(),
          powered: boolean(),
          discoverable: boolean(),
          pairable: boolean(),
          discovering: boolean(),
          pairing: boolean()
        }

  @type device() :: %{
          address: address(),
          name: String.t() | nil,
          icon: String.t() | nil,
          paired: boolean(),
          bonded: boolean(),
          trusted: boolean(),
          connected: boolean(),
          rssi: integer() | nil
        }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    :ok = bind_storage()

    children = [
      daemon(:dbus, "dbus-daemon", ["--system", "--nofork", "--nopidfile"], []),
      {NanoKVMGo.DBus, name: @bus, path: @socket, wait: 5_000},
      daemon(:bluetoothd, "/usr/libexec/bluetooth/bluetoothd", ["-n"], []),
      {Adapter, Keyword.put(opts, :bus, @bus)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # BlueZ keeps its pairings in /var/lib/bluetooth, on the read-only root
  # file system: the data partition's directory goes there.
  defp bind_storage do
    File.mkdir_p!(@storage)
    File.chmod!(@storage, 0o700)

    if File.read!("/proc/mounts") =~ " #{@state_dir} " do
      :ok
    else
      case System.cmd("mount", ["-o", "bind", @storage, @state_dir], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, String.trim(output)}
      end
    end
  end

  defp daemon(id, command, args, opts) do
    Supervisor.child_spec(
      {MuonTrap.Daemon, [command, args, [log_output: :debug, stderr_to_stdout: true] ++ opts]},
      id: id
    )
  end

  @doc false
  @spec bus() :: atom()
  def bus, do: @bus

  @doc "The controller: its name, address and state."
  @spec info() :: {:ok, info()} | {:error, :not_ready}
  def info, do: Adapter.info()

  @doc "The devices BlueZ knows: paired ones and those seen while scanning."
  @spec devices() :: [device()]
  def devices, do: Adapter.devices()

  @doc """
  Lets other devices find the board and pair with it for `seconds`,
  2 minutes by default.
  """
  @spec open_pairing(pos_integer()) :: :ok | {:error, term()}
  def open_pairing(seconds \\ 120), do: Adapter.open_pairing(seconds)

  @spec close_pairing() :: :ok | {:error, term()}
  def close_pairing, do: Adapter.close_pairing()

  @doc "Starts or stops looking for devices, which show up in `devices/0`."
  @spec scan(boolean()) :: :ok | {:error, term()}
  def scan(on?), do: Adapter.scan(on?)

  @doc "Pairs with a device the board found, such as a keyboard."
  @spec pair(address()) :: :ok | {:error, term()}
  def pair(address), do: Adapter.device_call(address, "Pair")

  @spec connect(address()) :: :ok | {:error, term()}
  def connect(address), do: Adapter.device_call(address, "Connect")

  @spec disconnect(address()) :: :ok | {:error, term()}
  def disconnect(address), do: Adapter.device_call(address, "Disconnect")

  @doc "Forgets a device and its pairing."
  @spec forget(address()) :: :ok | {:error, term()}
  def forget(address), do: Adapter.forget(address)

  @spec subscribe() :: :ok
  def subscribe, do: Adapter.subscribe(self())
end
