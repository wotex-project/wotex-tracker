defmodule Wotex.Tracker.UI.ProvisioningLive do
  @moduledoc """
  Presents target-specific TAT140 and ATC700 provisioning workflows.

  Cellular secrets remain only in the current LiveView while a plan is shown.
  The TAT140 path may additionally configure its associated EYE Sensor; the
  ATC700 path makes no BLE claim. EYE commands cross the closed mobile bridge
  one at a time and are admitted only when their request, phase, peripheral and
  characteristic match the current state. No result is persisted as proof of
  physical qualification.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components

  alias Wotex.Tracker.Protocols.Teltonika.{
    ATC700Configuration,
    EYESensorConfiguration,
    TAT140Configuration
  }

  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @ble_timeout_ms 30_000
  @scan_timeout_ms 10_000
  @sensor_names ~w(temperature humidity magnetic movement)

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       enrollment: nil,
       device: :tat140,
       plan: nil,
       error: nil,
       ble_state: :idle,
       ble_message: nil,
       ble_request: nil,
       ble_phase: nil,
       ble_peripherals: [],
       ble_peripheral: nil,
       ble_characteristics: [],
       ble_review: nil,
       ble_password: nil,
       ble_expected_mask: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket =
      socket
      |> reset_ble()
      |> assign(id: id, enrollment: nil, device: selected_device(params), plan: nil, error: nil)

    case Auth.request(socket, :get, %{"resource" => "enrollments", "id" => id}) do
      {:ok, %{"value" => enrollment}} -> {:noreply, assign(socket, enrollment: enrollment)}
      {:error, error} -> {:noreply, assign(socket, error: error)}
    end
  end

  @impl true
  def handle_event("select-device", %{"device" => %{"model" => model}}, socket)
      when model in ["tat140", "atc700"] do
    device = String.to_existing_atom(model)

    {:noreply,
     socket
     |> reset_ble()
     |> assign(device: device, plan: nil, error: nil)}
  end

  def handle_event("select-device", _, socket),
    do: {:noreply, assign(socket, plan: nil, error: %{"code" => "invalid_request"})}

  def handle_event("build-tat140-plan", %{"tat140" => input}, socket) when is_map(input) do
    with true <- socket.assigns.device == :tat140,
         true <- socket.assigns.identity["can_enroll"],
         {:ok, port} <- integer(input["port"]),
         {:ok, frequency} <- integer(input["update_frequency_seconds"]),
         {:ok, config} <-
           TAT140Configuration.new(tat140_configuration(input, port, frequency)) do
      plan = %{
        device: :tat140,
        commands: TAT140Configuration.endpoint_sms_commands(config),
        verification: [TAT140Configuration.endpoint_verification_sms(config)],
        expectations: TAT140Configuration.endpoint_expectations(config),
        manifest: TAT140Configuration.configurator_manifest(config)
      }

      {:noreply, assign(socket, plan: plan, error: nil)}
    else
      _ -> {:noreply, assign(socket, plan: nil, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("build-tat140-plan", _, socket),
    do: {:noreply, assign(socket, plan: nil, error: %{"code" => "invalid_request"})}

  def handle_event("clear-tat140-plan", _, socket),
    do: {:noreply, assign(socket, plan: nil, error: nil)}

  def handle_event("build-atc700-plan", %{"atc700" => input}, socket) when is_map(input) do
    with true <- socket.assigns.device == :atc700,
         true <- socket.assigns.identity["can_enroll"],
         {:ok, port} <- integer(input["port"]),
         {:ok, config} <- ATC700Configuration.new(atc700_configuration(input, port)) do
      plan = %{
        device: :atc700,
        commands: ATC700Configuration.endpoint_sms_commands(config),
        verification: [ATC700Configuration.endpoint_verification_sms(config)],
        expectations: ATC700Configuration.endpoint_expectations(config),
        manifest: ATC700Configuration.configurator_manifest(config)
      }

      {:noreply, assign(socket, plan: plan, error: nil)}
    else
      _ -> {:noreply, assign(socket, plan: nil, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("build-atc700-plan", _, socket),
    do: {:noreply, assign(socket, plan: nil, error: %{"code" => "invalid_request"})}

  def handle_event("clear-atc700-plan", _, socket),
    do: {:noreply, assign(socket, plan: nil, error: nil)}

  def handle_event("eye-scan", _, socket) do
    if socket.assigns.device == :tat140 and socket.assigns.identity["can_enroll"] do
      request = Identifier.uuid()

      socket =
        assign(socket,
          ble_peripherals: [],
          ble_peripheral: nil,
          ble_characteristics: [],
          ble_review: nil,
          ble_password: nil,
          ble_expected_mask: nil,
          ble_message: nil
        )

      {:noreply,
       dispatch(
         socket,
         :scanning,
         request,
         EYESensorConfiguration.scan_command(request, @scan_timeout_ms),
         @scan_timeout_ms
       )}
    else
      {:noreply, ble_unavailable(socket)}
    end
  end

  def handle_event("eye-connect", %{"peripheral" => peripheral}, socket) do
    if socket.assigns.device == :tat140 and socket.assigns.identity["can_enroll"] and
         Enum.any?(socket.assigns.ble_peripherals, &(&1["peripheral_id"] == peripheral)) do
      request = Identifier.uuid()

      {:noreply,
       socket
       |> assign(ble_peripheral: peripheral, ble_characteristics: [], ble_message: nil)
       |> dispatch(
         :connecting,
         request,
         EYESensorConfiguration.connect_command(request, peripheral)
       )}
    else
      {:noreply, ble_unavailable(socket, "Select an EYE Sensor from the current scan.")}
    end
  end

  def handle_event(
        "eye-prepare",
        %{"eye" => input},
        %{assigns: %{device: :tat140, ble_state: :ready}} = socket
      )
      when is_map(input) do
    sensors =
      for name <- @sensor_names, input[name] == "true", do: String.to_existing_atom(name)

    with password when is_binary(password) <- input["password"],
         true <- Regex.match?(~r/\A[0-9]{6}\z/, password),
         {:ok, mask} <- EYESensorConfiguration.sensor_mask(sensors) do
      {:noreply,
       assign(socket,
         ble_review: %{sensors: sensors, mask: mask},
         ble_password: password,
         ble_expected_mask: mask,
         ble_message: nil
       )}
    else
      _ ->
        {:noreply,
         ble_failure(
           socket,
           "Enter the EYE Sensor's six-digit PIN and a valid sensor selection.",
           :ready
         )}
    end
  end

  def handle_event("eye-prepare", _, socket),
    do:
      {:noreply,
       ble_failure(socket, "Connect and verify the EYE Sensor before preparing settings.")}

  def handle_event(
        "eye-apply",
        _,
        %{
          assigns: %{
            device: :tat140,
            ble_state: :ready,
            ble_review: %{mask: _},
            ble_password: password,
            ble_peripheral: peripheral
          }
        } = socket
      ) do
    request = Identifier.uuid()

    {:noreply,
     dispatch(
       socket,
       :authenticating,
       request,
       EYESensorConfiguration.authenticate_command(request, peripheral, password)
     )}
  end

  def handle_event("eye-apply", _, socket),
    do: {:noreply, ble_failure(socket, "Review valid EYE settings before applying them.")}

  def handle_event(
        "eye-disconnect",
        _,
        %{assigns: %{device: :tat140, ble_peripheral: peripheral}} = socket
      )
      when is_binary(peripheral) do
    request = Identifier.uuid()

    {:noreply,
     dispatch(
       clear_ble_secret(socket),
       :disconnecting,
       request,
       EYESensorConfiguration.disconnect_command(request, peripheral)
     )}
  end

  def handle_event("eye-disconnect", _, socket), do: {:noreply, socket}

  def handle_event("eye-ble-event", event, %{assigns: %{device: :tat140}} = socket)
      when is_map(event) do
    {:noreply, accept_ble_event(socket, event)}
  end

  def handle_event("eye-ble-event", _, socket),
    do: {:noreply, ble_failure(socket, "The native BLE bridge returned malformed data.")}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:eye_ble_timeout, request}, %{assigns: %{ble_request: request}} = socket),
    do: {:noreply, ble_failure(socket, "The native BLE operation timed out.")}

  def handle_info({:eye_ble_timeout, _}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace" phx-hook="TargetBLEHook">
      <a href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Target setup</p>
      <div class="heading">
        <h1>{if @enrollment, do: @enrollment["title"], else: "Asset unavailable"}</h1>
      </div>
      <.notice error={@error} />

      <section :if={@enrollment} class="panel" aria-labelledby="device-choice-title">
        <h2 id="device-choice-title">Choose the tracker being configured</h2>
        <form id="device-choice" phx-change="select-device">
          <label>Tracker model
          <select name="device[model]">
            <option value="tat140" selected={@device == :tat140}>Teltonika TAT140</option>
            <option value="atc700" selected={@device == :atc700}>Teltonika ATC700</option>
          </select></label>
        </form>
        <p class="muted">
          Each model has a separate bounded configuration contract. Selecting ATC700 does not
          enable or imply an EYE Sensor or another BLE gateway.
        </p>
      </section>

      <section
        :if={@enrollment && @device == :tat140}
        class="panel"
        aria-labelledby="tat140-title"
      >
        <h2 id="tat140-title">TAT140 endpoint and EYE gateway plan</h2>
        <p>
          The phone does not configure the TAT140 over BLE. Endpoint parameters use authenticated SMS.
          Codec 8 Extended and the EYE Sensor slot use Teltonika Configurator over USB.
        </p>
        <p class="notice">
          Generate this plan only for a TAT140 you control. Review the destination before sending SMS.
          Values and generated commands stay in this page only and are not saved by WoTEx.
        </p>
        <form :if={@identity["can_enroll"]} id="tat140-plan" phx-submit="build-tat140-plan">
          <fieldset>
            <legend>Authenticated SMS endpoint</legend>
            <label>SMS login <input name="tat140[sms_login]" maxlength="5" autocomplete="off" /></label>
            <label>SMS password
            <input
              name="tat140[sms_password]"
              type="password"
              maxlength="5"
              autocomplete="new-password"
            /></label>
            <label>Cellular APN <input name="tat140[apn]" value="internet" maxlength="32" required /></label>
            <label>APN username
            <input name="tat140[apn_username]" maxlength="32" autocomplete="off" /></label>
            <label>APN password
            <input
              name="tat140[apn_password]"
              type="password"
              maxlength="32"
              autocomplete="new-password"
            /></label>
            <label>Operator server
            <input name="tat140[server]" value="tracker.example" maxlength="55" required /></label>
            <label>TCP port
            <input name="tat140[port]" type="number" min="1" max="65535" value="5027" required /></label>
          </fieldset>
          <fieldset>
            <legend>USB Configurator selections</legend>
            <label>EYE Sensor MAC
            <input
              name="tat140[sensor_mac]"
              placeholder="AA:BB:CC:DD:EE:FF"
              pattern="[0-9A-F]{2}(:[0-9A-F]{2}){5}"
              required
            /></label>
            <label>BLE update frequency (seconds)
            <input
              name="tat140[update_frequency_seconds]"
              type="number"
              min="30"
              max="65535"
              value="60"
              required
            /></label>
            <label><input name="tat140[lost_sensor_alarm]" type="checkbox" value="true" checked />
            Enable lost-sensor alarm</label>
          </fieldset>
          <button type="submit">Generate local setup plan</button>
        </form>
        <p :if={!@identity["can_enroll"]} class="notice">
          This credential can inspect the setup path but cannot prepare hardware changes.
        </p>
      </section>

      <section
        :if={@enrollment && @device == :atc700}
        class="panel"
        aria-labelledby="atc700-title"
      >
        <h2 id="atc700-title">ATC700 SMS and TCT provisioning plan</h2>
        <p>
          ATC700 SMS authentication is password-only. The generated commands set the APN,
          operator-controlled TCP endpoint, Codec 8 Extended and AVL server confirmation.
        </p>
        <p class="notice">
          Generate this plan only for an ATC700 you control. Review the destination and the TCT
          selections before applying either path. Values and commands remain in this page only.
          This workflow makes no ATC700 BLE or physical-qualification claim.
        </p>
        <form :if={@identity["can_enroll"]} id="atc700-plan" phx-submit="build-atc700-plan">
          <fieldset>
            <legend>Password-only SMS and cellular endpoint</legend>
            <label>SMS password
            <input
              name="atc700[sms_password]"
              type="password"
              minlength="5"
              maxlength="10"
              pattern="[A-Za-z0-9]{5,10}"
              autocomplete="new-password"
            /></label>
            <label>Cellular APN <input name="atc700[apn]" value="internet" maxlength="32" required /></label>
            <label>APN username
            <input name="atc700[apn_username]" maxlength="32" autocomplete="off" /></label>
            <label>APN password
            <input
              name="atc700[apn_password]"
              type="password"
              maxlength="32"
              autocomplete="new-password"
            /></label>
            <label>Operator server
            <input name="atc700[server]" value="tracker.example" maxlength="55" required /></label>
            <label>TCP port
            <input name="atc700[port]" type="number" min="1" max="65535" value="5027" required /></label>
          </fieldset>
          <button type="submit">Generate ATC700 setup plan</button>
        </form>
        <p :if={!@identity["can_enroll"]} class="notice">
          This credential can inspect the setup path but cannot prepare hardware changes.
        </p>
      </section>

      <section :if={@plan} class="panel" aria-labelledby="plan-title">
        <h2 id="plan-title">Review the exact plan</h2>
        <h3>1. Send the SMS commands in order</h3>
        <ol>
          <li :for={command <- @plan.commands}><code>{command}</code></li>
        </ol>
        <h3>2. Read back non-secret configured fields</h3>
        <p :for={command <- @plan.verification}><code>{command}</code></p>
        <dl>
          <%= for {parameter, value} <- Enum.sort(@plan.expectations) do %>
            <dt>Parameter {parameter}</dt><dd>{value}</dd>
          <% end %>
        </dl>
        <h3>
          3. Connect over USB with {if @plan.device == :atc700,
            do: "Teltonika Configurator (TCT)",
            else: "Teltonika Configurator"}
        </h3>
        <dl :if={@plan.device == :tat140}>
          <dt>Data protocol</dt><dd>{@plan.manifest["system"]["data_protocol"]}</dd>
          <dt>BLE feature</dt><dd>{@plan.manifest["bluetooth"]["ble_feature"]}</dd>
          <dt>Sensor preset</dt><dd>{hd(@plan.manifest["bluetooth"]["sensor_table"])["preset"]}</dd>
          <dt>Sensor slot</dt><dd>{hd(@plan.manifest["bluetooth"]["sensor_table"])["slot"]}</dd>
          <dt>Sensor MAC</dt><dd>{hd(@plan.manifest["bluetooth"]["sensor_table"])["mac"]}</dd>
          <dt>Update frequency</dt><dd>
            {@plan.manifest["bluetooth"]["update_frequency_seconds"]} seconds
          </dd>
          <dt>Lost-sensor alarm</dt><dd>
            {if hd(@plan.manifest["bluetooth"]["sensor_table"])["lost_sensor_alarm"],
              do: "Enabled",
              else: "Disabled"}
          </dd>
        </dl>
        <dl :if={@plan.device == :atc700}>
          <dt>SMS authentication</dt><dd>
            {@plan.manifest["sms_call"]["sms_security"]["authentication"]}
          </dd>
          <dt>Auto APN</dt><dd>
            {@plan.manifest["mobile_network"]["mobile_data"]["auto_apn"]}
          </dd>
          <dt>APN</dt><dd>{@plan.manifest["mobile_network"]["mobile_data"]["apn"]}</dd>
          <dt>APN username</dt><dd>
            {@plan.manifest["mobile_network"]["mobile_data"]["apn_username"]}
          </dd>
          <dt>Primary server</dt><dd>
            {@plan.manifest["mobile_network"]["primary_server"]["domain"]}:{@plan.manifest[
              "mobile_network"
            ]["primary_server"]["port"]}
          </dd>
          <dt>Transport</dt><dd>
            {@plan.manifest["mobile_network"]["primary_server"]["data_protocol"]}
          </dd>
          <dt>Data protocol</dt><dd>
            {@plan.manifest["tracking"]["records"]["data_protocol"]}
          </dd>
          <dt>Server confirmation</dt><dd>
            {@plan.manifest["tracking"]["records"]["server_confirmation_method"]}
          </dd>
        </dl>
        <button
          :if={@plan.device == :tat140}
          class="secondary"
          phx-click="clear-tat140-plan"
        >
          Clear sensitive plan
        </button>
        <button
          :if={@plan.device == :atc700}
          class="secondary"
          phx-click="clear-atc700-plan"
        >
          Clear sensitive plan
        </button>
      </section>

      <section
        :if={@enrollment && @device == :tat140}
        class="panel"
        aria-labelledby="eye-title"
      >
        <h2 id="eye-title">Associated EYE Sensor</h2>
        <p>
          In the iOS companion, configure the EYE Sensor directly through its documented GATT service.
          This verifies the associated sensor component; it does not pair the phone with the TAT140.
        </p>
        <p role="status">{ble_status(@ble_state, @ble_message)}</p>
        <button
          :if={@identity["can_enroll"] && @ble_state in [:idle, :failed, :disconnected, :verified]}
          phx-click="eye-scan"
        >
          Scan for EYE Sensors
        </button>
        <ul :if={@ble_peripherals != []} aria-label="Discovered EYE Sensors">
          <li :for={peripheral <- @ble_peripherals}>
            {peripheral["name"] || "Unnamed EYE Sensor"} · signal {peripheral["rssi"]} dBm
            <button
              class="secondary"
              phx-click="eye-connect"
              phx-value-peripheral={peripheral["peripheral_id"]}
            >
              Connect
            </button>
          </li>
        </ul>

        <form
          :if={@ble_state == :ready && @identity["can_enroll"]}
          id="eye-settings"
          phx-submit="eye-prepare"
        >
          <fieldset>
            <legend>EYE Sensor settings</legend>
            <label>Six-digit PIN
            <input
              name="eye[password]"
              type="password"
              inputmode="numeric"
              pattern="[0-9]{6}"
              minlength="6"
              maxlength="6"
              autocomplete="off"
              required
            /></label>
            <label><input name="eye[temperature]" type="checkbox" value="true" checked /> Temperature</label>
            <label><input name="eye[humidity]" type="checkbox" value="true" checked /> Humidity</label>
            <label><input name="eye[magnetic]" type="checkbox" value="true" checked /> Magnetic state</label>
            <label><input name="eye[movement]" type="checkbox" value="true" checked /> Movement</label>
          </fieldset>
          <button type="submit">Review EYE settings</button>
        </form>

        <div :if={@ble_review && @ble_state == :ready} id="eye-review" class="operation">
          <p>
            Write sensor mask <code>{@ble_review.mask}</code>
            ({Enum.map_join(@ble_review.sensors, ", ", &Atom.to_string/1)}),
            issue the documented write-to-flash command, then read the mask back.
          </p>
          <button phx-click="eye-apply">Apply and verify on EYE Sensor</button>
        </div>
        <button :if={is_binary(@ble_peripheral)} class="secondary" phx-click="eye-disconnect">
          Disconnect EYE Sensor
        </button>
        <p class="muted">
          Local success proves only that the native bridge completed the documented request sequence.
          Physical radio, firmware and installation qualification remain separate evidence.
        </p>
      </section>
    </main>
    """
  end

  defp tat140_configuration(input, port, frequency) do
    %{
      "schema" => "wtr.tat140-configuration.v1",
      "provisioning_path" => "teltonika_configurator_usb",
      "sms" => %{"login" => input["sms_login"] || "", "password" => input["sms_password"] || ""},
      "cellular" => %{
        "apn" => input["apn"],
        "username" => input["apn_username"] || "",
        "password" => input["apn_password"] || "",
        "server" => input["server"],
        "port" => port,
        "transport" => "tcp"
      },
      "protocol" => %{"data" => "codec8_extended"},
      "ble" => %{
        "feature" => "sensors",
        "sensor" => "eye_sensor",
        "slot" => 1,
        "mac" => input["sensor_mac"],
        "update_frequency_seconds" => frequency,
        "lost_sensor_alarm" => input["lost_sensor_alarm"] == "true"
      }
    }
  end

  defp atc700_configuration(input, port) do
    %{
      "schema" => "wtr.atc700-configuration.v1",
      "provisioning_path" => "sms_and_teltonika_configurator_tct",
      "sms" => %{"password" => input["sms_password"] || ""},
      "cellular" => %{
        "apn" => input["apn"],
        "username" => input["apn_username"] || "",
        "password" => input["apn_password"] || "",
        "server" => input["server"],
        "port" => port,
        "transport" => "tcp"
      },
      "protocol" => %{
        "data" => "codec8_extended",
        "server_confirmation" => "avl"
      }
    }
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp integer(_), do: {:error, :invalid_integer}

  defp selected_device(%{"device" => "atc700"}), do: :atc700
  defp selected_device(_), do: :tat140

  defp dispatch(socket, state, request, command, timeout \\ @ble_timeout_ms)

  defp dispatch(socket, state, request, {:ok, command}, timeout) do
    Process.send_after(self(), {:eye_ble_timeout, request}, timeout)

    socket
    |> assign(ble_state: state, ble_request: request, ble_phase: state, ble_message: nil)
    |> push_event("eye-ble-command", command)
  end

  defp dispatch(socket, _, _, _, _),
    do: ble_failure(socket, "The target BLE command could not be constructed.")

  defp accept_ble_event(socket, event) do
    request = event["request_id"]

    case EYESensorConfiguration.decode_event(event) do
      {:ok, %{"event" => "disconnected", "data" => %{"peripheral_id" => peripheral}}}
      when peripheral == socket.assigns.ble_peripheral ->
        socket
        |> clear_ble_secret()
        |> assign(
          ble_state: :disconnected,
          ble_request: nil,
          ble_phase: nil,
          ble_peripheral: nil,
          ble_characteristics: [],
          ble_message: "The EYE Sensor disconnected before another operation."
        )

      {:ok, decoded} when request == socket.assigns.ble_request ->
        accept_current_event(socket, decoded)

      {:ok, _stale} ->
        socket

      {:error, :invalid_event} when request == socket.assigns.ble_request ->
        ble_failure(socket, "The native BLE bridge returned malformed target data.")

      {:error, :invalid_event} ->
        socket
    end
  end

  defp accept_current_event(socket, %{"event" => "scan_result", "data" => peripheral})
       when socket.assigns.ble_phase == :scanning do
    peripherals =
      [peripheral | socket.assigns.ble_peripherals]
      |> Enum.uniq_by(& &1["peripheral_id"])
      |> Enum.sort_by(& &1["peripheral_id"])

    assign(socket, ble_state: :found, ble_peripherals: peripherals)
  end

  defp accept_current_event(socket, %{"event" => "scan_complete"})
       when socket.assigns.ble_phase == :scanning do
    if socket.assigns.ble_peripherals == [] do
      ble_failure(socket, "No EYE Sensor exposed the documented configuration service.")
    else
      assign(socket, ble_state: :found, ble_request: nil, ble_phase: nil)
    end
  end

  defp accept_current_event(socket, %{
         "event" => "connected",
         "data" => %{"peripheral_id" => peripheral}
       })
       when socket.assigns.ble_phase == :connecting and
              peripheral == socket.assigns.ble_peripheral do
    request = Identifier.uuid()

    dispatch(
      socket,
      :discovering,
      request,
      EYESensorConfiguration.discover_command(request, peripheral)
    )
  end

  defp accept_current_event(socket, %{"event" => "services"})
       when socket.assigns.ble_phase == :discovering,
       do: socket

  defp accept_current_event(socket, %{
         "event" => "characteristics",
         "data" => %{"peripheral_id" => peripheral} = data
       })
       when socket.assigns.ble_phase == :discovering and
              peripheral == socket.assigns.ble_peripheral do
    characteristics =
      data["characteristics"]
      |> Enum.map(& &1["uuid"])
      |> Kernel.++(socket.assigns.ble_characteristics)
      |> Enum.uniq()
      |> Enum.sort()

    assign(socket, ble_characteristics: characteristics)
  end

  defp accept_current_event(socket, %{"event" => "discovery_complete"})
       when socket.assigns.ble_phase == :discovering do
    if Enum.all?(
         EYESensorConfiguration.required_characteristics(),
         &(&1 in socket.assigns.ble_characteristics)
       ) do
      assign(socket,
        ble_state: :ready,
        ble_request: nil,
        ble_phase: nil,
        ble_message:
          "The documented password, sensor-mask and save characteristics are available."
      )
    else
      ble_failure(
        socket,
        "The connected peripheral does not expose the complete EYE configuration surface."
      )
    end
  end

  defp accept_current_event(socket, %{"event" => "written"})
       when socket.assigns.ble_phase == :authenticating do
    request = Identifier.uuid()

    socket
    |> assign(ble_password: nil)
    |> dispatch(
      :writing_sensor_mask,
      request,
      EYESensorConfiguration.sensor_mask_command(
        request,
        socket.assigns.ble_peripheral,
        socket.assigns.ble_review.sensors
      )
    )
  end

  defp accept_current_event(socket, %{"event" => "written"})
       when socket.assigns.ble_phase == :writing_sensor_mask do
    request = Identifier.uuid()

    dispatch(
      socket,
      :saving,
      request,
      EYESensorConfiguration.save_command(request, socket.assigns.ble_peripheral)
    )
  end

  defp accept_current_event(socket, %{"event" => "written"})
       when socket.assigns.ble_phase == :saving do
    request = Identifier.uuid()

    dispatch(
      socket,
      :verifying,
      request,
      EYESensorConfiguration.read_sensor_mask_command(request, socket.assigns.ble_peripheral)
    )
  end

  defp accept_current_event(socket, %{"event" => "value", "data" => %{"value" => value}})
       when socket.assigns.ble_phase == :verifying do
    case EYESensorConfiguration.decode_sensor_mask(value) do
      {:ok, %{mask: mask}} when mask == socket.assigns.ble_expected_mask ->
        socket
        |> clear_ble_secret()
        |> assign(
          ble_state: :verified,
          ble_request: nil,
          ble_phase: nil,
          ble_review: nil,
          ble_message:
            "EYE Sensor settings were written, saved and read back in this local session."
        )

      {:ok, _} ->
        ble_failure(socket, "The EYE Sensor read-back did not match the reviewed sensor mask.")

      {:error, _} ->
        ble_failure(socket, "The EYE Sensor returned a malformed sensor mask.")
    end
  end

  defp accept_current_event(socket, %{"event" => event, "data" => %{"reason" => reason}})
       when event in ~w(rejected connect_failed operation_failed),
       do: ble_failure(socket, ble_reason(reason))

  defp accept_current_event(socket, _),
    do: ble_failure(socket, "The native BLE event was out of order for this target workflow.")

  defp clear_ble_secret(socket),
    do: assign(socket, ble_password: nil, ble_expected_mask: nil)

  defp reset_ble(socket) do
    assign(socket,
      ble_state: :idle,
      ble_message: nil,
      ble_request: nil,
      ble_phase: nil,
      ble_peripherals: [],
      ble_peripheral: nil,
      ble_characteristics: [],
      ble_review: nil,
      ble_password: nil,
      ble_expected_mask: nil
    )
  end

  defp ble_unavailable(%{assigns: %{device: :atc700}} = socket, _message),
    do: assign(socket, error: %{"code" => "invalid_request"})

  defp ble_unavailable(socket, message), do: ble_failure(socket, message)

  defp ble_unavailable(socket),
    do: ble_unavailable(socket, "This credential cannot provision local hardware.")

  defp ble_failure(socket, message, state \\ :failed) do
    socket
    |> clear_ble_secret()
    |> assign(ble_state: state, ble_request: nil, ble_phase: nil, ble_message: message)
  end

  defp ble_status(:idle, _), do: "No local EYE Sensor operation is active."
  defp ble_status(:scanning, _), do: "Scanning for the documented EYE configuration service…"
  defp ble_status(:found, _), do: "Select one EYE Sensor from this scan."
  defp ble_status(:connecting, _), do: "Connecting to the selected EYE Sensor…"
  defp ble_status(:discovering, _), do: "Checking the EYE Sensor's documented characteristics…"

  defp ble_status(:ready, message),
    do: message || "EYE Sensor ready for a reviewed settings write."

  defp ble_status(:authenticating, _), do: "Authenticating with the EYE Sensor…"
  defp ble_status(:writing_sensor_mask, _), do: "Writing the reviewed sensor mask…"
  defp ble_status(:saving, _), do: "Saving EYE Sensor settings to flash…"
  defp ble_status(:verifying, _), do: "Reading the sensor mask back…"
  defp ble_status(:disconnecting, _), do: "Disconnecting from the EYE Sensor…"
  defp ble_status(:verified, message), do: message
  defp ble_status(:disconnected, message), do: message
  defp ble_status(:failed, message), do: message

  defp ble_reason("unauthorized"),
    do: "Bluetooth permission was denied. Allow Bluetooth access in iOS Settings."

  defp ble_reason("powered_off"),
    do: "Bluetooth is powered off. Turn it on before scanning again."

  defp ble_reason("unsupported"),
    do: "This device does not provide the required BLE central capability."

  defp ble_reason("not_connected"),
    do: "The EYE Sensor disconnected before the operation completed."

  defp ble_reason("invalid_data"), do: "The native bridge rejected malformed EYE Sensor data."
  defp ble_reason("busy"), do: "Another BLE operation is active. Wait for it to finish."

  defp ble_reason("not_found"),
    do: "The requested EYE Sensor or characteristic is no longer available."

  defp ble_reason(_), do: "The native BLE operation is unavailable."
end
