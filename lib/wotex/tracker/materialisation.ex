defmodule Wotex.Tracker.Materialisation do
  @moduledoc """
  Pure evidence-to-TD materialisation through upstream WoT validation.
  All models, identity associations, snapshots, capabilities and deployment
  declarations are explicit. No Form is executed and no Thing is published.
  The evidence bundle stays outside the public TD and retains full provenance.
  """

  alias Wotex.Tracker.{
    Admission,
    Capability,
    Decoder,
    Deployment,
    DeviceProfile,
    Error,
    EvidenceBundle,
    Identity,
    Limits,
    Model,
    PropertyDelivery,
    Resolution
  }

  @fields ~w(observation catalogue resolution decoded bundle capabilities identity model mapping_revision deployment)a
  @type t :: %__MODULE__{
          td: Wotex.ThingDescription.t(),
          identity: String.t(),
          bundle: EvidenceBundle.t(),
          provenance: map()
        }
  @enforce_keys [:td, :identity, :bundle, :provenance]
  defstruct @enforce_keys

  @doc "Materialises only resolved, consistent evidence with explicit endpoint/security inputs."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         {:ok, resolution} <-
           Resolution.validate(input.resolution, input.observation, input.catalogue, options),
         :ok <- resolved(resolution),
         {:ok, decoded} <-
           Decoder.validate(input.decoded, input.observation, input.catalogue, options),
         {:ok, bundle} <- EvidenceBundle.validate(input.bundle, options),
         {:ok, identity} <- Identity.validate(input.identity, bundle, options),
         {:ok, model} <- Model.validate(input.model, options),
         {:ok, deployment} <- Deployment.validate(input.deployment, options),
         :ok <- revisions(input, resolution.selected, bundle, model),
         {:ok, capabilities} <- capabilities(input.capabilities, bundle, limits, options),
         :ok <- decoded_evidence(decoded, bundle, capabilities),
         {:ok, properties} <-
           select(model, resolution.selected.mapping, capabilities, deployment, bundle, limits),
         candidate = candidate(model, identity, properties, deployment),
         {:ok, td} <- upstream(candidate, limits),
         {:ok, profile_identity} <- DeviceProfile.identity(resolution.selected, options),
         provenance = provenance(input, model, bundle, deployment, profile_identity),
         {:ok, generation} <-
           Admission.digest(
             %{
               "schema" => "wtr.materialisation.v1",
               "td" => candidate,
               "provenance" => provenance
             },
             Limits.material(limits)
           ) do
      {:ok, %__MODULE__{td: td, identity: generation, bundle: bundle, provenance: provenance}}
    end
  end

  defp resolved(%{status: :resolved}), do: :ok
  defp resolved(_), do: error(:unknown_resolution)

  defp revisions(input, profile, bundle, model) do
    expected = {profile.id, profile.version}

    cond do
      profile.model !== model.revision or input.mapping_revision !== profile.mapping_revision ->
        error(:revision_mismatch)

      bundle.observations[input.observation.id] !== input.observation ->
        error(:conflict)

      not Enum.all?(bundle.evidence, fn {_id, evidence} ->
        evidence.profile === expected and evidence.decoder === profile.decoder
      end) ->
        error(:revision_mismatch)

      true ->
        :ok
    end
  end

  defp decoded_evidence(decoded, bundle, capabilities) do
    if Enum.all?(decoded.bundle.evidence, fn {id, claim} -> bundle.evidence[id] === claim end) and
         Enum.all?(Map.values(capabilities), fn capability ->
           Enum.any?(decoded.capabilities, &(&1 === capability))
         end),
       do: :ok,
       else: error(:conflict)
  end

  defp capabilities(values, bundle, limits, options) do
    with :ok <- Admission.bounded_list(values, limits.max_affordances),
         do: index_capabilities(values, bundle, options)
  end

  defp index_capabilities(values, bundle, options) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      with {:ok, capability} <- Capability.validate(value, bundle, options),
           false <- Map.has_key?(acc, capability.id) do
        {:cont, {:ok, Map.put(acc, capability.id, capability)}}
      else
        true -> {:halt, error(:conflict)}
        error -> {:halt, error}
      end
    end)
  end

  defp select(model, mapping, capabilities, deployment, bundle, limits) do
    properties = Map.get(model.document, "properties", %{})
    destinations = Map.values(mapping)

    known =
      Map.new(properties, fn {name, property} ->
        {Wotex.JSON.join_pointer("/properties", name), {name, property}}
      end)

    with true <- length(Enum.uniq(destinations)) == length(destinations),
         true <- Enum.all?(destinations, &Map.has_key?(known, &1)),
         true <- Enum.all?(Map.keys(deployment.forms), &Map.has_key?(known, &1)),
         :ok <- Admission.bounded_list(destinations, limits.max_affordances) do
      inverse = Map.new(mapping, fn {capability, pointer} -> {pointer, capability} end)
      optional = Map.get(model.document, "tm:optional", [])

      select_properties(known, inverse, capabilities, deployment, optional, bundle)
    else
      false -> error(:invalid_mapping)
      error -> error
    end
  end

  defp select_properties(known, inverse, capabilities, deployment, optional, bundle) do
    Enum.reduce_while(known, {:ok, %{}}, fn {pointer, {name, property}}, {:ok, acc} ->
      case property(pointer, property, inverse, capabilities, deployment, optional, bundle) do
        {:ok, selected} -> {:cont, {:ok, Map.put(acc, name, selected)}}
        :omit -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp property(pointer, property, inverse, capabilities, deployment, optional, bundle) do
    case Map.fetch(capabilities, inverse[pointer]) do
      {:ok, capability} -> readable(pointer, property, capability, deployment, bundle)
      :error -> if pointer in optional, do: :omit, else: error(:missing_capability)
    end
  end

  defp readable(pointer, property, capability, deployment, bundle) do
    cond do
      property["readOnly"] !== true or property["writeOnly"] === true ->
        error(:invalid_mapping)

      property["unit"] !== capability.unit ->
        error(:invalid_mapping)

      not Map.has_key?(deployment.forms, pointer) ->
        error(:missing_form)

      true ->
        with {:ok, property} <-
               PropertyDelivery.project(property, pointer, capability, deployment, bundle),
             do: {:ok, Map.put(property, "forms", deployment.forms[pointer])}
    end
  end

  defp candidate(model, identity, properties, deployment) do
    model.document
    |> Map.delete("tm:optional")
    |> remove_model_type()
    |> Map.put("id", identity.thing_id)
    |> Map.put("title", deployment.title)
    |> Map.put("properties", properties)
    |> Map.update!("version", &Map.put(&1, "instance", deployment.revision))
    |> Map.put("securityDefinitions", deployment.security_definitions)
    |> Map.put("security", deployment.security)
  end

  defp remove_model_type(document) do
    case document["@type"] do
      "tm:ThingModel" ->
        Map.delete(document, "@type")

      types when is_list(types) ->
        case Enum.reject(types, &(&1 == "tm:ThingModel")) do
          [] -> Map.delete(document, "@type")
          other -> Map.put(document, "@type", other)
        end

      _ ->
        document
    end
  end

  defp provenance(input, model, bundle, deployment, profile_identity) do
    %{
      "model" => model.identity,
      "model_revision" => Tuple.to_list(model.revision),
      "profile" => profile_identity,
      "catalogue" => input.catalogue.identity,
      "bundle" => bundle.identity,
      "mapping_revision" => input.mapping_revision,
      "identity" =>
        input.identity
        |> Map.from_struct()
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end),
      "deployment" => deployment.identity,
      "deployment_revision" => deployment.revision
    }
  end

  defp upstream(candidate, limits) do
    case Wotex.ThingDescription.from_map(candidate, Limits.material(limits)) do
      {:ok, td} -> {:ok, td}
      {:error, _} -> error(:invalid_td)
    end
  end

  defp error(code), do: {:error, Error.new(code, :materialisation)}
end
