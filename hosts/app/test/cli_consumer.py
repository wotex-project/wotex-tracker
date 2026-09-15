#!/usr/bin/env python3
"""Independent subprocess CLI workflow against an actual host listener."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import uuid


def main():
    descriptor = json.loads(Path(sys.argv[1]).read_text())
    token = Path(descriptor["token_file"]).read_text().strip()
    base = [descriptor["cli"], "--url", descriptor["url"], "--scope", "workshop",
            "--token-file", descriptor["token_file"]]

    def call(*args, code=0):
        result = subprocess.run([*base, *args], capture_output=True, text=True, timeout=10)
        assert result.returncode == code, (args[0], result.returncode, result.stdout, result.stderr)
        assert token not in result.stdout and token not in result.stderr
        return [json.loads(line) for line in result.stdout.splitlines()]

    assert call("ready")[0]["data"]["writable"] is True
    assert call("capabilities")[0]["data"]["runtime"]["readproperty"] == "available"
    snapshot = call("list", "state")[0]["data"]
    path = Path(descriptor["token_file"]).parent / "observation.json"
    observation = {"schema": "wtr.observation.v1", "id": "cli-observation", "observed_at": 1700000000000,
        "ingress": "ble", "source": {"integer": 1, "float": 1.0, "wide": 9007199254740993},
        "addressing": {}, "radio": {}, "transport": {"manufacturer_id": 1177}, "provenance": {},
        "payload": {"kind": "bytes", "encoding": "base64", "data": base64.b64encode(bytes.fromhex(
            "0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")).decode("ascii")}}
    path.write_text(json.dumps(observation))
    operation = str(uuid.uuid4())
    receipt = call("import", str(path), "--generation", "0", "--operation", operation)[0]["data"]
    assert receipt["outcome"] == "committed"
    assert call("import", str(path), "--generation", "0", "--operation", operation)[0]["data"] == receipt
    assert call("operation", operation)[0]["data"] == receipt
    assert call("import", str(path), "--generation", "1", "--operation", operation, code=1)[0]["error"]["code"] == "idempotency_conflict"
    observation_id = receipt["data"]["observation_id"]
    assert call("inspect", "observations", observation_id)[0]["data"]["value"]["id"] == observation_id
    assert call("raw", "observations", observation_id)[0] == observation
    export = path.parent / "export.json"
    assert call("raw", "observations", observation_id, "--output", str(export)) == []
    assert json.loads(export.read_bytes()) == observation
    assert b'"integer":1' in export.read_bytes() and b'"float":1.0' in export.read_bytes()
    assert export.stat().st_mode & 0o777 == 0o600
    enrolled = call("enroll", observation_id, "--title", "CLI sensor", "--confirm", "--generation", "1")[0]["data"]
    thing = enrolled["data"]["thing_id"]
    call("materialize", thing, "--generation", "2")
    assert call("read", thing, "temperature")[0] == 24.3
    assert call("read", thing, "pressure")[0] == 100044
    assert call("read", thing, "missing", code=1)[0]["error"]["code"] == "not_found"
    replay = call("events", "--cursor", snapshot["stream_cursor"])[0]["data"]["items"]
    assert [event["id"] for event in replay] == ["1", "2", "3"]
    streamed = call("events", "--cursor", snapshot["stream_cursor"], "--stream", "--max-events", "3", "--seconds", "3")
    assert [event["id"] for event in streamed] == ["1", "2", "3"]
    call("materialize", thing, "--generation", "3")
    history = call("history", "things", thing, "--limit", "1")[0]["data"]
    assert history["items"][0]["generation"] == "3"
    assert call("history", "things", thing, "--cursor", history["cursor"])[0]["data"]["items"][0]["generation"] == "4"
    assert call("revoke", "operator", "--generation", "4")[0]["data"]["outcome"] == "committed"
    assert call("list", "things", code=1)[0]["error"]["code"] == "unauthorized"
    print("CLI_CONSUMER_PASS workflow=true history=true sse=true native_types=true self_revocation=true")


if __name__ == "__main__":
    main()
