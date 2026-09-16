defmodule Wotex.Tracker.Catalogue do
  @moduledoc """
  Holds the admitted device profiles used for deterministic resolution.

  `new/2` validates every profile, rejects repeated ID/version pairs, sorts the
  result, and binds it to a content identity. Pass the snapshot to
  `Wotex.Tracker.resolve/3`; `validate/2` detects changes to an existing
  snapshot. Catalogue order does not choose a winner between tied profiles.
  """

  alias Wotex.Tracker.{Admission, DeviceProfile, Error, Limits}

  @type t :: %__MODULE__{profiles: [DeviceProfile.t()], identity: String.t()}
  @enforce_keys [:profiles, :identity]
  defstruct [:profiles, :identity]

  @doc "Admits every profile before resolution; repeated ID/version pairs always fail."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(profiles, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.bounded_list(profiles, limits.max_profiles),
         {:ok, profiles} <- admit(profiles, options),
         profiles = Enum.sort_by(profiles, &{&1.id, &1.version}),
         :ok <- unique(profiles),
         {:ok, identity} <- digest(profiles, options, limits) do
      {:ok, %__MODULE__{profiles: profiles, identity: identity}}
    end
  end

  @doc "Recalculates a supplied snapshot and rejects stale or forged identities."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{profiles: profiles, identity: identity}, options) do
    with {:ok, catalogue} <- new(profiles, options), true <- catalogue.identity === identity do
      {:ok, catalogue}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  defp admit(profiles, options) do
    Enum.reduce_while(profiles, {:ok, []}, fn profile, {:ok, acc} ->
      case DeviceProfile.validate(profile, options) do
        {:ok, profile} -> {:cont, {:ok, [profile | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp unique(profiles) do
    keys = Enum.map(profiles, &{&1.id, &1.version})
    if length(Enum.uniq(keys)) == length(keys), do: :ok, else: Admission.fail(:duplicate_id)
  end

  defp digest(profiles, options, limits) do
    identities =
      Enum.map(profiles, fn profile ->
        {:ok, identity} = DeviceProfile.identity(profile, options)
        identity
      end)

    Admission.digest(
      %{"schema" => "wtr.catalogue.v1", "profiles" => identities},
      Limits.json(limits)
      |> Keyword.put(:max_collection_size, max(2, limits.max_profiles))
      |> Keyword.put(:max_nodes, limits.max_profiles + 3)
      |> Keyword.put(:max_bytes, limits.max_profiles * 100 + 100)
    )
  end
end
