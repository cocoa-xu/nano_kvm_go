defmodule NanoKVMGo.Bluetooth.Adapter do
  @moduledoc false
  # BlueZ's controller hci0 and its devices over D-Bus, and the pairing
  # agent, which accepts pairing only while it is open. Calls that wait on
  # the other device (Pair, Connect) run in their own process: BlueZ may ask
  # the agent, served here, before it answers them.

  use GenServer

  require Logger

  alias NanoKVMGo.DBus

  @bluez "org.bluez"
  @adapter "/org/bluez/hci0"
  @agent "/nanokvmgo/agent"
  @adapter_iface "org.bluez.Adapter1"
  @device_iface "org.bluez.Device1"
  @properties "org.freedesktop.DBus.Properties"
  @object_manager "org.freedesktop.DBus.ObjectManager"
  @rejected "org.bluez.Error.Rejected"
  @retry_ms 250

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def info, do: GenServer.call(__MODULE__, :info)
  def devices, do: GenServer.call(__MODULE__, :devices)
  def open_pairing(seconds), do: GenServer.call(__MODULE__, {:open_pairing, seconds}, 30_000)
  def close_pairing, do: GenServer.call(__MODULE__, :close_pairing, 30_000)
  def scan(on?), do: GenServer.call(__MODULE__, {:scan, on?}, 30_000)
  def forget(address), do: GenServer.call(__MODULE__, {:forget, address}, 30_000)
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def device_call(address, method),
    do: GenServer.call(__MODULE__, {:device_call, address, method}, 90_000)

  @impl GenServer
  def init(opts) do
    state = %{
      bus: Keyword.fetch!(opts, :bus),
      name: Keyword.get_lazy(opts, :name, &hostname/0),
      adapter: nil,
      devices: %{},
      pairing: nil,
      subscribers: MapSet.new()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    :ok = DBus.subscribe(state.bus, sender: @bluez, interface: @object_manager)

    :ok =
      DBus.subscribe(state.bus,
        sender: @bluez,
        interface: @properties,
        member: "PropertiesChanged",
        path_namespace: "/org/bluez"
      )

    :ok = DBus.export(state.bus, @agent)
    {:noreply, load(state)}
  end

  @impl GenServer
  def handle_call(:info, _from, %{adapter: nil} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call(:info, _from, state), do: {:reply, {:ok, info(state)}, state}

  def handle_call(:devices, _from, state),
    do: {:reply, Enum.map(state.devices, &device/1), state}

  def handle_call({:open_pairing, seconds}, _from, state) do
    with :ok <- set(state, "Pairable", {"b", true}),
         :ok <- set(state, "DiscoverableTimeout", {"u", seconds}),
         :ok <- set(state, "Discoverable", {"b", true}) do
      if state.pairing, do: Process.cancel_timer(state.pairing)
      timer = Process.send_after(self(), :close_pairing, seconds * 1000)
      {:reply, :ok, notify_adapter(%{state | pairing: timer})}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:close_pairing, _from, state) do
    {result, state} = close(state)
    {:reply, result, state}
  end

  def handle_call({:scan, on?}, _from, state) do
    method = if on?, do: "StartDiscovery", else: "StopDiscovery"
    {:reply, adapter_call(state, method), state}
  end

  def handle_call({:forget, address}, _from, state) do
    case path_of(state, address) do
      nil -> {:reply, {:error, :unknown_device}, state}
      path -> {:reply, adapter_call(state, "RemoveDevice", "o", [path]), state}
    end
  end

  def handle_call({:device_call, address, method}, from, state) do
    case path_of(state, address) do
      nil ->
        {:reply, {:error, :unknown_device}, state}

      path ->
        bus = state.bus

        Task.start(fn ->
          GenServer.reply(
            from,
            ok(DBus.call(bus, @bluez, path, @device_iface, method, "", [], 80_000))
          )
        end)

        {:noreply, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_info(:load, state), do: {:noreply, load(state)}

  def handle_info(:close_pairing, state) do
    {_result, state} = close(%{state | pairing: nil})
    {:noreply, state}
  end

  def handle_info({:dbus_signal, message}, state), do: {:noreply, signal(state, message)}

  def handle_info({:dbus_method_call, %{path: @agent} = call}, state) do
    agent(state, call.member, call)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}

  defp load(state) do
    with {:ok, [objects]} <-
           DBus.call(state.bus, @bluez, "/", @object_manager, "GetManagedObjects"),
         %{@adapter_iface => adapter} <- Map.get(objects, @adapter),
         :ok <- setup(state) do
      devices = for {path, %{@device_iface => props}} <- objects, into: %{}, do: {path, props}
      Logger.info("nano_kvm_go: Bluetooth ready as #{state.name}")
      notify_adapter(%{state | adapter: adapter, devices: devices})
    else
      # bluetoothd starting, or the controller powering up (Busy)
      not_yet ->
        Logger.debug("nano_kvm_go: Bluetooth not ready: #{inspect(not_yet)}")
        Process.send_after(self(), :load, @retry_ms)
        %{state | adapter: nil}
    end
  end

  defp setup(state) do
    with :ok <- set(state, "Alias", {"s", state.name}),
         :ok <- set(state, "Powered", {"b", true}),
         :ok <- set(state, "Pairable", {"b", false}),
         :ok <- set(state, "Discoverable", {"b", false}),
         :ok <- agent_manager(state, "RegisterAgent", "os", [@agent, "NoInputNoOutput"]),
         do: agent_manager(state, "RequestDefaultAgent", "o", [@agent])
  end

  defp agent_manager(state, method, signature, args) do
    case DBus.call(
           state.bus,
           @bluez,
           "/org/bluez",
           "org.bluez.AgentManager1",
           method,
           signature,
           args
         ) do
      {:ok, _} -> :ok
      {:error, {"org.bluez.Error.AlreadyExists", _}} -> :ok
      error -> error
    end
  end

  defp close(state) do
    if state.pairing, do: Process.cancel_timer(state.pairing)
    state = %{state | pairing: nil}

    result =
      with :ok <- set(state, "Discoverable", {"b", false}),
           do: set(state, "Pairable", {"b", false})

    {result, notify_adapter(state)}
  end

  # The agent: NoInputNoOutput, so BlueZ asks only to authorize, and the
  # answer is yes while pairing is open.
  defp agent(state, member, call)
       when member in ["RequestAuthorization", "RequestConfirmation", "AuthorizeService"] do
    if state.pairing || paired?(state, hd(call.body)),
      do: DBus.reply(state.bus, call),
      else: DBus.error(state.bus, call, @rejected, "Pairing is not open")
  end

  defp agent(state, "RequestPinCode", call), do: legacy(state, call, "s", "0000")
  defp agent(state, "RequestPasskey", call), do: legacy(state, call, "u", 0)

  defp agent(state, member, call)
       when member in ["Release", "Cancel", "DisplayPasskey", "DisplayPinCode"],
       do: DBus.reply(state.bus, call)

  defp agent(state, _member, call),
    do: DBus.error(state.bus, call, @rejected, "Not supported")

  defp legacy(state, call, signature, answer) do
    if state.pairing,
      do: DBus.reply(state.bus, call, signature, [answer]),
      else: DBus.error(state.bus, call, @rejected, "Pairing is not open")
  end

  defp paired?(state, path), do: get_in(state.devices, [path, "Paired"]) == true

  defp signal(state, %{member: "InterfacesAdded", body: [path, interfaces]}) do
    cond do
      path == @adapter and is_map_key(interfaces, @adapter_iface) ->
        load(state)

      is_map_key(interfaces, @device_iface) ->
        update_device(state, path, interfaces[@device_iface])

      true ->
        state
    end
  end

  defp signal(state, %{member: "InterfacesRemoved", body: [path, interfaces]}) do
    cond do
      path == @adapter and @adapter_iface in interfaces ->
        %{state | adapter: nil}

      @device_iface in interfaces and is_map_key(state.devices, path) ->
        {props, devices} = Map.pop(state.devices, path)
        notify(state, {:device_removed, props["Address"]})
        %{state | devices: devices}

      true ->
        state
    end
  end

  defp signal(state, %{
         member: "PropertiesChanged",
         path: @adapter,
         body: [@adapter_iface, changed, _]
       })
       when state.adapter != nil,
       do: notify_adapter(%{state | adapter: Map.merge(state.adapter, changed)})

  defp signal(state, %{member: "PropertiesChanged", path: path, body: [@device_iface, changed, _]})
       when is_map_key(state.devices, path) do
    if changed["Paired"] == true and state.pairing,
      do: set(state, path, @device_iface, "Trusted", {"b", true})

    update_device(state, path, changed)
  end

  defp signal(state, _message), do: state

  defp update_device(state, path, changed) do
    props = Map.merge(Map.get(state.devices, path, %{}), changed)
    notify(state, {:device, device({path, props})})
    %{state | devices: Map.put(state.devices, path, props)}
  end

  defp notify_adapter(%{adapter: nil} = state), do: state

  defp notify_adapter(state) do
    notify(state, {:adapter, info(state)})
    state
  end

  defp notify(state, event) do
    for pid <- state.subscribers, do: send(pid, {NanoKVMGo.Bluetooth, event})
    :ok
  end

  defp info(state) do
    a = state.adapter

    %{
      name: a["Alias"],
      address: a["Address"],
      powered: a["Powered"] == true,
      discoverable: a["Discoverable"] == true,
      pairable: a["Pairable"] == true,
      discovering: a["Discovering"] == true,
      pairing: state.pairing != nil
    }
  end

  defp device({_path, props}) do
    %{
      address: props["Address"],
      name: props["Alias"] || props["Name"],
      icon: props["Icon"],
      paired: props["Paired"] == true,
      bonded: props["Bonded"] == true,
      trusted: props["Trusted"] == true,
      connected: props["Connected"] == true,
      rssi: props["RSSI"]
    }
  end

  defp path_of(state, address) do
    Enum.find_value(state.devices, fn {path, props} ->
      if props["Address"] == address, do: path
    end)
  end

  defp set(state, name, value), do: set(state, @adapter, @adapter_iface, name, value)

  defp set(state, path, interface, name, value),
    do:
      ok(DBus.call(state.bus, @bluez, path, @properties, "Set", "ssv", [interface, name, value]))

  defp adapter_call(state, method, signature \\ "", args \\ []),
    do: ok(DBus.call(state.bus, @bluez, @adapter, @adapter_iface, method, signature, args))

  defp ok({:ok, _body}), do: :ok
  defp ok({:error, _reason} = error), do: error

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
