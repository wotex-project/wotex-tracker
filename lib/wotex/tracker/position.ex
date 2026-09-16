defmodule Wotex.Tracker.Position do
  @moduledoc """
  A normalized position claim bound to its complete immutable evidence bundle.

  Coordinates use WGS84 degrees, altitude/accuracy metres and speed metres per
  second. Missing coordinates and accuracy remain explicit. This admission does
  not authenticate a receiver, qualify a clock or perform source-unit conversion;
  the claim declares those interpretations with its profile/decoder provenance.
  """

  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits}

  @fields ~w(schema latitude longitude altitude_m speed_m_s horizontal_accuracy_m accuracy_kind source fix_at device_at received_at fix_clock device_clock availability quality source_units conversion_revision raw receiver_observation_id)
  @sources ~w(gnss cellular wifi ble lorawan operator)
  @units %{
    "latitude" => "latitude",
    "longitude" => "longitude",
    "altitude_m" => "altitude",
    "speed_m_s" => "speed",
    "horizontal_accuracy_m" => "accuracy",
    "fix_at" => "fix_time",
    "device_at" => "device_time",
    "received_at" => "receiver_time"
  }
  @type t :: %__MODULE__{evidence_id: String.t(), bundle_identity: String.t(), claim: map()}
  @enforce_keys [:evidence_id, :bundle_identity, :claim]
  defstruct @enforce_keys

  @doc "Admits a closed wtr.position.v1 claim and verifies its receiver observation and lineage."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(evidence_id, bundle, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.id(evidence_id, limits),
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         {:ok, evidence} <- position_claim(bundle, evidence_id),
         :ok <- claim(evidence.claim, limits),
         :ok <- receiver(evidence, bundle) do
      {:ok,
       %__MODULE__{
         evidence_id: evidence_id,
         bundle_identity: bundle.identity,
         claim: evidence.claim
       }}
    end
  end

  @doc "Revalidates full position content and its immutable evidence identity."
  @spec validate(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, bundle, options \\ [])

  def validate(%__MODULE__{} = value, bundle, options) do
    with {:ok, admitted} <- new(value.evidence_id, bundle, options) do
      if admitted === value, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _, _), do: Admission.fail(:invalid_input)

  @doc "Exports the full private claim and source/profile provenance after revalidation."
  @spec to_map(term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, bundle, options \\ []) do
    with {:ok, value} <- validate(value, bundle, options) do
      evidence = bundle.evidence[value.evidence_id]

      {:ok,
       %{
         "schema" => "wtr.position-evidence.v1",
         "evidence_id" => value.evidence_id,
         "bundle_identity" => value.bundle_identity,
         "position" => value.claim,
         "source_observation_ids" => evidence.source_observation_ids,
         "parent_evidence_ids" => evidence.evidence_ids,
         "profile" => Tuple.to_list(evidence.profile),
         "decoder" => Tuple.to_list(evidence.decoder),
         "confidence" => Atom.to_string(evidence.confidence),
         "reasons" => evidence.reasons,
         "association_id" => evidence.association_id
       }}
    end
  end

  defp position_claim(bundle, id) do
    case Map.fetch(bundle.evidence, id) do
      {:ok, %{kind: :position} = evidence} -> {:ok, evidence}
      _ -> Admission.fail(:dangling_reference)
    end
  end

  defp claim(claim, limits) do
    valid = map_size(claim) == length(@fields) and Enum.all?(@fields, &Map.has_key?(claim, &1))

    with true <- valid and claim["schema"] == "wtr.position.v1" and claim["source"] in @sources,
         true <- coordinates?(claim) and accuracy?(claim),
         true <- optional_number?(claim["altitude_m"], -100_000_000, 100_000_000),
         true <- optional_number?(claim["speed_m_s"], 0, 100_000),
         true <- clock?(claim["fix_at"], claim["fix_clock"]),
         true <-
           clock?(claim["device_at"], claim["device_clock"]) and is_integer(claim["received_at"]),
         :ok <- Admission.id(claim["conversion_revision"], limits),
         :ok <- Admission.id(claim["receiver_observation_id"], limits),
         :ok <- units(claim, limits),
         :ok <- Admission.object(claim["raw"], limits) do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp coordinates?(%{"availability" => "available", "quality" => quality} = claim),
    do:
      quality in ["valid", "suspect"] and number?(claim["latitude"], -90, 90) and
        number?(claim["longitude"], -180, 180)

  defp coordinates?(%{
         "availability" => "unavailable",
         "quality" => "unavailable",
         "latitude" => nil,
         "longitude" => nil
       }),
       do: true

  defp coordinates?(_), do: false

  defp accuracy?(%{"horizontal_accuracy_m" => nil, "accuracy_kind" => "unknown"}), do: true

  defp accuracy?(%{"horizontal_accuracy_m" => value, "accuracy_kind" => kind}),
    do: kind in ["estimate", "bound"] and number?(value, 0, 40_100_000)

  defp number?(value, low, high), do: is_number(value) and value >= low and value <= high
  defp optional_number?(nil, _, _), do: true
  defp optional_number?(value, low, high), do: number?(value, low, high)
  defp clock?(nil, "unknown"), do: true
  defp clock?(time, trust), do: is_integer(time) and trust in ["trusted", "untrusted", "unknown"]

  defp units(claim, limits) do
    units = claim["source_units"]

    with :ok <- Admission.object(units, limits),
         true <-
           map_size(units) == map_size(@units) and
             Enum.all?(Map.values(@units), &Map.has_key?(units, &1)) do
      Admission.each(Map.to_list(@units), &unit(&1, claim, units, limits))
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp unit({field, unit}, claim, units, limits) do
    if is_nil(claim[field]) and is_nil(units[unit]),
      do: :ok,
      else: Admission.id(units[unit], limits)
  end

  defp receiver(evidence, bundle) do
    id = evidence.claim["receiver_observation_id"]

    if id in evidence.source_observation_ids and
         bundle.observations[id].observed_at === evidence.claim["received_at"],
       do: :ok,
       else: Admission.fail(:conflict)
  end
end
