defmodule Wotex.Tracker.UI.RuleForm do
  @moduledoc """
  Renders and admits the browser fields for heartbeat and battery rules.

  Operators enter whole seconds and volts. Admission converts them to the
  service's closed millisecond and threshold parameters, or rejects them without
  contacting the service. The service still validates and evaluates every rule.
  Only a numeric `batteryVoltage` Property in volts can back a battery rule.
  """

  use Phoenix.Component

  @maximum_seconds 604_800

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

  def parameters(_, _), do: :error

  @doc "Reports whether stored parameters round-trip through these fields without change."
  @spec editable?(term(), term()) :: boolean()
  def editable?("heartbeat", %{} = parameters),
    do: whole_seconds?([parameters["maximum_silence_ms"], parameters["future_skew_ms"]])

  def editable?("battery", %{"measurement_kind" => "batteryVoltage", "unit" => "V"} = parameters),
    do: whole_seconds?([parameters["maximum_age_ms"], parameters["future_skew_ms"]])

  def editable?(_, _), do: false

  @doc "Reports whether a Thing Description can back a battery-voltage rule."
  @spec battery?(term()) :: boolean()
  def battery?(%{"properties" => %{"batteryVoltage" => %{"type" => "number", "unit" => "V"}}}),
    do: true

  def battery?(_), do: false

  attr(:heartbeat, :boolean, required: true)
  attr(:battery, :boolean, required: true)
  attr(:parameters, :map, default: %{})

  @doc "Renders the fields for the selected rule kinds, prefilled from stored parameters."
  def fields(assigns) do
    assigns = assign(assigns, :maximum, @maximum_seconds)

    ~H"""
    <fieldset :if={@heartbeat}>
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
    <fieldset :if={@battery}>
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

  defp volts(value) when is_binary(value) do
    case Float.parse(value) do
      {volts, ""} when volts > 0 and volts < 100 -> {:ok, volts}
      _ -> :error
    end
  end

  defp volts(_), do: :error
end
