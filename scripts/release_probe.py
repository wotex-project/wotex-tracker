#!/usr/bin/env python3
"""Black-box bundled-release lifecycle proof; no BEAM tools or source imports."""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def write_json(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as target:
        json.dump(value, target)


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class Instance:
    def __init__(self, release, directory):
        self.release, self.directory = release, directory
        self.process, self.log = None, None
        self.port = available_port()
        result = subprocess.run([str(release / "bin/trackerctl"), "--scope", "workshop", "init",
            "--directory", str(directory), "--instance-id", str(uuid.uuid4()), "--bind", "127.0.0.1",
            "--port", str(self.port)], capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise RuntimeError("release CLI initialization failed")
        descriptor = json.loads(result.stdout)
        self.config = Path(descriptor["config"])
        self.token = Path(descriptor["token_file"]).read_text().strip()
        self.reader = secrets.token_urlsafe(32)
        self.document = json.loads(self.config.read_bytes())
        self.document["credentials"][0]["id"] = "admin"
        self.document["credentials"].append({"id": "reader", "principal": "reader",
            "token_sha256": hashlib.sha256(self.reader.encode()).hexdigest(),
            "grants": {"workshop": ["read"]}, "expires_at": int(time.time() * 1000) + 3_600_000})
        self.origin = f"http://127.0.0.1:{self.port}"
        self.descriptor = directory / "client.json"
        write_json(self.descriptor, {"url": self.origin, "scope": "workshop", "token": self.token,
            "reader": self.reader, "now": int(time.time() * 1000)})

    def start(self, expected_failure=False):
        write_json(self.config, self.document)
        self.log = open(self.directory / "release.log", "ab")
        self.process = subprocess.Popen([str(self.release / "bin/wotex_tracker"), "start"],
            stdout=self.log, stderr=subprocess.STDOUT,
            env={**os.environ, "WOTEX_TRACKER_CONFIG": str(self.config)}, start_new_session=True)
        if expected_failure:
            try:
                code = self.process.wait(timeout=10)
                if code == 0:
                    raise RuntimeError("invalid storage unexpectedly started")
            finally:
                self.stop()
            self.redacted()
            return
        until = time.monotonic() + 20
        while time.monotonic() < until:
            if self.process.poll() is not None:
                self.redacted()
                raise RuntimeError("bundled release exited before readiness")
            try:
                with urllib.request.urlopen(self.origin + "/health/live", timeout=1) as response:
                    if response.status == 200:
                        return
            except (OSError, urllib.error.URLError):
                time.sleep(0.1)
        raise RuntimeError("bundled release startup exceeded 20 seconds")

    def stop(self, crash=False):
        started = time.monotonic()
        if self.process and self.process.poll() is None:
            self.process.send_signal(signal.SIGKILL if crash else signal.SIGTERM)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
                raise RuntimeError("bundled release shutdown exceeded ten seconds")
        if self.log:
            self.log.close()
            self.log = None
        return time.monotonic() - started

    def redacted(self):
        log = self.directory / "release.log"
        if log.exists():
            data = log.read_bytes()
            for secret in (self.token, self.reader, self.document["secret_key"]):
                if secret.encode() in data:
                    raise RuntimeError("release log failed secret redaction")

    def request(self, path, body=None, operation=None, expected=200, token=None):
        headers = {"Authorization": "Bearer " + (token or self.token), "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode()
            headers.update({"Content-Type": "application/json", "Idempotency-Key": operation or str(uuid.uuid4())})
        request = urllib.request.Request(self.origin + "/api/v1/scopes/workshop" + path, data=data, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            if response.status != expected:
                raise RuntimeError("release returned an unexpected HTTP status")
            document = json.loads(response.read(4_194_305))
            if document.get("schema") != "wtr.response.v1":
                raise RuntimeError("release returned an unexpected API version")
            return document.get("data") if expected < 400 else document["error"]


def lifecycle(release, root):
    instance = Instance(release, root / "persistent")
    try:
        instance.start()
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("http_consumer.py")),
            str(instance.descriptor)], capture_output=True, text=True, timeout=30)
        if result.returncode or "HTTP_CONSUMER_PASS" not in result.stdout:
            raise RuntimeError("independent artifact HTTP/OpenAPI/SSE workflow failed")
        thing = instance.request("/things")["items"][0]["id"]
        operation = str(uuid.uuid4())
        request = {"thing_id": thing, "expected_generation": "8"}
        receipt = instance.request("/materialisations", request, operation)
        snapshot = instance.request("/state")
        td = instance.request("/things/" + urllib.parse.quote(thing, safe=""))
        stream = urllib.request.urlopen(urllib.request.Request(instance.origin +
            "/api/v1/scopes/workshop/events/stream?" + urllib.parse.urlencode({"cursor": snapshot["stream_cursor"]}),
            headers={"Authorization": "Bearer " + instance.token, "Accept": "text/event-stream"}), timeout=5)
        for _ in range(8):
            line = stream.readline(32769)
            if not line or len(line) > 32768:
                raise RuntimeError("artifact stream did not provide a bounded ready frame")
            if line == b"\n":
                break
        else:
            raise RuntimeError("artifact stream ready frame exceeded its field ceiling")
        closed = threading.Event()

        def await_close():
            try:
                while stream.read(32768):
                    pass
                closed.set()
            except (ConnectionError, http.client.IncompleteRead, http.client.RemoteDisconnected):
                closed.set()
            except TimeoutError:
                pass

        watcher = threading.Thread(target=await_close)
        watcher.start()
        shutdown = instance.stop()
        watcher.join(timeout=5)
        stream.close()
        if not closed.is_set():
            raise RuntimeError("active artifact SSE stream survived shutdown")
        instance.start()
        if instance.request("/operations/" + operation) != receipt:
            raise RuntimeError("operation receipt changed after restart")
        if instance.request("/materialisations", request, operation) != receipt:
            raise RuntimeError("duplicate mutation changed after restart")
        if instance.request("/things/" + urllib.parse.quote(thing, safe="")) != td:
            raise RuntimeError("Thing changed after restart")
        if instance.request("/state")["generation"] != "9":
            raise RuntimeError("restart or duplicate mutation added a generation")
        if instance.request("/state", expected=401, token=instance.reader)["code"] != "unauthorized":
            raise RuntimeError("revocation was not retained")
        instance.stop(crash=True)
        instance.start()
        if instance.request("/operations/" + operation) != receipt:
            raise RuntimeError("committed receipt was lost after process kill")
        history = instance.request("/things/" + urllib.parse.quote(thing, safe="") + "/history")
        if [item["generation"] for item in history["items"]] != ["3", "6", "7", "8", "9"]:
            raise RuntimeError("historical versions changed after recovery")
        instance.stop()
        instance.redacted()
        return {"http_openapi_sse": "pass", "history": "pass", "sigterm_active_stream": "pass",
            "shutdown_seconds": round(shutdown, 3), "restart_and_idempotency": "pass",
            "sigkill_recovery": "pass", "retained_revocation": "pass"}
    finally:
        instance.stop()


def failures(release, root, readonly_directory):
    invalid = Instance(release, root / "invalid-storage")
    os.chmod(invalid.document["data_directory"], 0o755)
    invalid.start(expected_failure=True)
    full = Instance(release, root / "full-storage")
    full.document["storage_limits"] = {"max_pages": 16}
    try:
        full.start()
        observation = {"schema": "wtr.observation.v1", "id": "full-disk-fixture", "observed_at": 0,
            "ingress": "imported", "source": {}, "addressing": {}, "radio": {}, "transport": {}, "provenance": {},
            "payload": {"kind": "bytes", "encoding": "base64", "data": base64.b64encode(b"x" * 65_536).decode()}}
        error = full.request("/observations", {"observation": observation, "expected_generation": "0"}, expected=507)
        if error.get("code") != "storage_full" or error.get("outcome") != "not_committed":
            raise RuntimeError("full storage did not return a definite rollback")
        if full.request("/observations")["generation"] != "0":
            raise RuntimeError("full storage left a partial commit")
    finally:
        full.stop()
        full.redacted()
    readonly = "not-executed"
    if readonly_directory:
        instance = Instance(release, root / "readonly-storage")
        instance.document["data_directory"] = readonly_directory
        instance.start(expected_failure=True)
        readonly = "pass"
    return {"invalid_storage_permissions": "pass", "sqlite_full_rollback": "pass", "readonly_filesystem": readonly}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    parser.add_argument("fixtures", type=Path)
    parser.add_argument("--readonly-directory")
    args = parser.parse_args()
    if any(shutil.which(tool) for tool in ("elixir", "erl", "mix")):
        raise RuntimeError("release probe requires a PATH without external BEAM tools")
    for component in ("wotex_tracker_host", "wotex_tracker", "wotex_tracker_service", "wotex",
                      "wotex_runtime", "wotex_binding_http", "exqlite", "mint", "elixir",
                      "erlang-OTP-27.3.4.15"):
        directory = args.release / "licenses" / component
        if not directory.is_dir() or not list(directory.glob("LICENSE*")):
            raise RuntimeError("release omitted a runtime license")
    args.fixtures.mkdir(mode=0o700, parents=True, exist_ok=True)
    report = {"runtime_licenses": "pass", "external_beam_tools_absent": True, "external_compiler_absent": shutil.which("gcc") is None,
        **lifecycle(args.release.resolve(), args.fixtures.resolve()),
        **failures(args.release.resolve(), args.fixtures.resolve(), args.readonly_directory)}
    write_json(args.fixtures / "result.json", report)
    print("RELEASE_PROBE_PASS " + json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
