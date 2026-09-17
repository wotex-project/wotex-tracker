defmodule Wotex.Tracker.Service.Projection do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, Credentials, RuleStatus}

  def public(_, _id, nil), do: {:ok, nil}
  def public("rules", id, value), do: RuleStatus.project(id, value)
  def public(resource, _id, value), do: {:ok, resource(resource, value)}

  def public_items(resource, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, projected} ->
      case public(resource, item["id"], item["value"]) do
        {:ok, value} -> {:cont, {:ok, [%{item | "value" => value} | projected]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      error -> error
    end)
  end

  def resource("observations", value), do: value["public"]["observation"]
  def resource("resolutions", value), do: value["public"]["resolution"]
  def resource(_, value), do: value["public"]

  def pseudonym(credentials, scope, kind, id) do
    key = Credentials.derive_key(credentials, :pseudonym)

    bytes =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        Codec.encode!(%{"scope" => scope, "kind" => kind, "id" => id})
      )

    "wtr1_" <> Base.url_encode64(bytes, padding: false)
  end

  def observation(observation, id) do
    %{
      "id" => id,
      "observed_at" => scalar(observation.observed_at),
      "ingress" => observation.ingress
    }
  end

  def resolution(resolution) do
    %{
      "status" => Atom.to_string(resolution.status),
      "reason" => Atom.to_string(resolution.reason),
      "candidates" => Enum.map(resolution.candidates, &candidate/1),
      "catalogue_identity" => resolution.catalogue_identity
    }
  end

  def measurement(measurement) do
    %{
      "kind" => measurement.kind,
      "value" => scalar(measurement.value),
      "unit" => measurement.unit,
      "availability" => Atom.to_string(measurement.availability),
      "quality" => Atom.to_string(measurement.quality)
    }
  end

  def scalar(nil), do: %{"type" => "null", "value" => nil}
  def scalar(value) when is_boolean(value), do: %{"type" => "boolean", "value" => value}

  def scalar(value)
      when is_integer(value) and value in -9_007_199_254_740_991..9_007_199_254_740_991,
      do: %{"type" => "integer", "value" => value}

  def scalar(value) when is_integer(value),
    do: %{"type" => "wide_integer", "value" => Integer.to_string(value)}

  def scalar(value) when is_float(value), do: %{"type" => "number", "value" => value}

  defp candidate(candidate) do
    {id, version} = candidate.profile

    %{
      "id" => id,
      "version" => version,
      "confidence" => Atom.to_string(candidate.confidence),
      "reasons" => candidate.reasons
    }
  end
end
