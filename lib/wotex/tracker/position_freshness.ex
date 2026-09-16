defmodule Wotex.Tracker.PositionFreshness do
  @moduledoc """
  Versioned, pure freshness classification over explicit Unix milliseconds.

  A trusted fix time takes precedence over reception time. An old fix is never
  made fresh by delayed delivery. Missing fix time may use reception time only
  under an explicit policy; an untrusted supplied fix never silently falls back.
  Device message time is retained evidence, not a replacement for fix time.
  """

  alias Wotex.Tracker.{Admission, Error, Limits, Position}

  @fields ~w(revision max_age_ms future_skew_ms missing_fix accept_suspect)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits an explicit policy; finite windows are at most seven days."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.id(input.revision, limits),
         true <- is_integer(input.max_age_ms) and input.max_age_ms in 0..604_800_000,
         true <- is_integer(input.future_skew_ms) and input.future_skew_ms in 0..604_800_000,
         true <-
           input.missing_fix in [:unknown, :receiver_time] and is_boolean(input.accept_suspect),
         {:ok, identity} <- Admission.digest(policy_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects a forged or modified policy identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = policy, options) do
    with {:ok, admitted} <- new(Map.take(policy, @fields), options) do
      if policy === admitted, do: {:ok, policy}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Evaluates availability, quality and clock qualification without reading any clock."
  @spec evaluate(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(position, bundle, policy, now, options \\ []) do
    with {:ok, position} <- Position.validate(position, bundle, options),
         {:ok, policy} <- validate(policy, options),
         true <- is_integer(now) do
      {status, reason, basis, timestamp} = classify(position.claim, policy, now)

      {:ok,
       %{
         "schema" => "wtr.position-freshness.v1",
         "status" => status,
         "reason" => reason,
         "time_basis" => basis,
         "timestamp" => timestamp,
         "age_ms" => if(timestamp, do: now - timestamp, else: nil),
         "evaluated_at" => now,
         "evidence_id" => position.evidence_id,
         "bundle_identity" => position.bundle_identity,
         "policy_revision" => policy.revision,
         "policy_identity" => policy.identity
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp classify(%{"availability" => "unavailable"}, _, _),
    do: {"unknown", "unavailable", nil, nil}

  defp classify(claim, policy, now) do
    cond do
      claim["quality"] == "suspect" and not policy.accept_suspect ->
        {"unknown", "suspect", nil, nil}

      claim["received_at"] > now + policy.future_skew_ms ->
        {"unknown", "receiver_in_future", nil, nil}

      is_integer(claim["fix_at"]) and claim["fix_clock"] != "trusted" ->
        {"unknown", "untrusted_fix_clock", nil, nil}

      is_integer(claim["fix_at"]) ->
        age(claim["fix_at"], "fix", policy, now, claim["received_at"])

      policy.missing_fix == :receiver_time ->
        age(claim["received_at"], "receiver", policy, now, claim["received_at"])

      true ->
        {"unknown", "missing_fix_time", nil, nil}
    end
  end

  defp age(timestamp, basis, policy, now, received) do
    cond do
      timestamp > received + policy.future_skew_ms ->
        {"unknown", "fix_after_reception", basis, timestamp}

      timestamp > now + policy.future_skew_ms ->
        {"future", "future_skew_exceeded", basis, timestamp}

      now - timestamp > policy.max_age_ms ->
        {"stale", "max_age_exceeded", basis, timestamp}

      true ->
        {"fresh", "within_window", basis, timestamp}
    end
  end

  defp policy_map(input),
    do: %{
      "schema" => "wtr.position-freshness-policy.v1",
      "algorithm" => "qualified-fix-first-v1",
      "revision" => input.revision,
      "max_age_ms" => input.max_age_ms,
      "future_skew_ms" => input.future_skew_ms,
      "missing_fix" => Atom.to_string(input.missing_fix),
      "accept_suspect" => input.accept_suspect
    }
end
