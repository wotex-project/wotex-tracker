defmodule Wotex.Tracker.ProbeEvidence do
  @moduledoc """
  Admitted private evidence returned by one authorized active probe.

  The result must bind the exact observation and an immutable probe declaration
  in the supplied catalogue. Public transport/target fields are matched against
  that declaration, response bytes must use canonical Base64 and no caller data
  can select a callback or create a profile.
  """

  alias Wotex.Tracker.{
    Admission,
    Catalogue,
    DeviceProfile,
    Error,
    Limits,
    Observation,
    ProbeContract
  }

  @fields ~w(schema request_id observation_identity profile probe transport operation target target_identity value)
  @profile_fields ~w(id version)
  @probe_fields ~w(id revision)
  @target_fields ~w(service_uuid characteristic_uuid handle generation)
  @value_fields ~w(encoding bytes data)
  @request_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @target_identity ~r/\A[0-9a-f]{64}\z/
  @maximum_json_integer 9_007_199_254_740_991

  @type t :: %__MODULE__{
          document: map(),
          value: binary(),
          identity: String.t(),
          profile: DeviceProfile.t(),
          contract: ProbeContract.t()
        }
  @enforce_keys [:document, :value, :identity, :profile, :contract]
  defstruct @enforce_keys

  @doc "Admits and binds one service probe result to its observation and catalogue contract."
  @spec new(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(document, observation, catalogue, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         {:ok, observation} <- Observation.validate(observation, options),
         {:ok, catalogue} <- Catalogue.validate(catalogue, options),
         :ok <- Admission.object(document, limits),
         true <- exact_fields?(document, @fields),
         true <- document["schema"] == "wtr.active-probe-result.v1",
         true <- request_id?(document["request_id"]),
         {:ok, observation_identity} <- Observation.identity(observation, options),
         true <- document["observation_identity"] == observation_identity,
         true <- revision?(document["profile"], @profile_fields),
         true <- revision?(document["probe"], @probe_fields),
         {:ok, profile} <- profile(catalogue, document["profile"]),
         {:ok, contract} <- contract(profile, document["probe"], options),
         true <- document["transport"] == contract.document["transport"],
         true <- document["operation"] == contract.document["operation"],
         true <- target?(document["target"], contract.document["target"]),
         true <- target_identity?(document["target_identity"]),
         {:ok, value} <- value(document["value"], contract.document["max_value_bytes"]),
         {:ok, identity} <- Admission.digest(document, Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         document: document,
         value: value,
         identity: identity,
         profile: profile,
         contract: contract
       }}
    else
      false -> Admission.fail(:invalid_input)
      {:error, %Error{}} = error -> error
      _ -> Admission.fail(:invalid_input)
    end
  end

  @doc "Revalidates evidence from its original result document."
  @spec validate(term(), term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, observation, catalogue, options \\ [])

  def validate(%__MODULE__{document: document} = value, observation, catalogue, options) do
    with {:ok, admitted} <- new(document, observation, catalogue, options),
         true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _, _, _), do: Admission.fail(:invalid_input)

  defp profile(catalogue, %{"id" => id, "version" => version}) do
    case Enum.find(catalogue.profiles, &(&1.id == id and &1.version == version)) do
      nil -> Admission.fail(:conflict)
      profile -> {:ok, profile}
    end
  end

  defp contract(profile, %{"id" => id, "revision" => revision}, options) do
    Enum.reduce_while(profile.probes, Admission.fail(:conflict), fn definition, acc ->
      find_contract(definition, {id, revision}, options, acc)
    end)
  end

  defp find_contract(definition, key, options, missing) do
    case ProbeContract.new(definition, options) do
      {:ok, contract} -> contract_result(contract, key, missing)
      error -> {:halt, error}
    end
  end

  defp contract_result(contract, key, missing) do
    if ProbeContract.key(contract) == key,
      do: {:halt, {:ok, contract}},
      else: {:cont, missing}
  end

  defp value(%{"encoding" => "base64", "bytes" => size, "data" => data} = document, max)
       when map_size(document) == length(@value_fields) and is_integer(size) and size >= 0 and
              size <= max and is_binary(data) do
    with {:ok, value} <- Base.decode64(data),
         true <- byte_size(value) == size,
         true <- Base.encode64(value) == data do
      {:ok, value}
    else
      _ -> Admission.fail(:invalid_input)
    end
  end

  defp value(_, _), do: Admission.fail(:invalid_input)

  defp target?(target, expected) do
    exact_fields?(target, @target_fields) and
      ProbeContract.equivalent_uuid?(target["service_uuid"], expected["service_uuid"]) and
      ProbeContract.equivalent_uuid?(
        target["characteristic_uuid"],
        expected["characteristic_uuid"]
      ) and
      nullable_handle?(target["handle"]) and nullable_generation?(target["generation"])
  end

  defp revision?(value, fields) do
    exact_fields?(value, fields) and Enum.all?(Map.values(value), &label?/1)
  end

  defp exact_fields?(value, fields) when is_map(value) and map_size(value) == length(fields),
    do: Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp exact_fields?(_, _), do: false

  defp request_id?(value) when is_binary(value), do: Regex.match?(@request_id, value)
  defp request_id?(_), do: false

  defp target_identity?(value) when is_binary(value), do: Regex.match?(@target_identity, value)
  defp target_identity?(_), do: false

  defp label?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"])

  defp label?(_), do: false

  defp nullable_handle?(nil), do: true
  defp nullable_handle?(value), do: is_integer(value) and value in 1..65_535

  defp nullable_generation?(nil), do: true

  defp nullable_generation?(value),
    do: is_integer(value) and value in 0..@maximum_json_integer
end
