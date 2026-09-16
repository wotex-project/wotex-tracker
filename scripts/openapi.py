#!/usr/bin/env python3
"""Build/check the versioned machine contract independently of the Elixir router.

Validation dependencies are pinned in requirements-openapi.txt. No network refs.
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "packages/tracker_service/priv/openapi/v1.json"


def obj(properties, optional=()):
    return {"type": "object", "properties": properties,
            "required": [key for key in properties if key not in optional],
            "additionalProperties": False}


def ref(name):
    return {"$ref": f"#/components/schemas/{name}"}


def array(items, maximum=100):
    return {"type": "array", "items": items, "maxItems": maximum}


def enum(*values):
    return {"enum": list(values)}


def envelope(value):
    return obj({"schema": {"const": "wtr.response.v1"}, "data": value})


def document():
    identifier = {"type": "string", "minLength": 1, "maxLength": 256, "x-max-utf8-bytes": 256}
    generation = {"type": "string", "pattern": "^(0|[1-9][0-9]{0,18})$",
                  "description": "Canonical decimal integer below 9223372036854775807."}
    uuid = {"type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"}
    thing = {**uuid, "pattern": "^urn:uuid:" + uuid["pattern"][1:]}
    cursor = {"type": "string", "minLength": 1, "maxLength": 4096,
              "pattern": "^wtrc1\\.[A-Za-z0-9_-]+$"}
    nullable_cursor = {"anyOf": [cursor, {"type": "null"}]}
    native_object = {"type": "object", "additionalProperties": ref("NativeJSON")}
    schemas = {
        "NativeJSON": {"anyOf": [{"type": ["null", "boolean", "number", "string"]},
                                 {"type": "array", "items": ref("NativeJSON")}, native_object]},
        "Scalar": {"oneOf": [obj({"type": {"const": tag}, "value": value}) for tag, value in [
            ("integer", {"type": "integer", "minimum": -9007199254740991, "maximum": 9007199254740991}),
            ("wide_integer", {"type": "string", "pattern": "^-?[1-9][0-9]*$"}),
            ("number", {"type": "number"}), ("boolean", {"type": "boolean"}), ("null", {"type": "null"})]]},
        "ObservationEnvelope": obj({
            "schema": {"const": "wtr.observation.v1"}, "id": identifier,
            "observed_at": {"type": "integer"}, "ingress": enum("ble", "cellular", "lorawan", "mqtt", "http", "serial", "imported"),
            **{key: native_object for key in ("source", "addressing", "radio", "transport", "provenance")},
            "payload": {"oneOf": [
                obj({"kind": {"const": "bytes"}, "encoding": {"const": "base64"},
                     "data": {"type": "string", "contentEncoding": "base64", "maxLength": 87384}}),
                obj({"kind": {"const": "json"}, "value": ref("NativeJSON")})]}}),
        "Observation": obj({"id": identifier, "observed_at": ref("Scalar"), "ingress": identifier}),
        "Resolution": obj({"status": enum("resolved", "unknown", "ambiguous"), "reason": identifier,
            "catalogue_identity": identifier, "candidates": array(obj({"id": identifier, "version": identifier,
                "confidence": enum("exact", "strong", "candidate", "unknown"), "reasons": array(identifier, 32)}), 256)}),
        "EvidenceSummary": obj({"id": identifier, "claim_count": {"type": "integer", "minimum": 0, "maximum": 256}}),
        "State": obj({"id": identifier, "observation_id": identifier, "observed_at": ref("Scalar"),
            "measurements": array(obj({"kind": identifier, "unit": identifier, "value": ref("Scalar"),
                "availability": enum("available", "unavailable"), "quality": enum("valid", "suspect", "unavailable")}), 256)}),
        "Enrollment": obj({"id": thing, "title": identifier, "observation_id": identifier,
            "owner_confirmed": {"const": True}, "identity_strategy": {"const": "operator-pseudonym-v1"}}),
        "Thing": {"type": "object", "required": ["@context", "id", "title", "properties", "security", "securityDefinitions"],
            "properties": {"id": thing, "title": identifier}, "additionalProperties": ref("NativeJSON"),
            "description": "TD 1.1, additionally validated by Wotex.ThingDescription; extensions are preserved."},
        "Evidence": obj({"schema": {"const": "wtr.evidence.v1"}, "id": identifier,
            "kind": enum("fingerprint", "identity", "capability", "measurement", "position", "transport"),
            "claim": native_object, "source_observation_ids": array(identifier, 64), "evidence_ids": array(identifier, 64),
            "profile": {**array(identifier, 2), "minItems": 2}, "decoder": {**array(identifier, 2), "minItems": 2},
            "confidence": enum("exact", "strong", "candidate", "unknown"), "reasons": array(identifier, 32),
            "association_id": {"anyOf": [identifier, {"type": "null"}]}}),
        "Event": obj({"schema": {"const": "wtr.event.v1"}, "id": generation, "generation": generation,
            "cursor": cursor, "event": obj({"type": enum("observation.admitted", "enrollment.changed", "thing.changed", "access.revoked"),
                "data": obj({"id": identifier, "status": enum("resolved", "unknown", "ambiguous")}, optional=("status",))})}),
        "Receipt": {"oneOf": [
            obj({"outcome": {"const": "unknown"}, "operation_id": uuid}),
            obj({"outcome": {"const": "committed"}, "operation_id": uuid, "generation": generation,
                 "disposition": enum("accepted", "duplicate"), "publication": {"type": "null"},
                 "data": {"oneOf": [obj({"observation_id": identifier}), obj({"thing_id": thing}),
                    obj({"thing_id": thing, "materialisation_id": identifier}), obj({"credential_id": identifier})]}})]},
        "Error": obj({"schema": {"const": "wtr.response.v1"}, "error": obj({
            "code": enum(*("unauthorized forbidden invalid_request invalid_observation invalid_cursor cursor_expired "
                "operation_expired not_found conflict idempotency_conflict observation_conflict unsupported unresolved unavailable deadline_exceeded "
                "revision_mismatch invalid_deployment invalid_materialisation storage_unavailable storage_full busy "
                "capacity_exceeded response_too_large overloaded invalid_query invalid_update invalid_json "
                "unsupported_media_type not_acceptable invalid_header unsupported_version method_not_allowed internal_error").split()),
            "path": {"const": "/"}, "outcome": enum("not_committed", "unknown"),
            "operation_id": {"anyOf": [uuid, {"type": "null"}]}
        }, optional=("outcome", "operation_id"))}),
        "ImportRequest": obj({"observation": ref("ObservationEnvelope"), "expected_generation": generation}),
        "EnrollmentRequest": obj({"observation_id": identifier, "title": identifier,
                                   "owner_confirmed": {"const": True}, "expected_generation": generation}),
        "AssociationRequest": obj({"thing_id": thing, "observation_id": identifier,
                                    "owner_confirmed": {"const": True}, "expected_generation": generation}),
        "MaterialisationRequest": obj({"thing_id": thing, "expected_generation": generation}),
        "RevocationRequest": obj({"credential_id": identifier, "expected_generation": generation}),
    }
    parameters = {
        "Scope": {"name": "scope", "in": "path", "required": True, "schema": identifier},
        "ID": {"name": "id", "in": "path", "required": True, "schema": identifier},
        "Property": {"name": "property", "in": "path", "required": True, "schema": identifier},
        "Operation": {"name": "operation", "in": "path", "required": True, "schema": uuid},
        "Idempotency": {"name": "Idempotency-Key", "in": "header", "required": True, "schema": uuid},
        "Limit": {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 100, "default": 25}},
        "Cursor": {"name": "cursor", "in": "query", "schema": cursor},
        "Resume": {"name": "Last-Event-ID", "in": "header", "schema": cursor},
    }

    def response(schema, media="application/json"):
        return {"description": "Response", "content": {media: {"schema": schema}}}

    def operation(name, result, params=(), body=None, public=False, media="application/json"):
        value = {"operationId": name, "parameters": [{"$ref": f"#/components/parameters/{p}"} for p in params],
                 "responses": {"200": response(result, media), "default": response(ref("Error"))}}
        if body:
            value["requestBody"] = {"required": True, "content": {"application/json": {"schema": ref(body)}},
                                    "description": "At most 1 MiB, UTF-8 JSON; duplicate keys and unknown fields are rejected."}
            value["responses"]["202"] = response(result)
        if public:
            value["security"] = []
        return value

    base = "/api/v1/scopes/{scope}"
    paths = {"/health/live": {"get": operation("liveness", envelope(obj({"status": {"const": "live"}})), public=True)}}
    paths[base + "/health/ready"] = {"get": operation("readiness", envelope(obj({"writable": {"const": True},
        "schema": {"const": "2"}, "sqlite": identifier})), ("Scope",))}
    paths[base + "/capabilities"] = {"get": operation("capabilities", envelope(obj({
        "api_version": {"const": "v1"}, "import": {"const": "available"},
        **{key: {"const": "unsupported"} for key in ("ble_scan", "cellular", "rules", "analytics")},
        "runtime": obj({"readproperty": {"const": "available"}, "observeproperty": {"const": "available"},
                        "invokeaction": {"const": "unsupported"}}),
        "directory": {"const": "unconfigured"}})), ("Scope",))}
    for resource, schema in [("observations", "Observation"), ("resolutions", "Resolution"),
                             ("evidence", "EvidenceSummary"), ("state", "State"),
                             ("enrollments", "Enrollment"), ("things", "Thing")]:
        item = obj({"id": identifier, "generation": generation, "value": ref(schema)})
        page = obj({"items": array(item), "generation": generation, "cursor": nullable_cursor, "stream_cursor": cursor})
        paths[base + "/" + resource] = {"get": operation("list_" + resource, envelope(page), ("Scope", "Limit", "Cursor"))}
        paths[base + "/" + resource + "/{id}"] = {"get": operation("get_" + resource, envelope(item), ("Scope", "ID"))}
        version = {"oneOf": [obj({**item["properties"], "deleted": {"const": False}}),
                              obj({"id": identifier, "generation": generation, "deleted": {"const": True}, "value": {"type": "null"}})]}
        history = obj({"items": array(version), "generation": generation, "cursor": nullable_cursor, "stream_cursor": cursor})
        paths[base + "/" + resource + "/{id}/history"] = {"get": operation("history_" + resource,
            envelope(history), ("Scope", "ID", "Limit", "Cursor"))}
        paths[base + "/" + resource + "/{id}/history"]["get"]["description"] = (
            "Ascending immutable committed resource versions, including explicit deletion tombstones. "
            "Cursor binds principal, scope, resource, ID, snapshot generation and page size for seven days. "
            "Later commits are excluded; stream_cursor starts after the same snapshot. Missing history returns 404. "
            "Record storage has a fixed capacity and no automatic historical deletion in schema 2.")
    property_read = operation("read_property", {"type": ["number", "boolean"],
        "description": "Native JSON scalar constrained by the selected TD Property. Unavailable measurements return 503, never a numeric null. Requires read authority."},
        ("Scope", "ID", "Property"))
    property_read["responses"]["200"]["headers"] = {"X-Wotex-Generation": {
        "description": "Committed snapshot generation shared by TD and state", "schema": generation}}
    paths[base + "/things/{id}/properties/{property}"] = {"get": property_read}
    paths[base + "/things/{id}/properties/{property}/observe"] = {"get": operation(
        "observe_property", {"type": "string", "description":
            "Bounded SSE of native JSON scalars constrained by the selected observable TD Property. "
            "Without a cursor, sends the current committed value and then every committed Thing update. "
            "Supply at most one cursor or Last-Event-ID to resume after an acknowledged sample. "
            "The id field is an encrypted cursor bound to principal, scope, Thing and Property. "
            "The event field is property:snapshot:<generation>:<generation> for the initial sample, "
            "or property:event:<event-id>:<generation> for an update; this stable metadata supports deduplication. "
            "The data field contains only the native Property value, without an envelope. "
            "No physical sensor subscription or automatic reconnect is implied. "
            "Requires read authority; missing returns 404, unavailable 503, unsupported 501 before headers. "
            "Authorization, availability gaps, retention or storage failures close an established stream. "
            "Use a fresh snapshot after a gap or expired cursor. At most 300 seconds, 32 KiB per frame, "
            "16 instance-wide streams shared with events/stream; polling is at most one second."},
        ("Scope", "ID", "Property", "Cursor", "Resume"), media="text/event-stream")}
    for path, name, body in [("observations", "import_observation", "ImportRequest"),
                             ("enrollments", "enroll", "EnrollmentRequest"),
                             ("associations", "associate", "AssociationRequest"),
                             ("materialisations", "materialize", "MaterialisationRequest"),
                             ("revocations", "revoke", "RevocationRequest")]:
        paths.setdefault(base + "/" + path, {})["post"] = operation(name, envelope(ref("Receipt")), ("Scope", "Idempotency"), body)
    paths[base + "/operations/{operation}"] = {"get": operation("operation_status", envelope(ref("Receipt")), ("Scope", "Operation"))}
    paths[base + "/observations/{id}/raw"] = {"get": operation("export_observation", ref("ObservationEnvelope"),
        ("Scope", "ID"), media="application/vnd.wotex.tracker.observation+json")}
    paths[base + "/evidence/{id}/raw"] = {"get": operation("export_evidence", array(ref("Evidence"), 256),
        ("Scope", "ID"), media="application/vnd.wotex.tracker.evidence+json")}
    paths[base + "/events"] = {"get": operation("replay_events", envelope(obj({"items": array(ref("Event")), "cursor": cursor})), ("Scope", "Cursor"))}
    paths[base + "/events/stream"] = {"get": operation("stream_events", {"type": "string",
        "description": "SSE: event tracker has Event JSON data. id is the encrypted transport cursor; deduplicate data.id. "
                       "An initial ready event has schema wtr.stream.v1 and cursor; comment heartbeats carry no domain event. "
                       "Supply exactly one of cursor or Last-Event-ID. Errors before headers are JSON. "
                       "After headers, authorization/retention/storage failure closes the connection. Resnapshot on expired cursors. "
                       "Connection lifetime 300 s; idle reauthorization/poll 1 s; no unlimited queue."},
        ("Scope", "Cursor", "Resume"), media="text/event-stream")}
    paths["/api/v1/openapi.json"] = {"get": operation("openapi", {"type": "object"}, public=True)}
    return {"openapi": "3.1.0", "info": {"title": "WoTEx Tracker service", "version": "1.3.0",
        "description": "Authenticated imported-observation foundation. No scanner, rules, analytics or physical interaction is implied."},
        "jsonSchemaDialect": "https://json-schema.org/draft/2020-12/schema", "security": [{"bearer": []}],
        "paths": paths, "components": {"securitySchemes": {"bearer": {"type": "http", "scheme": "bearer"}},
                                       "parameters": parameters, "schemas": schemas}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    spec = document()
    from openapi_spec_validator import validate
    validate(spec)
    encoded = json.dumps(spec, ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if TARGET.read_text() != encoded:
            raise SystemExit("Packaged OpenAPI differs from the versioned contract")
    else:
        TARGET.parent.mkdir(parents=True, exist_ok=True)
        TARGET.write_text(encoded)
    print("OpenAPI 3.1.0 contract validated")
