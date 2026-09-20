Code.require_file("ios_release.exs", __DIR__)

{options, arguments, invalid} =
  OptionParser.parse(System.argv(), strict: [no_slim: :boolean])

if arguments != [] or invalid != [] do
  Mix.raise("usage: mix run --no-start scripts/release_ios.exs [--no-slim]")
end

config = MobDev.NativeBuild.__load_config__()

with {:ok, resolved} <- MobDev.Release.resolve_distribution_signing(config),
     identity when is_binary(identity) <- resolved[:ios_dist_sign_identity],
     {:ok, ipa_path} <- MobDev.Release.build_ipa(slim: not options[:no_slim]),
     {:ok, ^ipa_path} <- Wotex.Tracker.Mobile.IOSRelease.finalize(ipa_path, identity) do
  Mix.shell().info("")
  Mix.shell().info("Qualified production APNs entitlement: #{ipa_path}")
else
  {:error, reason} -> Mix.raise("iOS release failed: #{inspect(reason)}")
  _ -> Mix.raise("iOS release failed: invalid signing configuration")
end
