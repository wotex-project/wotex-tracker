defmodule Wotex.Tracker.Mobile.IOSRelease do
  @moduledoc """
  Repairs and verifies the narrow APNs entitlement seam in a Mob iOS release.

  MobDev 0.7.1 creates a correctly provisioned application but signs its
  distribution bundle with a fixed entitlement document that omits
  `aps-environment`. This tool extracts the already embedded App Store profile,
  admits only the expected production identity, re-signs with a minimal closed
  entitlement set and atomically replaces the IPA only after verification.
  """

  @bundle_id "org.wotex.tracker"
  @maximum_ipa_bytes 4_294_967_296
  @maximum_profile_bytes 4_194_304
  @maximum_output_bytes 4_194_304

  @ditto "/usr/bin/ditto"
  @security "/usr/bin/security"
  @plutil "/usr/bin/plutil"
  @codesign "/usr/bin/codesign"

  @type runner :: (String.t(), [String.t()], keyword() -> {binary(), non_neg_integer()})

  @doc "Finalizes one Mob-generated App Store IPA with the production APNs entitlement."
  @spec finalize(term(), term(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def finalize(ipa_path, signing_identity, options \\ [])

  def finalize(ipa_path, signing_identity, options)
      when is_binary(ipa_path) and is_binary(signing_identity) and is_list(options) do
    runner = Keyword.get(options, :runner, &system_command/3)

    with :ok <- input(ipa_path, signing_identity, runner),
         {:ok, work_directory} <- create_work_directory(Path.dirname(ipa_path)) do
      try do
        finalize_in(ipa_path, signing_identity, work_directory, runner)
      after
        File.rm_rf(work_directory)
      end
    end
  rescue
    _ -> {:error, :release_finalization_failed}
  catch
    _, _ -> {:error, :release_finalization_failed}
  end

  def finalize(_, _, _), do: {:error, :invalid_release}

  defp input(ipa_path, signing_identity, runner) do
    with true <- Path.type(ipa_path) == :absolute and Path.expand(ipa_path) == ipa_path,
         true <- String.ends_with?(ipa_path, ".ipa"),
         {:ok, %{type: :regular, links: 1, size: size}} <- File.lstat(ipa_path),
         true <- size in 1..@maximum_ipa_bytes,
         true <- safe_text?(signing_identity, 512),
         true <- is_function(runner, 3) do
      :ok
    else
      _ -> {:error, :invalid_release}
    end
  end

  defp create_work_directory(parent) do
    directory =
      Path.join(parent, ".wotex-ios-release-" <> random_suffix())

    case File.mkdir(directory) do
      :ok -> {:ok, directory}
      _ -> {:error, :release_finalization_failed}
    end
  end

  defp finalize_in(ipa_path, identity, work_directory, runner) do
    extract_directory = Path.join(work_directory, "archive")
    profile_plist = Path.join(work_directory, "profile.plist")
    entitlements = Path.join(work_directory, "release.entitlements")
    signed_entitlements = Path.join(work_directory, "signed.entitlements")
    repaired_ipa = Path.join(work_directory, Path.basename(ipa_path))

    with :ok <- File.mkdir(extract_directory),
         {:ok, _} <-
           command(runner, @ditto, ["-x", "-k", "--norsrc", ipa_path, extract_directory]),
         {:ok, app_path} <- application_bundle(extract_directory),
         :ok <- bundle_identifier(app_path, runner),
         {:ok, profile} <- provisioning_profile(app_path, profile_plist, runner),
         :ok <- write_entitlements(entitlements, profile),
         {:ok, _} <- sign(app_path, identity, entitlements, runner),
         {:ok, _} <- verify_signature(app_path, runner),
         {:ok, _} <-
           command(
             runner,
             @codesign,
             ["--display", "--entitlements", signed_entitlements, "--xml", app_path]
           ),
         :ok <- verify_signed_entitlements(signed_entitlements, profile, runner),
         {:ok, _} <-
           command(
             runner,
             @ditto,
             [
               "-c",
               "-k",
               "--norsrc",
               "--noextattr",
               "--noqtn",
               "--keepParent",
               "Payload",
               repaired_ipa
             ],
             cd: extract_directory
           ),
         :ok <- replacement(repaired_ipa),
         :ok <- File.rename(repaired_ipa, ipa_path) do
      {:ok, ipa_path}
    else
      {:error, _} = error -> error
      _ -> {:error, :release_finalization_failed}
    end
  end

  defp application_bundle(extract_directory) do
    payload = Path.join(extract_directory, "Payload")

    with {:ok, %{type: :directory}} <- File.lstat(payload),
         {:ok, entries} <- File.ls(payload),
         [name] <- Enum.filter(entries, &String.ends_with?(&1, ".app")),
         path = Path.join(payload, name),
         {:ok, %{type: :directory}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> {:error, :invalid_release}
    end
  end

  defp bundle_identifier(app_path, runner) do
    info = Path.join(app_path, "Info.plist")

    with {:ok, @bundle_id} <- plist_value(runner, info, "CFBundleIdentifier") do
      :ok
    else
      _ -> {:error, :invalid_release}
    end
  end

  defp provisioning_profile(app_path, profile_plist, runner) do
    embedded = Path.join(app_path, "embedded.mobileprovision")

    with {:ok, %{type: :regular, links: 1, size: size}} <- File.lstat(embedded),
         true <- size in 1..@maximum_profile_bytes,
         {:ok, profile_bytes} <- command(runner, @security, ["cms", "-D", "-i", embedded]),
         true <- byte_size(profile_bytes) in 1..@maximum_profile_bytes,
         :ok <- File.write(profile_plist, profile_bytes, [:binary, :exclusive]),
         :ok <- File.chmod(profile_plist, 0o600),
         {:ok, entitlement_bytes} <-
           command(runner, @plutil, [
             "-extract",
             "Entitlements",
             "json",
             "-o",
             "-",
             profile_plist
           ]),
         {:ok,
          %{
            "application-identifier" => application_id,
            "aps-environment" => environment,
            "beta-reports-active" => true,
            "com.apple.developer.team-identifier" => team_id
          }} <- Jason.decode(entitlement_bytes),
         true <- environment == "production",
         true <- team_id?(team_id),
         true <- application_id == team_id <> "." <> @bundle_id do
      {:ok, %{application_id: application_id, environment: environment, team_id: team_id}}
    else
      {:error, :release_command_failed} = error -> error
      _ -> {:error, :invalid_provisioning_profile}
    end
  end

  defp write_entitlements(path, profile) do
    bytes = entitlement_document(profile)

    with :ok <- File.write(path, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      _ -> {:error, :release_finalization_failed}
    end
  end

  defp entitlement_document(profile) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>application-identifier</key>
        <string>#{profile.application_id}</string>
        <key>com.apple.developer.team-identifier</key>
        <string>#{profile.team_id}</string>
        <key>beta-reports-active</key>
        <true/>
        <key>aps-environment</key>
        <string>#{profile.environment}</string>
    </dict>
    </plist>
    """
  end

  defp sign(app_path, identity, entitlements, runner) do
    command(runner, @codesign, [
      "--force",
      "--sign",
      identity,
      "--entitlements",
      entitlements,
      "--timestamp",
      "--options",
      "runtime",
      app_path
    ])
  end

  defp verify_signature(app_path, runner) do
    command(runner, @codesign, [
      "--verify",
      "--deep",
      "--strict",
      "--verbose=2",
      app_path
    ])
  end

  defp verify_signed_entitlements(path, profile, runner) do
    with {:ok, bytes} <- command(runner, @plutil, ["-convert", "json", "-o", "-", path]),
         {:ok, document} <- Jason.decode(bytes),
         true <-
           document == %{
             "application-identifier" => profile.application_id,
             "aps-environment" => profile.environment,
             "beta-reports-active" => true,
             "com.apple.developer.team-identifier" => profile.team_id
           } do
      :ok
    else
      {:error, :release_command_failed} = error -> error
      _ -> {:error, :invalid_signed_entitlements}
    end
  end

  defp replacement(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, links: 1, size: size}} when size in 1..@maximum_ipa_bytes ->
        :ok

      _ ->
        {:error, :release_finalization_failed}
    end
  end

  defp plist_value(runner, path, key) do
    case command(runner, @plutil, ["-extract", key, "raw", "-o", "-", path]) do
      {:ok, output} ->
        value = String.trim(output)
        if safe_text?(value, 512), do: {:ok, value}, else: {:error, :invalid_plist}

      {:error, _} = error ->
        error
    end
  end

  defp command(runner, executable, arguments, options \\ []) do
    case runner.(executable, arguments, options) do
      {output, 0} when is_binary(output) and byte_size(output) <= @maximum_output_bytes ->
        {:ok, output}

      _ ->
        {:error, :release_command_failed}
    end
  rescue
    _ -> {:error, :release_command_failed}
  catch
    _, _ -> {:error, :release_command_failed}
  end

  defp system_command(executable, arguments, options) do
    System.cmd(executable, arguments, Keyword.put(options, :stderr_to_stdout, true))
  end

  defp team_id?(value) do
    safe_text?(value, 64) and String.match?(value, ~r/\A[A-Z0-9]+\z/)
  end

  defp safe_text?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
      not String.contains?(value, ["\0", "\n", "\r"])
  end

  defp random_suffix,
    do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
