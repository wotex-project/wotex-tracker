defmodule Wotex.Tracker.Service.PublicationTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service.{Codec, Store}

  test "durable intents survive failed/uncertain publication; stale confirmations and cleanup are separate" do
    {store, directory} = store()
    document = "../../test/fixtures/ruuvi/ordinary.td.json" |> File.read!() |> Codec.decode!()
    thing = document["id"]
    publication = %{thing_id: thing, deployment_id: "1", td: document}

    assert {:ok, %{"publication" => %{"status" => "pending"}}} =
             Store.mutate(store, update(%{publication: publication}))

    assert {:ok, pending} = Store.latest_publication(store, "workshop", thing)
    assert pending["document"]["td"] == document
    # Failed or uncertain remote attempts leave the durable intent pending.
    GenServer.stop(store.pid)
    {store, _} = store(directory: directory)
    assert Store.latest_publication(store, "workshop", thing) == {:ok, pending}

    assert {:ok, %{"status" => "published", "cleanup" => "failed"}} =
             Store.confirm_publication(store, "workshop", thing, "1", "failed")

    assert {:ok, %{"cleanup" => "failed"}} =
             Store.confirm_publication(store, "workshop", thing, "1", "pending")

    assert {:ok, %{"status" => "published", "cleanup" => "complete"}} =
             Store.confirm_publication(store, "workshop", thing, "1", "complete")

    assert {:ok, %{"cleanup" => "complete"}} =
             Store.confirm_publication(store, "workshop", thing, "1", "failed")

    assert {:ok, %{"cleanup" => "complete"}} =
             Store.confirm_publication(store, "workshop", thing, "1", "pending")

    assert {:ok, _} =
             Store.mutate(
               store,
               update(%{
                 operation_id: "v2",
                 expected_generation: "1",
                 observation: nil,
                 publication: %{publication | deployment_id: "2"}
               })
             )

    assert {:ok, _} =
             Store.mutate(
               store,
               update(%{
                 operation_id: "v3",
                 expected_generation: "2",
                 observation: nil,
                 publication: %{publication | deployment_id: "3"}
               })
             )

    assert {:error, :superseded} =
             Store.confirm_publication(store, "workshop", thing, "2", "complete")

    assert {:ok, %{"status" => "superseded"}} = Store.publication(store, "workshop", thing, "2")

    assert {:ok, %{"status" => "published", "cleanup" => "complete"}} =
             Store.publication(store, "workshop", thing, "1")

    assert {:ok, %{"status" => "pending", "generation" => "3"}} =
             Store.latest_publication(store, "workshop", thing)

    assert {:error, :not_found} = Store.latest_publication(store, "other", thing)

    assert {:error, :not_found} =
             Store.confirm_publication(store, "other", thing, "3", "complete")

    assert {:error, :invalid_query} = Store.latest_publication(store, "", thing)
    assert {:error, :invalid_query} = Store.publication(store, "workshop", thing, "00")

    assert {:error, :invalid_query} =
             Store.confirm_publication(store, "workshop", thing, "3", "unknown")
  end
end
