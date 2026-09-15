defmodule Wotex.Tracker.Deployment do
  @moduledoc "Explicit endpoint and security declarations. No credentials, default security or invented Forms are supplied."
  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(revision title forms security_definitions security)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits exact readable-Property Forms and explicit security using upstream WoT constructors."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.revision, input.title], &Admission.id(&1, limits)),
         :ok <- native(input, limits),
         :ok <- security(input, limits),
         :ok <- forms(input.forms, input.security_definitions, limits),
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

  defp document(input), do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(input, &1)})

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

  defp forms(forms, definitions, limits) when is_map(forms) do
    if map_size(forms) <= limits.max_affordances do
      Admission.each(Map.values(forms), &form_list(&1, definitions, limits))
    else
      {:error, Error.new(:limit_exceeded, :materialisation)}
    end
  end

  defp forms(_, _, _), do: {:error, Error.new(:missing_form, :materialisation)}

  defp form_list(forms, definitions, limits) do
    with :ok <- Admission.bounded_list(forms, limits.max_forms),
         true <- forms != [],
         :ok <- Admission.each(forms, &form(&1, definitions, limits)) do
      :ok
    else
      false -> {:error, Error.new(:missing_form, :materialisation)}
      error -> error
    end
  end

  defp form(map, definitions, limits) do
    with {:ok, form} <-
           Wotex.Form.new(map, Keyword.put(Limits.material(limits), :for, :property)),
         true <- Wotex.Form.operations(form) === ["readproperty"],
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
end
