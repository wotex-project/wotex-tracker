defmodule Wotex.Tracker.PropertyDelivery do
  @moduledoc false

  alias Wotex.Tracker.{Admission, Error}

  # Delivery is a host declaration backed by a transport claim. It does not
  # change the decoder's physical-device capabilities or imply a device Event.
  def declaration(value, forms, limits) when is_map(value) and is_map(forms) do
    if map_size(value) <= limits.max_affordances do
      Admission.each(Map.to_list(value), &reference(&1, forms, limits))
    else
      error()
    end
  end

  def declaration(_, _, _), do: error()

  defp reference({pointer, evidence}, forms, limits) do
    with :ok <- Admission.id(pointer, limits),
         :ok <- Admission.id(evidence, limits),
         true <- Map.has_key?(forms, pointer) do
      :ok
    else
      _ -> error()
    end
  end

  def operations(form, false, :property),
    do: Wotex.Form.operations(form) === ["readproperty"]

  def operations(form, true, :property) do
    map = Wotex.Form.to_map(form)

    case Wotex.Form.operations(form) do
      ["readproperty"] ->
        true

      operations
      when operations in [
             ["observeproperty"],
             ["unobserveproperty"],
             ["observeproperty", "unobserveproperty"]
           ] ->
        map["subprotocol"] == "sse" and map["contentType"] == "application/json" and
          URI.parse(map["href"]).scheme in ["http", "https"]

      _ ->
        false
    end
  end

  def operations(form, false, :action),
    do:
      Wotex.Form.operations(form, for: :action) === ["invokeaction"] and
        explicit_operation?(Wotex.Form.to_map(form), "invokeaction")

  def operations(_, true, :action), do: false

  def complete(forms, observing?, :property) do
    operations =
      forms
      |> Enum.flat_map(fn form -> List.wrap(form["op"]) end)
      |> Enum.uniq()
      |> Enum.sort()

    expected =
      if observing?,
        do: ~w(observeproperty readproperty unobserveproperty),
        else: ["readproperty"]

    if operations == expected, do: :ok, else: error()
  end

  def complete(forms, false, :action) do
    operations =
      forms
      |> Enum.flat_map(fn form -> List.wrap(form["op"]) end)
      |> Enum.uniq()
      |> Enum.sort()

    if operations == ["invokeaction"], do: :ok, else: error()
  end

  def complete(_, true, :action), do: error()

  def project(property, pointer, capability, deployment, bundle) do
    case Map.fetch(deployment.observation_evidence, pointer) do
      :error ->
        if property["observable"] == true, do: error(), else: {:ok, property}

      {:ok, id} ->
        with {:ok, evidence} <- Map.fetch(bundle.evidence, id),
             true <-
               property["observable"] != false and
                 supported?(evidence, pointer, capability, deployment, bundle) do
          {:ok, Map.put(property, "observable", true)}
        else
          _ -> error()
        end
    end
  end

  defp supported?(evidence, pointer, capability, deployment, bundle) do
    source_ids =
      capability.evidence_ids
      |> Enum.flat_map(&bundle.evidence[&1].source_observation_ids)
      |> Enum.uniq()
      |> Enum.sort()

    evidence.kind == :transport and evidence.confidence == :exact and
      "host_delivery_declaration" in evidence.reasons and
      Enum.sort(evidence.evidence_ids) == Enum.sort(capability.evidence_ids) and
      Enum.sort(evidence.source_observation_ids) == source_ids and
      claim?(evidence.claim, pointer, deployment)
  end

  defp claim?(claim, pointer, deployment) do
    is_binary(claim["provider"]) and byte_size(claim["provider"]) > 0 and
      is_binary(claim["revision"]) and byte_size(claim["revision"]) > 0 and
      claim === %{
        "schema" => "wtr.delivery.v1",
        "provider" => claim["provider"],
        "revision" => claim["revision"],
        "semantics" => "committed-values",
        "deployment_revision" => deployment.revision,
        "property" => pointer,
        "forms" => deployment.forms[pointer]
      }
  end

  defp explicit_operation?(%{"op" => "invokeaction"}, _operation), do: true

  defp explicit_operation?(%{"op" => operations}, operation) when is_list(operations),
    do: operations == [operation]

  defp explicit_operation?(_, _), do: false

  defp error, do: {:error, Error.new(:invalid_mapping, :materialisation)}
end
