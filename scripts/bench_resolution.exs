# Run with MIX_ENV=test WOTEX_PATH_DEPS=1 mise exec -- mix run scripts/bench_resolution.exs.
# Sequential diagnostic only: zero warmup, setup excluded, five elapsed samples.
# Does not measure allocations, peak RSS, concurrency or establish a performance SLA.
alias Wotex.Tracker.{Catalogue, Fixtures, Resolution}

profile =
  Fixtures.profile(%{fingerprints: List.duplicate(hd(Fixtures.profile().fingerprints), 32)})

{:ok, catalogue} = Catalogue.new(for n <- 1..256, do: %{profile | id: "p#{n}"})

observation =
  Fixtures.observation(%{
    source: %{"metadata" => List.duplicate(String.duplicate("a", 200), 250)}
  })

samples =
  for _ <- 1..5 do
    {microseconds, {:ok, result}} =
      :timer.tc(fn -> Resolution.resolve(observation, catalogue) end)

    {microseconds, result.status}
  end

IO.inspect(samples, label: "resolution_elapsed_microseconds")
