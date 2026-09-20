Code.require_file(Path.expand("../scripts/ios_release.exs", __DIR__))

defmodule Wotex.Tracker.Mobile.IOSReleaseTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.Mobile.IOSRelease

  @bundle_id "org.wotex.tracker"
  @team_id "TEAM123XYZ"

  setup do
    root = Path.expand("_build/test/ios-release/#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ipa_path = Path.join(root, "WotexTrackerMobile.ipa")
    File.write!(ipa_path, "unqualified")
    %{ipa_path: ipa_path, root: root}
  end

  test "atomically re-signs and verifies the exact production APNs entitlement", context do
    runner = runner(self())

    assert {:ok, context.ipa_path} ==
             IOSRelease.finalize(context.ipa_path, "Apple Distribution: Example", runner: runner)

    assert File.read!(context.ipa_path) == "qualified"
    assert_received {:signed, "Apple Distribution: Example"}
    assert_received :verified
    assert_received :packaged

    refute Enum.any?(File.ls!(context.root), &String.starts_with?(&1, ".wotex-ios-release-"))
  end

  test "rejects development, foreign and widened profiles without replacing the IPA", context do
    cases = [
      [environment: "development"],
      [team_id: "team-with-punctuation"],
      [application_id: "#{@team_id}.org.foreign.app"],
      [beta_reports_active: false]
    ]

    for profile <- cases do
      assert {:error, :invalid_provisioning_profile} =
               IOSRelease.finalize(context.ipa_path, "Apple Distribution: Example",
                 runner: runner(self(), profile: profile)
               )

      assert File.read!(context.ipa_path) == "unqualified"
      refute_received {:signed, _}
    end

    assert {:error, :invalid_release} =
             IOSRelease.finalize(context.ipa_path, "Apple Distribution: Example",
               runner: runner(self(), bundle_id: "org.foreign.app")
             )

    assert File.read!(context.ipa_path) == "unqualified"
  end

  test "preserves the original artifact when signing or verification fails", context do
    for failure <- [:sign, :verify, :package] do
      assert {:error, :release_command_failed} =
               IOSRelease.finalize(context.ipa_path, "Apple Distribution: Example",
                 runner: runner(self(), failure: failure)
               )

      assert File.read!(context.ipa_path) == "unqualified"
    end

    assert {:error, :invalid_signed_entitlements} =
             IOSRelease.finalize(context.ipa_path, "Apple Distribution: Example",
               runner: runner(self(), tamper_signed_entitlements: true)
             )

    assert File.read!(context.ipa_path) == "unqualified"
  end

  test "contains invalid inputs and exceptional command adapters", context do
    for {path, identity, options} <- [
          {"relative.ipa", "identity", []},
          {context.ipa_path, "", []},
          {context.ipa_path, "identity\nargument", []},
          {context.ipa_path, "identity", [runner: :invalid]},
          {context.ipa_path <> ".zip", "identity", []},
          {nil, nil, []}
        ] do
      assert {:error, :invalid_release} = IOSRelease.finalize(path, identity, options)
    end

    assert {:error, :release_command_failed} =
             IOSRelease.finalize(context.ipa_path, "identity",
               runner: fn _, _, _ -> raise "private failure" end
             )

    assert {:error, :release_command_failed} =
             IOSRelease.finalize(context.ipa_path, "identity",
               runner: fn _, _, _ -> throw(:private_failure) end
             )

    assert File.read!(context.ipa_path) == "unqualified"
  end

  defp runner(owner, options \\ []) do
    profile_options = Keyword.get(options, :profile, [])
    bundle_id = Keyword.get(options, :bundle_id, @bundle_id)
    failure = Keyword.get(options, :failure)
    tamper? = Keyword.get(options, :tamper_signed_entitlements, false)

    fn executable, arguments, command_options ->
      send(owner, {:command, executable, arguments})

      fake_command(
        executable,
        arguments,
        command_options,
        owner,
        profile_options,
        bundle_id,
        failure,
        tamper?
      )
    end
  end

  defp fake_command(
         "/usr/bin/ditto",
         ["-x", "-k", "--norsrc", _ipa_path, extract_directory],
         _command_options,
         _owner,
         _profile,
         bundle_id,
         _failure,
         _tamper?
       ) do
    app_path = Path.join([extract_directory, "Payload", "WotexTrackerMobile.app"])
    File.mkdir_p!(app_path)
    File.write!(Path.join(app_path, "embedded.mobileprovision"), "signed-profile")
    File.write!(Path.join(app_path, "Info.plist"), info_plist(bundle_id))
    {"", 0}
  end

  defp fake_command(
         "/usr/bin/security",
         ["cms", "-D", "-i", _profile_path],
         _command_options,
         _owner,
         profile,
         _bundle_id,
         _failure,
         _tamper?
       ),
       do: {profile_plist(profile), 0}

  defp fake_command(
         "/usr/bin/plutil" = executable,
         arguments,
         command_options,
         _owner,
         _profile,
         _bundle_id,
         _failure,
         _tamper?
       ),
       do: System.cmd(executable, arguments, command_options)

  defp fake_command(
         "/usr/bin/codesign",
         ["--force", "--sign", identity, "--entitlements", entitlements | rest],
         _command_options,
         owner,
         _profile,
         _bundle_id,
         failure,
         _tamper?
       ) do
    app_path = List.last(rest)

    if failure == :sign do
      {"signing failed", 1}
    else
      File.cp!(entitlements, Path.join(app_path, "signed-entitlements.test"))
      send(owner, {:signed, identity})
      {"", 0}
    end
  end

  defp fake_command(
         "/usr/bin/codesign",
         ["--verify", "--deep", "--strict", "--verbose=2", _app_path],
         _command_options,
         owner,
         _profile,
         _bundle_id,
         failure,
         _tamper?
       ) do
    if failure == :verify do
      {"verification failed", 1}
    else
      send(owner, :verified)
      {"", 0}
    end
  end

  defp fake_command(
         "/usr/bin/codesign",
         ["--display", "--entitlements", output_path, "--xml", app_path],
         _command_options,
         _owner,
         _profile,
         _bundle_id,
         _failure,
         tamper?
       ) do
    signed = Path.join(app_path, "signed-entitlements.test")
    File.cp!(signed, output_path)

    if tamper? do
      System.cmd("/usr/bin/plutil", [
        "-replace",
        "aps-environment",
        "-string",
        "development",
        output_path
      ])
    end

    {"", 0}
  end

  defp fake_command(
         "/usr/bin/ditto",
         ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", "Payload", output],
         _command_options,
         owner,
         _profile,
         _bundle_id,
         failure,
         _tamper?
       ) do
    if failure == :package do
      {"packaging failed", 1}
    else
      File.write!(output, "qualified")
      send(owner, :packaged)
      {"", 0}
    end
  end

  defp info_plist(bundle_id) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key>
      <string>#{bundle_id}</string>
    </dict>
    </plist>
    """
  end

  defp profile_plist(options) do
    environment = Keyword.get(options, :environment, "production")
    team_id = Keyword.get(options, :team_id, @team_id)
    application_id = Keyword.get(options, :application_id, team_id <> "." <> @bundle_id)
    beta = Keyword.get(options, :beta_reports_active, true)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
      <key>Entitlements</key>
      <dict>
        <key>application-identifier</key>
        <string>#{application_id}</string>
        <key>com.apple.developer.team-identifier</key>
        <string>#{team_id}</string>
        <key>beta-reports-active</key>
        <#{if beta, do: "true", else: "false"}/>
        <key>aps-environment</key>
        <string>#{environment}</string>
      </dict>
    </dict>
    </plist>
    """
  end
end
