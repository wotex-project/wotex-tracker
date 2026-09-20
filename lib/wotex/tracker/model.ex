defmodule Wotex.Tracker.Model do
  @moduledoc """
  Admits a self-contained Thing Model for evidence-based materialisation.

  `new/3` validates the native document against the supported subset and the
  explicit ID/version revision, then records a content identity. `validate/2`
  recomputes that identity before the model is used. The caller loads the source;
  this module does not fetch references, expand templates, or execute Forms.
  """

  alias Wotex.Tracker.{Admission, Error, Limits}

  @type t :: %__MODULE__{
          document: map(),
          revision: {String.t(), String.t()},
          identity: String.t()
        }
  @enforce_keys [:document, :revision, :identity]
  defstruct @enforce_keys

  @doc "Validates a native model and explicit revision without fetching references or expanding templates."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(document, revision, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.revision(revision, limits),
         :ok <- native(document, limits),
         :ok <- subset(document),
         :ok <- count(document, limits),
         :ok <- upstream(document, limits),
         true <-
           document["id"] === elem(revision, 0) and
             get_in(document, ["version", "model"]) === elem(revision, 1),
         {:ok, identity} <- Admission.digest(document, Limits.material(limits)) do
      {:ok, %__MODULE__{document: document, revision: revision, identity: identity}}
    else
      false -> {:error, Error.new(:revision_mismatch, :materialisation)}
      error -> error
    end
  end

  @doc "Re-admits the source model and verifies its content identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{document: document, revision: revision, identity: identity}, options) do
    with {:ok, model} <- new(document, revision, options), true <- model.identity === identity do
      {:ok, model}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_model)

  defp native(document, limits) do
    case Wotex.JSON.validate(document, Limits.material(limits)) do
      :ok when is_map(document) -> :ok
      _ -> {:error, Error.new(:invalid_model, :materialisation)}
    end
  end

  defp subset(document) do
    if unsupported?(document, true) or Map.get(document, "events", %{}) != %{},
      do: {:error, Error.new(:unsupported_model_feature, :materialisation)},
      else: :ok
  end

  defp unsupported?(value, root) when is_map(value) do
    Enum.any?(value, fn {key, child} ->
      (String.starts_with?(key, "tm:") and not (root and key == "tm:optional")) or
        (key == "rel" and is_binary(child) and String.starts_with?(child, "tm:")) or
        unsupported?(child, false)
    end)
  end

  defp unsupported?(value, _) when is_list(value), do: Enum.any?(value, &unsupported?(&1, false))
  defp unsupported?(value, _) when is_binary(value), do: String.contains?(value, "{{")
  defp unsupported?(_, _), do: false

  defp count(document, limits) do
    properties = Map.get(document, "properties", %{})
    actions = Map.get(document, "actions", %{})

    if is_map(properties) and is_map(actions) and
         map_size(properties) + map_size(actions) <= limits.max_affordances,
       do: :ok,
       else: {:error, Error.new(:limit_exceeded, :materialisation)}
  end

  defp upstream(document, limits) do
    case Wotex.ThingModel.from_map(document, Limits.material(limits)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, Error.new(:invalid_model, :materialisation)}
    end
  end
end
