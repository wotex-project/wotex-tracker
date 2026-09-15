#!/usr/bin/env python3
"""Isolated signed loopback registry and production archive consumers; no publication.

Runs source-cohort checks with unchanged dependency requirements and fresh HEX_HOME.
The public wotex release gate is separate. No sibling checkout is modified.
"""
import hashlib
import http.server
import json
import os
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT.parent / "wotex"
LANES = [("1.18.4-otp-27", "27.3.4.15"), ("1.20.4-otp-29", "29.0.4")]


def run(args, cwd, env, lane=LANES[0]):
    command = ["mise", "exec", f"elixir@{lane[0]}", f"erlang@{lane[1]}", "--"] + args
    result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"{args[0:3]} failed:\n{result.stdout}")
    return result.stdout


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", action="store_true", help="also qualify the durable service archive")
    service = parser.parse_args().service
    with tempfile.TemporaryDirectory(prefix="wtr-source-cohort-") as temporary:
        workspace = Path(temporary)
        env = os.environ.copy()
        for name in ("WOTEX_PATH_DEPS", "MIX_BUILD_PATH", "MIX_DEPS_PATH", "MIX_ENV"):
            env.pop(name, None)
        env["MIX_ENV"] = "prod"
        registry = workspace / "registry"
        tarballs = registry / "tarballs"
        tarballs.mkdir(parents=True)
        source = workspace / "wotex"
        source.mkdir()
        revision = subprocess.check_output(["git", "-C", str(CORE), "rev-parse", "HEAD"], text=True).strip()
        archive = subprocess.check_output(["git", "-C", str(CORE), "archive", revision])
        subprocess.run(["tar", "-xf", "-", "-C", str(source)], input=archive, check=True)
        print(f"Checking clean upstream source snapshot {revision}", flush=True)
        core_env = {**env, "MIX_ENV": "test"}
        core_lock = (source / "mix.lock").read_bytes()
        for command in (["mix", "deps.get"], ["mix", "format", "--check-formatted"],
                        ["mix", "compile", "--warnings-as-errors"], ["mix", "test"],
                        ["mix", "docs", "--warnings-as-errors"]):
            print("Upstream:", " ".join(command), flush=True)
            run(command, source, core_env)
        if core_lock != (source / "mix.lock").read_bytes():
            raise RuntimeError("Upstream lock changed during snapshot verification")
        run(["mix", "hex.build", "--output", str(tarballs / "wotex-0.1.0.tar")], source, env)
        revisions = {"wotex": revision}
        if service:
            for repository, package in [("wotex-runtime", "wotex_runtime"), ("wotex-binding-http", "wotex_binding_http")]:
                sibling = ROOT.parent / repository
                target = workspace / repository
                target.mkdir()
                head = subprocess.check_output(["git", "-C", str(sibling), "rev-parse", "HEAD"], text=True).strip()
                archive = subprocess.check_output(["git", "-C", str(sibling), "archive", head])
                subprocess.run(["tar", "-xf", "-", "-C", str(target)], input=archive, check=True)
                revisions[package] = head
                lock = (target / "mix.lock").read_bytes()
                snapshot_env = {**core_env, "WOTEX_PATH_DEPS": "1"}
                for command in (["mix", "deps.get"], ["mix", "check", "--no-retry"],
                                ["mix", "docs", "--warnings-as-errors"], ["elixir", "bin/check_boundary.exs"]):
                    print(f"Upstream {package}@{head}:", " ".join(command), flush=True)
                    run(command, target, snapshot_env)
                if lock != (target / "mix.lock").read_bytes():
                    raise RuntimeError(f"{package} lock changed during snapshot verification")
                run(["mix", "hex.build", "--output", str(tarballs / f"{package}-0.1.0.tar")], target, env)
        run(["mix", "hex.build", "--output", str(tarballs / "wotex_tracker-0.1.0.tar")], ROOT, env)
        packages = ["jason-1.4.5", "ex_json_schema-0.11.5", "decimal-3.1.1", "jason-1.4.0", "ex_json_schema-0.11.0", "decimal-2.0.0"]
        if service:
            run(["mix", "hex.build", "--output", str(tarballs / "wotex_tracker_service-0.1.0.tar")], ROOT / "packages/tracker_service", env)
            packages += ["exqlite-0.40.0", "db_connection-2.10.2", "telemetry-1.4.2", "elixir_make-0.10.0", "cc_precompiler-0.1.11"]
            packages += ["bandit-1.12.5", "plug-1.20.3", "thousand_island-1.5.0", "hpax-1.0.4", "mime-2.0.7", "plug_crypto-2.2.0", "websock-0.5.3"]
            packages += ["mint-1.10.0"]
        for package in packages:
            run(["mix", "hex.package", "fetch", package.rsplit("-", 1)[0], package.rsplit("-", 1)[1],
                 "--output", str(workspace / "downloads")], ROOT, env)
            shutil.copyfile(workspace / "downloads" / f"{package}.tar", tarballs / f"{package}.tar")
        key = workspace / "registry-key.pem"
        subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(["mix", "hex.registry", "build", str(registry), "--name", "hexpm", "--private-key", str(key)], ROOT, env)
        handler = lambda *args, **kwargs: QuietHandler(*args, directory=str(registry), **kwargs)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        results = []
        try:
            for lane in LANES:
                for mode in ("fresh", "locked", "minimum"):
                    consumer = workspace / f"consumer-{lane[0]}-{mode}"
                    consumer.mkdir()
                    consumer_env = {**env, "HEX_HOME": str(consumer / "hex-home")}
                    run(["mix", "hex.repo", "set", "hexpm", "--url", f"http://127.0.0.1:{server.server_port}",
                         "--public-key", str(registry / "public_key")], ROOT, consumer_env, lane)
                    (consumer / "mix.exs").write_text('''defmodule ArchiveConsumer.MixProject do
  use Mix.Project
  def project, do: [app: :archive_consumer, version: "0.0.0", elixir: "~> 1.18",
    deps: [{:wotex_tracker, "~> 0.1.0"}]]
  def application, do: []
end
''')
                    if mode == "minimum":
                        project = (consumer / "mix.exs").read_text().replace(
                            'deps: [{:wotex_tracker, "~> 0.1.0"}]',
                            'deps: [{:wotex_tracker, "~> 0.1.0"}, {:jason, "1.4.0"}, {:ex_json_schema, "0.11.0"}, {:decimal, "2.0.0"}]')
                        (consumer / "mix.exs").write_text(project)
                    if service:
                        consumer_env["WTR_HTTP_PYTHON"] = str(ROOT / "_build/openapi-venv/bin/python")
                        consumer_env["WTR_HTTP_CONSUMER"] = str(ROOT / "scripts/http_consumer.py")
                        project = (consumer / "mix.exs").read_text().replace(
                            '{:wotex_tracker, "~> 0.1.0"}', '{:wotex_tracker_service, "~> 0.1.0"}')
                        (consumer / "mix.exs").write_text(project)
                        (consumer / "config").mkdir()
                        (consumer / "config/config.exs").write_text('import Config\nconfig :exqlite, force_build: true\n')
                    if mode == "locked":
                        shutil.copyfile(workspace / f"consumer-{lane[0]}-fresh" / "mix.lock", consumer / "mix.lock")
                    print(f"Consumer {lane}: {mode}", flush=True)
                    run(["mix", "deps.get"], consumer, consumer_env, lane)
                    lock_before = (consumer / "mix.lock").read_bytes()
                    run(["mix", "compile", "--warnings-as-errors"], consumer, consumer_env, lane)
                    output = run(["mix", "run", str(ROOT / "scripts" / "source_consumer.exs")], consumer, consumer_env, lane)
                    if "SOURCE_COHORT_PASS" not in output or lock_before != (consumer / "mix.lock").read_bytes():
                        raise RuntimeError("Consumer contract or immutable lock check failed")
                    print(output.strip(), flush=True)
                    if service:
                        output = run(["mix", "run", str(ROOT / "scripts" / "service_consumer.exs")], consumer, consumer_env, lane)
                        if "SERVICE_COHORT_PASS" not in output:
                            raise RuntimeError("Service consumer contract failed")
                        print(output.strip(), flush=True)
                    results.append({"elixir": lane[0], "otp": lane[1], "mode": mode, "result": "pass", "lock_sha256": hashlib.sha256(lock_before).hexdigest()})
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        report = {"scope": "local-source-cohort-not-public-release", "upstream_revision": revision,
                  "upstream_revisions": revisions,
                  "archives": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(tarballs.glob("*.tar"))},
                  "consumers": results}
        destination = ROOT / "_build" / "verification"
        destination.mkdir(parents=True, exist_ok=True)
        report_name = "service-consumer.json" if service else "source-consumer.json"
        (destination / report_name).write_text(json.dumps(report, indent=2) + "\n")
        print(f"Recorded _build/verification/{report_name}; temporary registry and keys removed on exit", flush=True)


if __name__ == "__main__":
    main()
