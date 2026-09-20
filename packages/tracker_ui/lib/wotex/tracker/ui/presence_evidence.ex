defmodule Wotex.Tracker.UI.PresenceEvidence do
  @moduledoc """
  Admits private owner-presence evidence for submission and validates its public projection.

  A submitted document must be a complete, content-consistent `PolicyFact` for
  `owner.present`, backed by exact or strong identity evidence associated with
  the selected Thing. Only its three-valued status and receiver observation
  time are returned as presentation metadata. The complete document is passed
  directly to the service and must not be retained in LiveView assigns.
  """

  alias Wotex.Tracker.PolicyFact

  @public_fields ~w(schema thing_id status revision observed_at admitted_at admitted_by)
  @statuses ~w(present absent unknown)

  @type admission :: %{
          document: map(),
          status: String.t(),
          observed_at: non_neg_integer()
        }

  @doc "Validates one complete private fact for the selected Thing."
  @spec admission(term(), term()) :: {:ok, admission()} | :error
  def admission(document, thing) when is_map(document) and is_binary(thing) do
    with {:ok, fact} <- PolicyFact.from_map(document),
         true <- fact.predicate == "owner.present",
         true <- fact.evidence.kind == :identity,
         true <- fact.evidence.confidence in [:exact, :strong],
         true <- fact.evidence.association_id == thing,
         {:ok, status} <- public_status(fact.status),
         true <- timestamp?(fact.observed_at) do
      {:ok, %{document: document, status: status, observed_at: fact.observed_at}}
    else
      _ -> :error
    end
  end

  def admission(_, _), do: :error

  @doc "Checks the exact closed public owner-presence projection."
  @spec public?(term(), term()) :: boolean()
  def public?(value, thing) do
    public_shape?(value) and public_identity?(value, thing) and public_times?(value) and
      actor?(value["admitted_by"])
  end

  @doc "Labels the admitted three-valued state without treating unknown as absence."
  @spec label(term()) :: String.t()
  def label(%{"status" => "present"}), do: "Present"
  def label(%{"status" => "absent"}), do: "Absent"
  def label(%{"status" => "unknown"}), do: "Unknown"
  def label(_), do: "Unknown"

  defp public_status("true"), do: {:ok, "present"}
  defp public_status("false"), do: {:ok, "absent"}
  defp public_status("unknown"), do: {:ok, "unknown"}
  defp public_status(_), do: :error

  defp public_shape?(value),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(@public_fields)

  defp public_identity?(value, thing),
    do:
      value["schema"] == "wtr.owner-presence.v1" and value["thing_id"] == thing and
        value["status"] in @statuses and revision?(value["revision"])

  defp public_times?(value),
    do: timestamp?(value["observed_at"]) and timestamp?(value["admitted_at"])

  defp revision?("owner-presence-" <> generation), do: positive_generation?(generation)
  defp revision?(_), do: false

  defp positive_generation?(generation) when byte_size(generation) in 1..19 do
    case Integer.parse(generation) do
      {value, ""} when value > 0 and value < 9_223_372_036_854_775_807 ->
        Integer.to_string(value) == generation

      _ ->
        false
    end
  end

  defp positive_generation?(_), do: false

  defp timestamp?(value), do: is_integer(value) and value in 0..9_007_199_254_740_991

  defp actor?("wtr1_" <> digest),
    do: digest != "" and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, digest)

  defp actor?(_), do: false
end
