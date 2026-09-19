defmodule Wotex.Tracker.Service.NotificationIntent do
  @moduledoc false

  # Push is a non-canonical, lossy projection of a durable alert. Live rule
  # events atomically stage only an opaque alert reference for each active
  # endpoint. Replay processing must never cause a notification.

  alias Wotex.Tracker.Service.{Codec, ForwardItem, ForwardQueue, NotificationEndpoint, SQL}

  @maximum_endpoints 256

  def stage(_db, %{mode: mode}, _generation, _alert_id, _options) when mode != "live", do: :ok

  def stage(db, source, generation, alert_id, options) do
    rows = endpoints(db, source.scope, generation)

    if length(rows) > @maximum_endpoints,
      do: throw({:storage, :storage_unavailable})

    Enum.each(rows, fn [internal_id, encoded] ->
      value = Codec.decode!(encoded)

      with {:ok, target} <-
             NotificationEndpoint.queue_target(
               options.credentials,
               source.scope,
               internal_id,
               value
             ),
           {:ok, item} <- item(source, alert_id, target) do
        ForwardQueue.stage(db, item, options)
      else
        _ -> throw({:storage, :storage_unavailable})
      end
    end)

    :ok
  end

  defp endpoints(db, scope, generation) do
    SQL.rows!(
      db,
      """
      SELECT r.id,r.document FROM records r
      WHERE r.scope=? AND r.kind='notification_endpoints' AND r.generation<=?
      AND r.generation=(SELECT max(v.generation) FROM records v WHERE v.scope=r.scope AND v.kind=r.kind AND v.id=r.id AND v.generation<=?)
      AND r.document!='null' ORDER BY r.id LIMIT ?
      """,
      [scope, generation, generation, @maximum_endpoints + 1]
    )
  end

  defp item(source, alert_id, target) do
    id =
      "notification:" <>
        Codec.digest(%{
          "scope" => source.scope,
          "alert" => alert_id,
          "candidate" => target.candidate_id
        })

    ForwardItem.new(%{
      scope: source.scope,
      id: id,
      candidate_id: target.candidate_id,
      bearer: "push",
      application_protocol: target.provider,
      payload: %{
        "schema" => "wtr.notification-reference.v1",
        "event_ref" => alert_id
      },
      source: :lossy,
      admitted_at: source.evaluated_at,
      required_acknowledgement: :application
    })
  end
end
