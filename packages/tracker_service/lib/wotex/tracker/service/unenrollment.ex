defmodule Wotex.Tracker.Service.Unenrollment do
  @moduledoc false

  # An administrator removes one enrolled asset from current service views. Its
  # enrollment, Thing, current state and every live rule definition bound to it
  # become tombstones in one commit, so deleted definitions stop scheduling. Record
  # history, private evidence, observations and alerts are retained.

  alias Wotex.Tracker.Service.{Codec, Store, Update}

  def admit_delete(
        %{"thing_id" => "urn:uuid:" <> _ = thing, "expected_generation" => generation} = request
      )
      when map_size(request) == 2 do
    if Codec.id?(thing) and match?({:ok, _}, Codec.generation(generation)),
      do: :ok,
      else: {:error, :invalid_request}
  end

  def admit_delete(_), do: {:error, :invalid_request}

  def prepare_delete(service, access, operation, request, now) do
    thing = request["thing_id"]

    with {:ok, _enrollment} <- fetch(service, access, "enrollments", request, now),
         {:ok, current} <-
           optional(service, access, ~w(things state arming owner_presence), request, now),
         {:ok, %{"items" => definitions}} <-
           policies(service, access, thing, request["expected_generation"], now) do
      ids = Enum.map(definitions, & &1["id"])

      Update.new(%{
        principal: access.principal,
        scope: access.scope,
        authority: access,
        operation_id: operation,
        expected_generation: request["expected_generation"],
        now: now,
        request: %{"operation" => "delete_enrollment", "body" => request},
        observation: nil,
        publication: nil,
        response: %{"thing_id" => thing, "action" => "unenrolled", "policy_ids" => ids},
        records:
          Enum.map(["enrollments" | current], &%{kind: &1, id: thing, value: nil}) ++
            Enum.map(ids, &%{kind: "policies", id: &1, value: nil}),
        events:
          [%{"type" => "enrollment.changed", "data" => %{"id" => thing}}] ++
            if("things" in current,
              do: [%{"type" => "thing.changed", "data" => %{"id" => thing}}],
              else: []
            ) ++
            Enum.map(
              ids,
              &%{"type" => "policy.changed", "data" => %{"id" => &1, "action" => "deleted"}}
            )
      })
    end
  end

  # A Thing that was never materialised has no Thing or state record to remove.
  defp optional(service, access, kinds, request, now) do
    Enum.reduce_while(kinds, {:ok, []}, fn kind, {:ok, present} ->
      case fetch(service, access, kind, request, now) do
        {:ok, _} -> {:cont, {:ok, present ++ [kind]}}
        {:error, :not_found} -> {:cont, {:ok, present}}
        error -> {:halt, error}
      end
    end)
  end

  defp fetch(service, access, kind, request, now) do
    service.store
    |> Store.authorized_fetch(
      access,
      "admin",
      %{
        scope: access.scope,
        kind: kind,
        id: request["thing_id"],
        generation: request["expected_generation"]
      },
      now
    )
    |> conflict()
  end

  defp policies(service, access, thing, generation, now),
    do:
      service.store
      |> Store.authorized_policies(access, "admin", thing, generation, now)
      |> conflict()

  defp conflict({:error, :invalid_cursor}), do: {:error, :conflict}
  defp conflict(result), do: result
end
