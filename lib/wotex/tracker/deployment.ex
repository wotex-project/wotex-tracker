defmodule Wotex.Tracker.Deployment do
  @moduledoc """
  Admits deployment-owned Forms and security declarations for materialisation.

  `new/2` checks readable Property and invokable Action Forms plus explicit
  security definitions against the upstream WoT constructors, then binds the
  admitted declarations to a content identity. The caller supplies endpoint
  and security policy; this module does not invent Forms, provide credentials,
  select default security, contact an endpoint or execute an Action.
  `validate/2` rejects changed declarations.
  """

  alias Wotex.Tracker.{Admission, Error, Limits, PropertyDelivery}

  @fields ~w(revision title forms security_definitions security)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys ++ [observation_evidence: %{}]

  @doc "Admits exact Property/Action Forms and explicit security using upstream WoT constructors."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields, [:observation_evidence]),
         :ok <- Admission.each([input.revision, input.title], &Admission.id(&1, limits)),
         input = Map.put_new(input, :observation_evidence, %{}),
         :ok <- native(input, limits),
         :ok <- PropertyDelivery.declaration(input.observation_evidence, input.forms, limits),
         :ok <- security(input, limits),
         :ok <-
           forms(input.forms, input.security_definitions, input.observation_evidence, limits),
         {:ok, identity} <- Admission.digest(document(input), Limits.material(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    end
  end

  @doc "Revalidates the exact deployment and rejects stale content identities."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = value, options) do
    with {:ok, deployment} <- new(value |> Map.from_struct() |> Map.delete(:identity), options),
         true <- deployment === value do
      {:ok, deployment}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  defp document(input) do
    document = Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(input, &1)})

    if input.observation_evidence == %{},
      do: document,
      else: Map.put(document, "observation_evidence", input.observation_evidence)
  end

  defp native(input, limits) do
    case Wotex.JSON.validate(document(input), Limits.material(limits)) do
      :ok -> :ok
      {:error, _} -> {:error, Error.new(:invalid_input, :materialisation)}
    end
  end

  defp security(input, limits) do
    with true <- is_map(input.security_definitions) and map_size(input.security_definitions) > 0,
         :ok <- Admission.ids(input.security, limits, 32),
         true <- input.security != [],
         true <- Enum.all?(input.security, &Map.has_key?(input.security_definitions, &1)),
         :ok <-
           Admission.each(Map.values(input.security_definitions), &security_scheme(&1, limits)) do
      :ok
    else
      _ -> {:error, Error.new(:invalid_security, :materialisation)}
    end
  end

  defp security_scheme(value, limits) do
    case Wotex.SecurityScheme.new(value, Limits.material(limits)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, Error.new(:invalid_security, :materialisation)}
    end
  end

  defp forms(forms, definitions, delivery, limits) do
    if map_size(forms) <= limits.max_affordances do
      Admission.each(
        Map.to_list(forms),
        &form_entry(&1, definitions, delivery, limits)
      )
    else
      {:error, Error.new(:limit_exceeded, :materialisation)}
    end
  end

  defp form_entry({pointer, list}, definitions, delivery, limits) do
    with {:ok, context} <- pointer_context(pointer) do
      form_list(list, definitions, Map.has_key?(delivery, pointer), context, limits)
    end
  end

  defp form_list(forms, definitions, observing?, context, limits) do
    with :ok <- Admission.bounded_list(forms, limits.max_forms),
         true <- forms != [],
         :ok <- Admission.each(forms, &form(&1, definitions, observing?, context, limits)),
         :ok <- PropertyDelivery.complete(forms, observing?, context) do
      :ok
    else
      false -> {:error, Error.new(:missing_form, :materialisation)}
      error -> error
    end
  end

  defp form(map, definitions, observing?, context, limits) do
    with {:ok, form} <-
           Wotex.Form.new(map, Keyword.put(Limits.material(limits), :for, context)),
         true <- PropertyDelivery.operations(form, observing?, context),
         {:ok, %URI{scheme: scheme, userinfo: nil}} when is_binary(scheme) <-
           URI.new(Wotex.Form.href(form)),
         false <- String.contains?(Wotex.Form.href(form), "{{"),
         :ok <- references(map, definitions, limits) do
      :ok
    else
      _ -> {:error, Error.new(:invalid_mapping, :materialisation)}
    end
  end

  defp references(%{"security" => references}, definitions, limits) do
    references = if is_binary(references), do: [references], else: references

    with :ok <- Admission.ids(references, limits, 32),
         true <- references != [] and Enum.all?(references, &Map.has_key?(definitions, &1)) do
      :ok
    else
      _ -> {:error, Error.new(:invalid_security, :materialisation)}
    end
  end

  defp references(_, _, _), do: :ok

  defp pointer_context("/properties/" <> segment), do: pointer_segment(segment, :property)
  defp pointer_context("/actions/" <> segment), do: pointer_segment(segment, :action)
  defp pointer_context(_), do: {:error, Error.new(:invalid_mapping, :materialisation)}

  defp pointer_segment(segment, context) do
    if segment != "" and not String.contains?(segment, "/") and valid_escapes?(segment),
      do: {:ok, context},
      else: {:error, Error.new(:invalid_mapping, :materialisation)}
  end

  defp valid_escapes?(<<>>), do: true
  defp valid_escapes?(<<"~0", rest::binary>>), do: valid_escapes?(rest)
  defp valid_escapes?(<<"~1", rest::binary>>), do: valid_escapes?(rest)
  defp valid_escapes?(<<"~", _::binary>>), do: false
  defp valid_escapes?(<<_::utf8, rest::binary>>), do: valid_escapes?(rest)
  defp valid_escapes?(_), do: false
end
