defmodule NanoKVMGo.Bluetooth.HID do
  @moduledoc """
  The board as a Bluetooth LE HID device (HID over GATT): a keyboard, a
  mouse, a game controller, whatever its report descriptor says.

  It needs `NanoKVMGo.Bluetooth`. A computer, phone or tablet pairs with it
  from its Bluetooth settings while pairing is open
  (`NanoKVMGo.Bluetooth.open_pairing/1`); while it is, the board advertises
  as discoverable, and afterwards only to the hosts it knows.

      {NanoKVMGo.Bluetooth.HID,
       report_map: keyboard_and_mouse_descriptor,
       inputs: [keyboard: {1, 8}, mouse: {2, 7}],
       outputs: [leds: {1, 1}],
       appearance: 0x03C1}

      NanoKVMGo.Bluetooth.HID.report(:keyboard, <<0, 0, 4, 0, 0, 0, 0, 0>>)

  A report is the same bytes as over USB, without its report ID: the
  report ID is in the report's GATT descriptor. `with_report_id/2` gives a
  USB descriptor of one report a report ID, to combine several in one
  report map. Output reports (a keyboard's LEDs) go to the `:notify`
  process as `{NanoKVMGo.Bluetooth.HID, name, report}`.

  ## Options

    * `:report_map` - the HID report descriptor (required)
    * `:inputs`, `:outputs` - reports by name: `{report_id, length}`
    * `:appearance` - what hosts show it as: 0x03C0 a HID device (by
      default), 0x03C1 a keyboard, 0x03C2 a mouse, 0x03C4 a gamepad
    * `:pnp_id` - `{vendor_id_source, vendor_id, product_id, version}`, the
      source 1 for Bluetooth SIG IDs or 2 for USB-IF ones; by default
      BlueZ's, `{2, 0x1D6B, 0x0246, 0x0100}`
    * `:local_name` - the name it advertises, the host name by default
    * `:notify` - the process for output reports
    * `:name` - the name to register, `NanoKVMGo.Bluetooth.HID` by default
  """

  use GenServer

  require Logger

  alias NanoKVMGo.DBus

  @bluez "org.bluez"
  @adapter "/org/bluez/hci0"
  @root "/nanokvmgo/hid"
  @advertisement "/nanokvmgo/hidadv"

  @service "org.bluez.GattService1"
  @characteristic "org.bluez.GattCharacteristic1"
  @descriptor "org.bluez.GattDescriptor1"
  @advertisement_iface "org.bluez.LEAdvertisement1"
  @properties "org.freedesktop.DBus.Properties"
  @object_manager "org.freedesktop.DBus.ObjectManager"

  @input 1
  @output 2

  @retry_ms 1_000

  @type report_spec() :: {report_id :: 1..255, length :: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends an input report to the host, when one listens."
  @spec report(GenServer.server(), atom(), binary()) :: :ok
  def report(server \\ __MODULE__, name, report),
    do: GenServer.cast(server, {:report, name, report})

  @doc """
  Whether a host listens to the input reports: it subscribed to them, or a
  paired device is connected, which BlueZ remembers the subscriptions of.
  """
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__), do: GenServer.call(server, :connected?)

  @doc """
  Gives a descriptor of one report, as USB has it, a report ID: the Report
  ID item after its first application collection.
  """
  @spec with_report_id(binary(), 1..255) :: binary()
  def with_report_id(descriptor, id) do
    case :binary.match(descriptor, <<0xA1, 0x01>>) do
      {at, 2} ->
        split = at + 2

        <<binary_part(descriptor, 0, split)::binary, 0x85, id,
          binary_part(descriptor, split, byte_size(descriptor) - split)::binary>>

      :nomatch ->
        raise ArgumentError, "no application collection in the descriptor"
    end
  end

  @impl GenServer
  def init(opts) do
    bus = NanoKVMGo.Bluetooth.bus()
    inputs = Keyword.get(opts, :inputs, [])
    outputs = Keyword.get(opts, :outputs, [])

    state = %{
      bus: bus,
      notify: Keyword.get(opts, :notify),
      objects: objects(inputs, outputs),
      advertisement: advertisement(opts),
      values: values(opts, inputs, outputs),
      inputs: Map.new(inputs, fn {name, {id, _length}} -> {name, report_path(:input, id)} end),
      outputs: Map.new(outputs, fn {name, {id, _length}} -> {report_path(:output, id), name} end),
      notifying: MapSet.new(),
      hosts: connected_paired(),
      registered: false,
      discoverable: false
    }

    :ok = DBus.export(bus, @root)
    :ok = DBus.export(bus, @advertisement)
    :ok = NanoKVMGo.Bluetooth.subscribe()
    {:ok, state, {:continue, :register}}
  end

  @impl GenServer
  def handle_continue(:register, state) do
    register(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:connected?, _from, state),
    do: {:reply, MapSet.size(state.notifying) > 0 or MapSet.size(state.hosts) > 0, state}

  @impl GenServer
  def handle_cast({:report, name, report}, state) do
    case Map.fetch(state.inputs, name) do
      {:ok, path} ->
        # Not only after StartNotify: BlueZ restores the subscriptions of
        # bonded hosts when it starts, without a StartNotify for them.
        value_changed(state, path, report)
        {:noreply, put_in(state.values[path], report)}

      :error ->
        Logger.warning("nano_kvm_go: Bluetooth HID has no input report #{inspect(name)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:registered, :ok}, state) do
    Logger.info("nano_kvm_go: Bluetooth HID registered")
    {:noreply, %{state | registered: true}}
  end

  def handle_info({:registered, error}, state) do
    Logger.debug("nano_kvm_go: Bluetooth HID not registered yet: #{inspect(error)}")
    Process.send_after(self(), :register, @retry_ms)
    {:noreply, state}
  end

  def handle_info(:register, state) do
    register(state)
    {:noreply, state}
  end

  def handle_info({NanoKVMGo.Bluetooth, {:adapter, %{pairing: pairing}}}, state)
      when pairing != state.discoverable and state.registered do
    state = %{state | discoverable: pairing}
    readvertise(state)
    {:noreply, state}
  end

  def handle_info(
        {NanoKVMGo.Bluetooth, {:device, %{paired: true, connected: true} = device}},
        state
      ),
      do: {:noreply, %{state | hosts: MapSet.put(state.hosts, device.address)}}

  def handle_info({NanoKVMGo.Bluetooth, {:device, device}}, state),
    do: {:noreply, %{state | hosts: MapSet.delete(state.hosts, device.address)}}

  def handle_info({NanoKVMGo.Bluetooth, {:device_removed, address}}, state),
    do: {:noreply, %{state | hosts: MapSet.delete(state.hosts, address)}}

  def handle_info({NanoKVMGo.Bluetooth, _event}, state), do: {:noreply, state}

  def handle_info({:dbus_method_call, call}, state), do: {:noreply, method(state, call)}

  defp register(state) do
    bus = state.bus
    parent = self()

    # BlueZ reads the objects back before it answers: not from this process.
    Task.start(fn ->
      result =
        with :ok <- registered(bus, "org.bluez.GattManager1", "RegisterApplication", @root),
             do:
               registered(
                 bus,
                 "org.bluez.LEAdvertisingManager1",
                 "RegisterAdvertisement",
                 @advertisement
               )

      send(parent, {:registered, result})
    end)
  end

  defp registered(bus, interface, method, path) do
    case DBus.call(bus, @bluez, @adapter, interface, method, "oa{sv}", [path, %{}]) do
      {:ok, _} -> :ok
      {:error, {"org.bluez.Error.AlreadyExists", _}} -> :ok
      error -> error
    end
  end

  defp readvertise(state) do
    bus = state.bus
    manager = "org.bluez.LEAdvertisingManager1"

    Task.start(fn ->
      DBus.call(bus, @bluez, @adapter, manager, "UnregisterAdvertisement", "o", [@advertisement])

      DBus.call(bus, @bluez, @adapter, manager, "RegisterAdvertisement", "oa{sv}", [
        @advertisement,
        %{}
      ])
    end)
  end

  defp connected_paired do
    for device <- NanoKVMGo.Bluetooth.devices(),
        device.paired and device.connected,
        into: MapSet.new(),
        do: device.address
  end

  defp value_changed(state, path, value) do
    DBus.signal(state.bus, path, @properties, "PropertiesChanged", "sa{sv}as", [
      @characteristic,
      %{"Value" => {"ay", value}},
      []
    ])
  end

  defp method(
         state,
         %{interface: @object_manager, member: "GetManagedObjects", path: @root} = call
       ) do
    DBus.reply(state.bus, call, "a{oa{sa{sv}}}", [state.objects])
    state
  end

  defp method(state, %{interface: @object_manager, member: "GetManagedObjects"} = call) do
    DBus.reply(state.bus, call, "a{oa{sa{sv}}}", [
      %{@advertisement => %{@advertisement_iface => advertisement_props(state)}}
    ])

    state
  end

  defp method(state, %{interface: @properties, member: "GetAll", body: [interface]} = call) do
    DBus.reply(state.bus, call, "a{sv}", [props(state, call.path, interface)])
    state
  end

  defp method(state, %{interface: @properties, member: "Get", body: [interface, name]} = call) do
    case Map.fetch(props(state, call.path, interface), name) do
      {:ok, value} -> DBus.reply(state.bus, call, "v", [value])
      :error -> DBus.error(state.bus, call, "org.freedesktop.DBus.Error.InvalidArgs", name)
    end

    state
  end

  defp method(state, %{member: "ReadValue", body: [options]} = call)
       when is_map_key(state.values, call.path) do
    value = state.values[call.path]
    offset = min(Map.get(options, "offset", 0), byte_size(value))
    DBus.reply(state.bus, call, "ay", [binary_part(value, offset, byte_size(value) - offset)])
    state
  end

  defp method(
         state,
         %{interface: @characteristic, member: "WriteValue", body: [value, _opts]} = call
       ) do
    DBus.reply(state.bus, call)

    case Map.fetch(state.outputs, call.path) do
      {:ok, name} -> if state.notify, do: send(state.notify, {__MODULE__, name, value})
      :error -> :ok
    end

    if is_map_key(state.values, call.path),
      do: put_in(state.values[call.path], value),
      else: state
  end

  defp method(state, %{interface: @characteristic, member: "StartNotify"} = call) do
    DBus.reply(state.bus, call)
    %{state | notifying: MapSet.put(state.notifying, call.path)}
  end

  defp method(state, %{interface: @characteristic, member: "StopNotify"} = call) do
    DBus.reply(state.bus, call)
    %{state | notifying: MapSet.delete(state.notifying, call.path)}
  end

  defp method(state, %{interface: @advertisement_iface, member: "Release"} = call) do
    DBus.reply(state.bus, call)
    state
  end

  defp method(state, %{interface: "org.freedesktop.DBus.Introspectable"} = call) do
    DBus.reply(state.bus, call, "s", [~s(<node name="#{call.path}"/>)])
    state
  end

  defp method(state, call) do
    DBus.error(
      state.bus,
      call,
      "org.freedesktop.DBus.Error.UnknownMethod",
      "#{call.interface}.#{call.member}"
    )

    state
  end

  defp props(state, @advertisement, @advertisement_iface), do: advertisement_props(state)
  defp props(state, path, interface), do: get_in(state.objects, [path, interface]) || %{}

  defp advertisement_props(state),
    do: Map.put(state.advertisement, "Discoverable", {"b", state.discoverable})

  # The GATT database: the HID service, the battery and the PnP ID.
  defp objects(inputs, outputs) do
    hid = @root <> "/hid"
    battery = @root <> "/battery"
    device = @root <> "/device"

    reports =
      for {kind, reports} <- [input: inputs, output: outputs],
          {_name, {id, _length}} <- reports,
          object <- report_objects(hid, kind, id),
          do: object

    Map.new(
      [
        service(hid, 0x1812),
        characteristic(hid, "info", 0x2A4A, ["encrypt-read"]),
        characteristic(hid, "map", 0x2A4B, ["encrypt-read"]),
        characteristic(hid, "mode", 0x2A4E, ["encrypt-read", "write-without-response"]),
        characteristic(hid, "control", 0x2A4C, ["write-without-response"]),
        service(battery, 0x180F),
        characteristic(battery, "level", 0x2A19, ["read", "notify"]),
        service(device, 0x180A),
        characteristic(device, "pnp", 0x2A50, ["read"])
      ] ++ reports
    )
  end

  defp report_objects(hid, :input, id) do
    path = report_path(:input, id)

    [
      {path,
       %{@characteristic => chrc_props(hid, 0x2A4D, ["encrypt-read", "notify", "encrypt-notify"])}},
      descriptor(path, 0x2908, ["encrypt-read"])
    ]
  end

  defp report_objects(hid, :output, id) do
    path = report_path(:output, id)

    [
      {path,
       %{
         @characteristic =>
           chrc_props(hid, 0x2A4D, ["encrypt-read", "encrypt-write", "write-without-response"])
       }},
      descriptor(path, 0x2908, ["encrypt-read"])
    ]
  end

  defp values(opts, inputs, outputs) do
    {source, vendor, product, version} = Keyword.get(opts, :pnp_id, {2, 0x1D6B, 0x0246, 0x0100})

    reports =
      for {kind, type, reports} <- [{:input, @input, inputs}, {:output, @output, outputs}],
          {_name, {id, length}} <- reports,
          path = report_path(kind, id),
          pair <- [{path, <<0::size(length)-unit(8)>>}, {path <> "/ref", <<id, type>>}],
          do: pair

    Map.new(
      [
        # HID 1.11, no country, remote wake and normally connectable
        {@root <> "/hid/info", <<0x11, 0x01, 0x00, 0x03>>},
        {@root <> "/hid/map", Keyword.fetch!(opts, :report_map)},
        {@root <> "/hid/mode", <<1>>},
        {@root <> "/hid/control", <<0>>},
        {@root <> "/battery/level", <<100>>},
        {@root <> "/device/pnp",
         <<source, vendor::little-16, product::little-16, version::little-16>>}
      ] ++ reports
    )
  end

  defp advertisement(opts) do
    %{
      "Type" => {"s", "peripheral"},
      "ServiceUUIDs" => {"as", [uuid(0x1812)]},
      "Appearance" => {"q", Keyword.get(opts, :appearance, 0x03C0)},
      "LocalName" => {"s", Keyword.get_lazy(opts, :local_name, &hostname/0)}
    }
  end

  defp report_path(kind, id), do: "#{@root}/hid/#{kind}#{id}"

  defp service(path, uuid),
    do: {path, %{@service => %{"UUID" => {"s", uuid(uuid)}, "Primary" => {"b", true}}}}

  defp characteristic(service, name, uuid, flags),
    do: {"#{service}/#{name}", %{@characteristic => chrc_props(service, uuid, flags)}}

  defp chrc_props(service, uuid, flags) do
    %{"UUID" => {"s", uuid(uuid)}, "Service" => {"o", service}, "Flags" => {"as", flags}}
  end

  defp descriptor(characteristic, uuid, flags) do
    {characteristic <> "/ref",
     %{
       @descriptor => %{
         "UUID" => {"s", uuid(uuid)},
         "Characteristic" => {"o", characteristic},
         "Flags" => {"as", flags}
       }
     }}
  end

  defp uuid(short),
    do:
      "0000#{short |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")}-0000-1000-8000-00805f9b34fb"

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
