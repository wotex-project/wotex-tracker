Code.require_file("contracts.exs", __DIR__)

case WotexTracker.Contracts.check(File.cwd!()) do
  :ok -> IO.puts("Catalogue, delivery graph, evidence and local documentation links pass")
  {:error, reason} -> Mix.raise("Documentation contract failed: #{inspect(reason)}")
end
