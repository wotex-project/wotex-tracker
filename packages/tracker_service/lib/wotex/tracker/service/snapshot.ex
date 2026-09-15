defmodule Wotex.Tracker.Service.Snapshot do
  @moduledoc false
  alias Wotex.Tracker.Service.Store

  def fetch(service, access, kind, id, generation, permission, now) do
    case Store.authorized_fetch(
           service.store,
           access,
           permission,
           %{scope: access.scope, kind: kind, id: id, generation: generation},
           now
         ) do
      {:error, :unknown} -> {:error, :storage_unavailable}
      {:error, :invalid_cursor} when permission == "enroll" -> {:error, :conflict}
      result -> result
    end
  end

  def resolved(index, catalogue) do
    cond do
      index["catalogue_identity"] != catalogue.identity -> {:error, :revision_mismatch}
      index["public"]["resolution"]["status"] != "resolved" -> {:error, :unresolved}
      true -> :ok
    end
  end
end
