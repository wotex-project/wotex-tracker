#!/usr/bin/env python3
"""Independent HTTP/SSE acceptance client. Descriptor is a private fixture file.

Uses only the versioned wire contract; never imports Elixir/repository domain code.
"""
import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from jsonschema import Draft202012Validator
from openapi_spec_validator import validate


def main():
    descriptor = json.loads(Path(sys.argv[1]).read_text())
    base = descriptor["url"]
    prefix = "/api/v1/scopes/" + urllib.parse.quote(descriptor["scope"], safe="")
    spec = json.load(urllib.request.urlopen(base + "/api/v1/openapi.json", timeout=5))
    validate(spec)
    assert spec["openapi"] == "3.1.0"
    operations = {operation["operationId"]: operation for path in spec["paths"].values() for operation in path.values()}

    def check(schema, value):
        Draft202012Validator({**schema, "components": spec["components"]}).validate(value)

    def headers(who):
        return {} if who is None else {"Authorization": "Bearer " + descriptor[who]}

    def request(name, path, body=None, who="token", status=200, operation=None, raw=None, validate_body=True,
                extra_headers=None, method=None):
        contract = operations[name]
        fields = headers(who)
        data = raw
        if body is not None:
            if validate_body:
                check(contract["requestBody"]["content"]["application/json"]["schema"], body)
            data = json.dumps(body, separators=(",", ":")).encode()
        if data is not None:
            fields["Content-Type"] = "application/json"
            fields["Idempotency-Key"] = operation or str(uuid.uuid4())
        fields.update(extra_headers or {})
        req = urllib.request.Request(base + path, data=data, headers=fields, method=method)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            assert response.status == status, (name, response.status, status)
            payload = response.read(4_194_305)
            assert len(payload) <= 4_194_304
            value = json.loads(payload)
            response_schema = contract["responses"].get(str(status), contract["responses"]["default"])
            media, schema = next(iter(response_schema["content"].items()))
            assert response.headers.get_content_type() == media
            check(schema["schema"], value)
            assert response.headers["Cache-Control"] == "no-store"
            assert response.headers["X-Content-Type-Options"] == "nosniff"
            return value, payload

    def data(*args, **kwargs):
        return request(*args, **kwargs)[0]["data"]

    assert data("liveness", "/health/live", who=None)["status"] == "live"
    request("capabilities", prefix + "/capabilities", who=None, status=401)
    assert data("capabilities", prefix + "/capabilities")["ble_scan"] == "unsupported"
    request("capabilities", prefix + "/capabilities", extra_headers={"Authorization": "bearer " + descriptor["token"]})
    request("capabilities", prefix + "/capabilities", extra_headers={"Authorization": "Basic invalid"}, status=401)
    request("capabilities", prefix + "/capabilities", extra_headers={"Authorization": "malformed"}, status=401)
    assert data("readiness", prefix + "/health/ready")["writable"]
    snapshot = data("list_state", prefix + "/state", who="reader")
    assert snapshot["generation"] == "0"

    observation = {"schema": "wtr.observation.v1", "id": "private-client-observation",
        "observed_at": descriptor["now"], "ingress": "ble",
        "source": {"integer": 1, "float": 1.0, "wide": 9007199254740993, "zero": 0, "false": False, "null": None},
        "addressing": {"mac": "private-hardware"}, "radio": {},
        "transport": {"manufacturer_id": 1177}, "provenance": {"kind": "fixture"},
        "payload": {"kind": "bytes", "encoding": "base64", "data": base64.b64encode(bytes.fromhex(
            "0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")).decode()}}
    body = {"observation": observation, "expected_generation": "0"}
    denied, _ = request("import_observation", prefix + "/observations", body, who=None, status=401)
    assert denied["error"]["outcome"] == "not_committed"
    request("import_observation", prefix + "/observations", body, who="reader", status=403)
    request("import_observation", prefix + "/observations", body, operation="not-uuid", status=400)
    request("import_observation", prefix + "/observations", body, extra_headers={"Content-Type": "text/plain"}, status=415)
    request("import_observation", prefix + "/observations", body, extra_headers={"Content-Encoding": "gzip"}, status=415)
    request("import_observation", prefix + "/observations", body, extra_headers={"Accept": "application/xml"}, status=406)
    request("list_state", prefix + "/state", extra_headers={"Accept": "application/json;q=0, */*;q=1"}, status=406)
    request("list_state", prefix + "/state", extra_headers={"Accept": "text/plain, application/*;q=0.8"})
    request("capabilities", prefix + "/capabilities", method="DELETE", status=405)
    request("get_things", prefix + "/things/missing", status=404)
    request("list_state", prefix + "/state?limit=101", status=400)
    request("list_state", prefix + "/state?limit=bad", status=400)
    request("list_state", prefix + "/state?limit=1")
    request("get_state", prefix + "/state/missing?extra=true", status=400)
    request("stream_events", prefix + "/events/stream", status=400)
    operation = str(uuid.uuid4())
    imported = data("import_observation", prefix + "/observations", body, operation=operation)
    assert imported["generation"] == "1"
    assert data("import_observation", prefix + "/observations", body, operation=operation) == imported
    assert data("operation_status", prefix + "/operations/" + operation) == imported
    changed = {**body, "expected_generation": "1"}
    request("import_observation", prefix + "/observations", changed, operation=operation, status=409)
    public_id = imported["data"]["observation_id"]
    page, public_bytes = request("list_observations", prefix + "/observations")
    for private in (b"private-client-observation", b"private-hardware", b"9007199254740993", b"payload"):
        assert private not in public_bytes
    assert page["data"]["items"][0]["id"] == public_id
    raw_path = prefix + "/observations/" + public_id + "/raw"
    request("export_observation", raw_path, who="reader", status=403)
    exported, raw_bytes = request("export_observation", raw_path)
    assert exported == observation
    assert b'"float":1.0' in raw_bytes and b'"integer":1' in raw_bytes
    assert b'"wide":9007199254740993' in raw_bytes
    state = data("get_state", prefix + "/state/" + public_id)["value"]
    temperature = next(v for v in state["measurements"] if v["kind"] == "temperature")
    assert temperature["value"] == {"type": "number", "value": 24.3}
    enrolled = data("enroll", prefix + "/enrollments", {"observation_id": public_id,
        "title": "Independent client sensor", "owner_confirmed": True, "expected_generation": "1"})
    thing = enrolled["data"]["thing_id"]
    materialized = data("materialize", prefix + "/materialisations", {"thing_id": thing, "expected_generation": "2"})
    assert materialized["generation"] == "3"
    replay = data("replay_events", prefix + "/events?" + urllib.parse.urlencode({"cursor": snapshot["stream_cursor"]}), who="reader")
    assert [event["id"] for event in replay["items"]] == ["1", "2", "3"]
    request("replay_events", prefix + "/events?cursor=wtrc1.invalid", status=400)
    thing_path = prefix + "/things/" + urllib.parse.quote(thing, safe="")
    td = data("get_things", thing_path)["value"]
    assert td["id"] == thing and len(td["properties"]) == 10
    assert td["properties"]["temperature"]["forms"][0]["href"] == base + thing_path + "/properties/temperature"
    value, _ = request("read_property", thing_path + "/properties/temperature", who="reader")
    assert value == 24.3
    value, _ = request("read_property", thing_path + "/properties/pressure", who="reader")
    assert value == 100044
    request("read_property", thing_path + "/properties/missing", who="reader", status=404)
    request("read_property", thing_path + "/properties/temperature", who=None, status=401)
    evidence, _ = request("export_evidence", prefix + "/evidence/" + urllib.parse.quote(thing, safe="") + "/raw")
    assert any(e["claim"].get("strategy") == "operator-pseudonym-v1" for e in evidence)

    def stream(cursor, resume=False):
        fields = {**headers("reader"), "Accept": "text/event-stream"}
        path = prefix + "/events/stream"
        if resume:
            fields["Last-Event-ID"] = cursor
        else:
            path += "?" + urllib.parse.urlencode({"cursor": cursor})
        response = urllib.request.urlopen(urllib.request.Request(base + path, headers=fields), timeout=5)
        assert response.status == 200 and response.headers.get_content_type() == "text/event-stream"
        return response

    def frame(response):
        fields = {}
        size = 0
        while True:
            line = response.readline(32769)
            size += len(line)
            assert size <= 32768
            if not line:
                return None
            if line == b"\n":
                if fields:
                    return fields
                size = 0
            elif not line.startswith(b":"):
                key, value = line.decode().rstrip("\n").split(":", 1)
                fields[key] = value.lstrip(" ")

    with stream(snapshot["stream_cursor"]) as response:
        assert frame(response)["event"] == "ready"
        events = []
        for _ in range(3):
            event = frame(response)
            assert event["event"] == "tracker"
            value = json.loads(event["data"])
            check(spec["components"]["schemas"]["Event"], value)
            assert event["id"] == value["cursor"]
            events.append(value)
        assert [event["id"] for event in events] == ["1", "2", "3"]
    with stream(events[1]["cursor"], resume=True) as response:
        assert frame(response)["event"] == "ready"
        replayed = json.loads(frame(response)["data"])
        assert replayed["id"] == events[2]["id"]
        data("revoke", prefix + "/revocations", {"credential_id": "reader", "expected_generation": "3"})
        assert frame(response) is None
    request("list_state", prefix + "/state", who="reader", status=401)
    request("capabilities", "/api/v9/scopes/workshop/capabilities", status=404)
    request("list_state", prefix + "/state?limit=01", status=400)
    request("list_state", prefix + "/state?limit=1&limit=2", status=400)
    request("list_state", prefix + "/state?token=forbidden", status=400)
    request("import_observation", prefix + "/observations", raw=b'{"observation":{},"observation":{}}', status=400)
    request("import_observation", prefix + "/observations", raw=b" " * 1_048_577, status=400)
    wide_observation = {**observation, "id": "wide-clock-fixture", "ingress": "imported",
        "observed_at": 9007199254740993,
        "payload": {"kind": "json", "value": {"integer": 1, "float": 1.0, "false": False, "null": None}}}
    wide = data("import_observation", prefix + "/observations",
                {"observation": wide_observation, "expected_generation": "4"})
    wide_id = wide["data"]["observation_id"]
    projection = data("get_observations", prefix + "/observations/" + wide_id)["value"]
    assert projection["observed_at"] == {"type": "wide_integer", "value": "9007199254740993"}
    exported, raw_bytes = request("export_observation", prefix + "/observations/" + wide_id + "/raw")
    assert exported == wide_observation and b'"float":1.0' in raw_bytes
    state_path = prefix + "/state/" + urllib.parse.quote(thing, safe="")
    for generation in ("5", "6"):
        data("materialize", prefix + "/materialisations", {"thing_id": thing, "expected_generation": generation})
    history = data("history_state", state_path + "/history?limit=1")
    assert history["generation"] == "7" and [item["generation"] for item in history["items"]] == ["3"]
    data("materialize", prefix + "/materialisations", {"thing_id": thing, "expected_generation": "7"})
    versions = list(history["items"])
    cursor = history["cursor"]
    while cursor:
        page = data("history_state", state_path + "/history?" + urllib.parse.urlencode({"cursor": cursor}))
        assert page["generation"] == "7"
        versions += page["items"]
        cursor = page["cursor"]
    assert [item["generation"] for item in versions] == ["3", "6", "7"]
    assert all(item["deleted"] is False and item["value"]["id"] == thing for item in versions)
    pending = data("replay_events", prefix + "/events?" + urllib.parse.urlencode({"cursor": page["stream_cursor"]}))
    assert [event["generation"] for event in pending["items"]] == ["8"]
    request("history_state", state_path + "/history", who="reader", status=401)
    request("history_things", thing_path + "/history?" + urllib.parse.urlencode({"cursor": history["cursor"]}), status=400)
    request("history_state", state_path + "/history?limit=101", status=400)
    request("history_state", prefix + "/state/missing/history", status=404)
    wide_history = data("history_observations", prefix + "/observations/" + wide_id + "/history")
    assert wide_history["items"][0]["value"]["observed_at"]["value"] == "9007199254740993"
    observe_path = thing_path + "/properties/temperature/observe"
    request("observe_property", observe_path, who=None, status=401)
    request("observe_property", observe_path, who="reader", status=401)
    request("observe_property", thing_path + "/properties/missing/observe", status=404)
    request("observe_property", observe_path + "?cursor=wtrc1.invalid", status=400)
    request("observe_property", observe_path + "?" + urllib.parse.urlencode({"cursor": page["stream_cursor"]}), status=400)
    assert td["properties"]["temperature"]["observable"] is True
    assert td["properties"]["temperature"]["forms"][1]["op"] == ["observeproperty", "unobserveproperty"]

    def property_stream(cursor=None, resume=False):
        fields = {**headers("token"), "Accept": "text/event-stream"}
        path = observe_path
        if cursor:
            if resume:
                fields["Last-Event-ID"] = cursor
            else:
                path += "?" + urllib.parse.urlencode({"cursor": cursor})
        response = urllib.request.urlopen(urllib.request.Request(base + path, headers=fields), timeout=5)
        assert response.status == 200 and response.headers.get_content_type() == "text/event-stream"
        return response

    with property_stream() as response:
        first = frame(response)
        assert first["event"] == "property:snapshot:8:8"
        assert json.loads(first["data"]) == 24.3
        check(td["properties"]["temperature"], json.loads(first["data"]))
        data("materialize", prefix + "/materialisations", {"thing_id": thing, "expected_generation": "8"})
        updated = frame(response)
        assert updated["event"] == "property:event:9:9"
        assert json.loads(updated["data"]) == 24.3
    for resume in (False, True):
        with property_stream(first["id"], resume=resume) as response:
            replayed = frame(response)
            assert (replayed["event"], replayed["data"]) == (updated["event"], updated["data"])
    request("observe_property", thing_path + "/properties/pressure/observe?" + urllib.parse.urlencode({"cursor": first["id"]}), status=400)
    request("observe_property", observe_path + "?" + urllib.parse.urlencode({"cursor": first["id"]}),
            extra_headers={"Last-Event-ID": first["id"]}, status=400)
    print("HTTP_CONSUMER_PASS openapi=true enrollment=true materialisation=true native_types=true history=true replay=true revoked_stream_closed=true property_observation=true")



if __name__ == "__main__":
    main()
