defmodule Wotex.Tracker.UI.RuleForm do
  @moduledoc """
  Renders and admits the browser fields for managed tracking rules.

  Operators enter whole seconds and volts. Admission converts them to the
  service's closed millisecond and threshold parameters, or rejects them without
  contacting the service. The service still validates and evaluates every rule.
  Only a numeric `batteryVoltage` Property in volts can back a battery rule.
  Motion and geofence fields preserve the service's complete ordering and
  uncertainty choices; polygon vertices use one `latitude,longitude` pair per
  line.
  """

  use Phoenix.Component

  @maximum_seconds 604_800
  @order_event_times ~w(trusted_fix trusted_fix_or_receiver)
  @sequences ~w(none optional required)
  @uncertainties ~w(require_bound coordinate_only)
  @motion_fields ~w(event_time future_skew_ms late_window_ms sequence moving_speed_m_s stationary_speed_m_s moving_distance_m stationary_distance_m max_plausible_speed_m_s max_gap_ms uncertainty minimum_movement_ms minimum_stop_ms)
  @geofence_fields ~w(shape boundary uncertainty event_time future_skew_ms late_window_ms sequence max_transition_gap_ms)

  @doc "Converts submitted fields for one kind into closed service parameters."
  @spec parameters(term(), term()) :: {:ok, map()} | :error
  def parameters("heartbeat", %{} = input) do
    with {:ok, skew} <- milliseconds(input["future_skew_seconds"]),
         {:ok, silence} <- milliseconds(input["maximum_silence_seconds"]),
         do: {:ok, %{"maximum_silence_ms" => silence, "future_skew_ms" => skew}}
  end

  def parameters("battery", %{} = input) do
    with {:ok, skew} <- milliseconds(input["future_skew_seconds"]),
         {:ok, low} <- volts(input["low_threshold"]),
         {:ok, clear} <- volts(input["clear_threshold"]),
         true <- low < clear,
         {:ok, age} <- milliseconds(input["maximum_age_seconds"]),
         true <- input["accept_suspect"] in [nil, "true"] do
      {:ok,
       %{
         "measurement_kind" => "batteryVoltage",
         "unit" => "V",
         "low_threshold" => low,
         "clear_threshold" => clear,
         "maximum_age_ms" => age,
         "future_skew_ms" => skew,
         "accept_suspect" => input["accept_suspect"] == "true"
       }}
    else
      _ -> :error
    end
  end

  def parameters("motion", %{} = input) do
    with {:ok, ordering} <- ordering(input),
         {:ok, moving_speed} <- number(input["moving_speed_m_s"], 0, 1_000_000),
         {:ok, stationary_speed} <- number(input["stationary_speed_m_s"], 0, moving_speed),
         {:ok, moving_distance} <- number(input["moving_distance_m"], 0, 1_000_000),
         {:ok, stationary_distance} <- number(input["stationary_distance_m"], 0, moving_distance),
         {:ok, plausible_speed} <-
           number(input["max_plausible_speed_m_s"], moving_speed, 1_000_000),
         {:ok, gap} <- milliseconds(input["max_gap_seconds"]),
         {:ok, movement} <- positive_milliseconds(input["minimum_movement_seconds"]),
         {:ok, stop} <- positive_milliseconds(input["minimum_stop_seconds"]) do
      {:ok,
       Map.merge(ordering, %{
         "moving_speed_m_s" => moving_speed,
         "stationary_speed_m_s" => stationary_speed,
         "moving_distance_m" => moving_distance,
         "stationary_distance_m" => stationary_distance,
         "max_plausible_speed_m_s" => plausible_speed,
         "max_gap_ms" => gap,
         "minimum_movement_ms" => movement,
         "minimum_stop_ms" => stop
       })}
    else
      _ -> :error
    end
  end

  def parameters("geofence", %{} = input) do
    with {:ok, ordering} <- ordering(input),
         {:ok, shape} <- shape(input),
         true <- input["boundary"] in ~w(inside outside),
         {:ok, gap} <- milliseconds(input["max_transition_gap_seconds"]) do
      {:ok,
       Map.merge(ordering, %{
         "shape" => shape,
         "boundary" => input["boundary"],
         "max_transition_gap_ms" => gap
       })}
    else
      _ -> :error
    end
  end

  def parameters(_, _), do: :error

  @doc "Reports whether stored parameters round-trip through these fields without change."
  @spec editable?(term(), term()) :: boolean()
  def editable?("heartbeat", %{} = parameters),
    do: whole_seconds?([parameters["maximum_silence_ms"], parameters["future_skew_ms"]])

  def editable?("battery", %{"measurement_kind" => "batteryVoltage", "unit" => "V"} = parameters),
    do: whole_seconds?([parameters["maximum_age_ms"], parameters["future_skew_ms"]])

  def editable?("motion", %{} = parameters) do
    exact?(parameters, @motion_fields) and ordering?(parameters) and
      whole_seconds?([
        parameters["max_gap_ms"],
        parameters["minimum_movement_ms"],
        parameters["minimum_stop_ms"]
      ]) and
      Enum.all?(
        ~w(moving_speed_m_s stationary_speed_m_s moving_distance_m stationary_distance_m max_plausible_speed_m_s),
        &is_number(parameters[&1])
      )
  end

  def editable?("geofence", %{} = parameters) do
    exact?(parameters, @geofence_fields) and ordering?(parameters) and
      parameters["boundary"] in ~w(inside outside) and shape?(parameters["shape"]) and
      whole_seconds?([parameters["max_transition_gap_ms"]])
  end

  def editable?(_, _), do: false

  @doc "Reports whether a Thing Description can back a battery-voltage rule."
  @spec battery?(term()) :: boolean()
  def battery?(%{"properties" => %{"batteryVoltage" => %{"type" => "number", "unit" => "V"}}}),
    do: true

  def battery?(_), do: false

  attr(:kinds, :list, required: true)
  attr(:parameters, :map, default: %{})

  @doc "Renders the fields for the selected rule kinds, prefilled from stored parameters."
  def fields(assigns) do
    assigns = assign(assigns, :maximum, @maximum_seconds)

    ~H"""
    <fieldset :if={kind_enabled?(@kinds, "heartbeat")}>
      <legend>Reporting heartbeat</legend>
      <label for="rule-silence">Maximum silence (seconds)</label>
      <input
        id="rule-silence"
        name="rule[maximum_silence_seconds]"
        type="number"
        min="0"
        max={@maximum}
        value={seconds(@parameters["maximum_silence_ms"], 3_600)}
      />
    </fieldset>
    <fieldset :if={kind_enabled?(@kinds, "battery")}>
      <legend>Low battery voltage</legend>
      <label for="rule-low">Low at or below (V)</label>
      <input
        id="rule-low"
        name="rule[low_threshold]"
        type="text"
        inputmode="decimal"
        value={@parameters["low_threshold"] || 2.5}
      />
      <label for="rule-clear">Recovered at or above (V)</label>
      <input
        id="rule-clear"
        name="rule[clear_threshold]"
        type="text"
        inputmode="decimal"
        value={@parameters["clear_threshold"] || 2.8}
      />
      <label for="rule-age">Maximum reading age (seconds)</label>
      <input
        id="rule-age"
        name="rule[maximum_age_seconds]"
        type="number"
        min="0"
        max={@maximum}
        value={seconds(@parameters["maximum_age_ms"], 86_400)}
      />
      <label class="checkbox">
        <input
          type="checkbox"
          name="rule[accept_suspect]"
          value="true"
          checked={@parameters["accept_suspect"] == true}
        /> Accept readings marked suspect
      </label>
    </fieldset>
    <fieldset :if={kind_enabled?(@kinds, "motion")}>
      <legend>Motion and trips</legend>
      <label for="rule-moving-speed">Moving speed at or above (m/s)</label>
      <input
        id="rule-moving-speed"
        name="rule[moving_speed_m_s]"
        type="text"
        inputmode="decimal"
        value={value(@parameters["moving_speed_m_s"], 1.0)}
      />
      <label for="rule-stationary-speed">Stationary speed at or below (m/s)</label>
      <input
        id="rule-stationary-speed"
        name="rule[stationary_speed_m_s]"
        type="text"
        inputmode="decimal"
        value={value(@parameters["stationary_speed_m_s"], 0.1)}
      />
      <label for="rule-moving-distance">Moving distance at or above (m)</label>
      <input
        id="rule-moving-distance"
        name="rule[moving_distance_m]"
        type="text"
        inputmode="decimal"
        value={value(@parameters["moving_distance_m"], 5.0)}
      />
      <label for="rule-stationary-distance">Stationary distance at or below (m)</label>
      <input
        id="rule-stationary-distance"
        name="rule[stationary_distance_m]"
        type="text"
        inputmode="decimal"
        value={value(@parameters["stationary_distance_m"], 1.0)}
      />
      <label for="rule-plausible-speed">Maximum plausible speed (m/s)</label>
      <input
        id="rule-plausible-speed"
        name="rule[max_plausible_speed_m_s]"
        type="text"
        inputmode="decimal"
        value={value(@parameters["max_plausible_speed_m_s"], 100.0)}
      />
      <label for="rule-motion-gap">Maximum segment gap (seconds)</label>
      <input
        id="rule-motion-gap"
        name="rule[max_gap_seconds]"
        type="number"
        min="0"
        max={@maximum}
        value={seconds(@parameters["max_gap_ms"], 300)}
      />
      <label for="rule-movement-dwell">Movement confirmation dwell (seconds)</label>
      <input
        id="rule-movement-dwell"
        name="rule[minimum_movement_seconds]"
        type="number"
        min="1"
        max={@maximum}
        value={seconds(@parameters["minimum_movement_ms"], 30)}
      />
      <label for="rule-stop-dwell">Stop confirmation dwell (seconds)</label>
      <input
        id="rule-stop-dwell"
        name="rule[minimum_stop_seconds]"
        type="number"
        min="1"
        max={@maximum}
        value={seconds(@parameters["minimum_stop_ms"], 60)}
      />
    </fieldset>
    <fieldset :if={kind_enabled?(@kinds, "geofence")}>
      <legend>Geofence</legend>
      <label for="rule-shape">Fence shape</label>
      <select id="rule-shape" name="rule[shape_kind]">
        <option value="circle" selected={shape_kind(@parameters) == "circle"}>Circle</option>
        <option value="polygon" selected={shape_kind(@parameters) == "polygon"}>Polygon</option>
      </select>
      <label for="rule-latitude">Circle centre latitude</label>
      <input
        id="rule-latitude"
        name="rule[latitude]"
        type="text"
        inputmode="decimal"
        value={shape_value(@parameters, "latitude")}
      />
      <label for="rule-longitude">Circle centre longitude</label>
      <input
        id="rule-longitude"
        name="rule[longitude]"
        type="text"
        inputmode="decimal"
        value={shape_value(@parameters, "longitude")}
      />
      <label for="rule-radius">Circle radius (m)</label>
      <input
        id="rule-radius"
        name="rule[radius_m]"
        type="text"
        inputmode="decimal"
        value={shape_value(@parameters, "radius_m", 100.0)}
      />
      <label for="rule-vertices">Polygon vertices (one latitude,longitude pair per line)</label>
      <textarea id="rule-vertices" name="rule[vertices]">{vertices(@parameters)}</textarea>
      <label for="rule-boundary">Exact boundary counts as</label>
      <select id="rule-boundary" name="rule[boundary]">
        <option value="inside" selected={value(@parameters["boundary"], "inside") == "inside"}>
          Inside
        </option>
        <option value="outside" selected={@parameters["boundary"] == "outside"}>Outside</option>
      </select>
      <label for="rule-transition-gap">Maximum transition gap (seconds)</label>
      <input
        id="rule-transition-gap"
        name="rule[max_transition_gap_seconds]"
        type="number"
        min="0"
        max={@maximum}
        value={seconds(@parameters["max_transition_gap_ms"], 300)}
      />
    </fieldset>
    <fieldset :if={position_fields?(@kinds)}>
      <legend>Position ordering and uncertainty</legend>
      <label for="rule-event-time">Event time</label>
      <select id="rule-event-time" name="rule[event_time]">
        <option value="trusted_fix" selected={event_time(@parameters) == "trusted_fix"}>
          Require trusted fix time
        </option>
        <option
          value="trusted_fix_or_receiver"
          selected={event_time(@parameters) == "trusted_fix_or_receiver"}
        >
          Use receiver time only when fix time is missing
        </option>
      </select>
      <label for="rule-late-window">Late-arrival window (seconds)</label>
      <input
        id="rule-late-window"
        name="rule[late_window_seconds]"
        type="number"
        min="0"
        max={@maximum}
        value={seconds(@parameters["late_window_ms"], 300)}
      />
      <label for="rule-sequence">Sequence evidence</label>
      <select id="rule-sequence" name="rule[sequence]">
        <option value="none" selected={sequence(@parameters) == "none"}>Disabled</option>
        <option value="optional" selected={sequence(@parameters) == "optional"}>Optional</option>
        <option value="required" selected={sequence(@parameters) == "required"}>Required</option>
      </select>
      <label for="rule-uncertainty">Position uncertainty</label>
      <select id="rule-uncertainty" name="rule[uncertainty]">
        <option value="require_bound" selected={uncertainty(@parameters) == "require_bound"}>
          Require accuracy bounds
        </option>
        <option
          value="coordinate_only"
          selected={uncertainty(@parameters) == "coordinate_only"}
        >
          Use reported coordinates only
        </option>
      </select>
    </fieldset>
    <label for="rule-skew">Permitted receiver clock skew (seconds)</label>
    <input
      id="rule-skew"
      name="rule[future_skew_seconds]"
      type="number"
      min="0"
      max={@maximum}
      value={seconds(@parameters["future_skew_ms"], 60)}
    />
    """
  end

  defp whole_seconds?(values),
    do: Enum.all?(values, &(is_integer(&1) and rem(&1, 1_000) == 0))

  defp seconds(milliseconds, _default) when is_integer(milliseconds),
    do: div(milliseconds, 1_000)

  defp seconds(_, default), do: default

  defp milliseconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in 0..@maximum_seconds -> {:ok, seconds * 1_000}
      _ -> :error
    end
  end

  defp milliseconds(_), do: :error

  defp positive_milliseconds(value) do
    with {:ok, milliseconds} <- milliseconds(value),
         true <- milliseconds > 0 do
      {:ok, milliseconds}
    else
      _ -> :error
    end
  end

  defp volts(value) when is_binary(value) do
    case Float.parse(value) do
      {volts, ""} when volts > 0 and volts < 100 -> {:ok, volts}
      _ -> :error
    end
  end

  defp volts(_), do: :error

  defp number(value, lower, upper) when is_binary(value) do
    parsed =
      case Integer.parse(value) do
        {number, ""} ->
          {:ok, number}

        _ ->
          case Float.parse(value) do
            {number, ""} -> {:ok, number}
            _ -> :error
          end
      end

    case parsed do
      {:ok, number} when number >= lower and number <= upper -> {:ok, number}
      _ -> :error
    end
  end

  defp number(_, _, _), do: :error

  defp ordering(input) do
    with true <- input["event_time"] in @order_event_times,
         {:ok, skew} <- milliseconds(input["future_skew_seconds"]),
         {:ok, late} <- milliseconds(input["late_window_seconds"]),
         true <- input["sequence"] in @sequences,
         true <- input["uncertainty"] in @uncertainties do
      {:ok,
       %{
         "event_time" => input["event_time"],
         "future_skew_ms" => skew,
         "late_window_ms" => late,
         "sequence" => input["sequence"],
         "uncertainty" => input["uncertainty"]
       }}
    else
      _ -> :error
    end
  end

  defp shape(%{"shape_kind" => "circle"} = input) do
    with {:ok, latitude} <- number(input["latitude"], -90, 90),
         {:ok, longitude} <- number(input["longitude"], -180, 180),
         {:ok, radius} <- number(input["radius_m"], 0, 1_000_000) do
      {:ok,
       %{
         "kind" => "circle",
         "latitude" => latitude,
         "longitude" => longitude,
         "radius_m" => radius
       }}
    end
  end

  defp shape(%{"shape_kind" => "polygon", "vertices" => text}) when is_binary(text) do
    lines = text |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    with true <- length(lines) in 3..64,
         {:ok, vertices} <- polygon_vertices(lines, []) do
      {:ok, %{"kind" => "polygon", "vertices" => vertices}}
    else
      _ -> :error
    end
  end

  defp shape(_), do: :error

  defp polygon_vertices([], vertices), do: {:ok, Enum.reverse(vertices)}

  defp polygon_vertices([line | rest], vertices) do
    case String.split(line, ",", parts: 2) do
      [latitude, longitude] ->
        with {:ok, latitude} <- number(String.trim(latitude), -90, 90),
             {:ok, longitude} <- number(String.trim(longitude), -180, 180) do
          polygon_vertices(rest, [
            %{"latitude" => latitude, "longitude" => longitude} | vertices
          ])
        end

      _ ->
        :error
    end
  end

  defp ordering?(parameters),
    do:
      parameters["event_time"] in @order_event_times and
        parameters["sequence"] in @sequences and
        parameters["uncertainty"] in @uncertainties and
        whole_seconds?([parameters["future_skew_ms"], parameters["late_window_ms"]])

  defp shape?(
         %{
           "kind" => "circle",
           "latitude" => latitude,
           "longitude" => longitude,
           "radius_m" => radius
         } = shape
       ),
       do: map_size(shape) == 4 and Enum.all?([latitude, longitude, radius], &is_number/1)

  defp shape?(%{"kind" => "polygon", "vertices" => vertices} = shape)
       when map_size(shape) == 2 and is_list(vertices),
       do:
         length(vertices) in 3..64 and
           Enum.all?(vertices, fn
             %{"latitude" => latitude, "longitude" => longitude} = vertex ->
               map_size(vertex) == 2 and is_number(latitude) and is_number(longitude)

             _ ->
               false
           end)

  defp shape?(_), do: false

  defp exact?(value, fields),
    do: Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp value(nil, default), do: default
  defp value(value, _default), do: value

  defp shape_kind(%{"shape" => %{"kind" => kind}}) when kind in ~w(circle polygon), do: kind
  defp shape_kind(_), do: "circle"

  defp shape_value(parameters, field, default \\ "")

  defp shape_value(%{"shape" => %{"kind" => "circle"} = shape}, field, default),
    do: value(shape[field], default)

  defp shape_value(_, _, default), do: default

  defp vertices(%{"shape" => %{"kind" => "polygon", "vertices" => vertices}}),
    do: Enum.map_join(vertices, "\n", &"#{&1["latitude"]},#{&1["longitude"]}")

  defp vertices(_), do: ""

  defp event_time(parameters), do: value(parameters["event_time"], "trusted_fix")
  defp sequence(parameters), do: value(parameters["sequence"], "none")
  defp uncertainty(parameters), do: value(parameters["uncertainty"], "require_bound")

  defp kind_enabled?(kinds, kind), do: kind in kinds

  defp position_fields?(kinds),
    do: kind_enabled?(kinds, "motion") or kind_enabled?(kinds, "geofence")
end
