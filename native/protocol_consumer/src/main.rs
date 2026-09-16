use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

const LIMIT: usize = 4_194_304;
const PAYLOAD: &str = "BRL8U5TDfAAE//wEDKw2QgDNy7gzTIhP";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = env::args()
        .nth(1)
        .ok_or("usage: protocol-consumer DESCRIPTOR")?;
    let descriptor: Value = serde_json::from_slice(&fs::read(path)?)?;
    let origin = descriptor["url"].as_str().ok_or("missing URL")?;
    let address: SocketAddr = origin
        .strip_prefix("http://")
        .ok_or("expected a plain loopback origin")?
        .parse()?;
    if !address.ip().is_loopback() {
        return Err("the fixture must use loopback".into());
    }

    let scope = descriptor["scope"].as_str().ok_or("missing scope")?;
    let token = descriptor["token"]
        .as_str()
        .ok_or("missing operator token")?;
    let reader = descriptor["reader"]
        .as_str()
        .ok_or("missing reader token")?;
    let client = Client { address, token };
    let prefix = format!("/api/v1/scopes/{scope}");

    let spec = client.call("GET", "/api/v1/openapi.json", None, None, None, 200)?;
    assert_eq!(spec["openapi"], "3.1.0");
    assert!(spec["paths"]["/api/v1/scopes/{scope}/observations"].is_object());
    assert_eq!(
        client.call(
            "GET",
            &format!("{prefix}/capabilities"),
            Some(""),
            None,
            None,
            401
        )?["error"]["code"],
        "unauthorized"
    );
    let initial = client.call(
        "GET",
        &format!("{prefix}/state"),
        Some(reader),
        None,
        None,
        200,
    )?;
    assert_eq!(initial["data"]["generation"], "0");
    let cursor = initial["data"]["stream_cursor"]
        .as_str()
        .ok_or("missing cursor")?;

    let observation = json!({
        "schema": "wtr.observation.v1",
        "id": "native-client-observation",
        "observed_at": 1_700_000_000_000_i64,
        "ingress": "ble",
        "source": {"integer": 1, "float": 1.0, "wide": 9_007_199_254_740_993_i64,
                   "zero": 0, "false": false, "null": null},
        "addressing": {"mac": "private-native-fixture"},
        "radio": {},
        "transport": {"manufacturer_id": 1177},
        "provenance": {"kind": "fixture"},
        "payload": {"kind": "bytes", "encoding": "base64", "data": PAYLOAD}
    });
    let import = json!({"observation": observation, "expected_generation": "0"});
    let import_path = format!("{prefix}/observations");
    let import_key = "00000000-0000-4000-8000-000000000001";
    assert_eq!(
        client.call(
            "POST",
            &import_path,
            Some(reader),
            Some(&import),
            Some(import_key),
            403
        )?["error"]["code"],
        "forbidden"
    );
    let imported = client.call(
        "POST",
        &import_path,
        None,
        Some(&import),
        Some(import_key),
        200,
    )?;
    assert_eq!(imported["data"]["generation"], "1");
    assert_eq!(
        client.call(
            "POST",
            &import_path,
            None,
            Some(&import),
            Some(import_key),
            200
        )?,
        imported
    );
    assert_eq!(
        client.call(
            "GET",
            &format!("{prefix}/operations/{import_key}"),
            None,
            None,
            None,
            200
        )?["data"],
        imported["data"]
    );
    let observation_id = imported["data"]["data"]["observation_id"]
        .as_str()
        .ok_or("missing observation ID")?;

    let raw = client.call(
        "GET",
        &format!("{prefix}/observations/{observation_id}/raw"),
        None,
        None,
        None,
        200,
    )?;
    assert_eq!(raw["source"]["integer"], 1);
    assert_eq!(raw["source"]["float"], 1.0);
    assert_eq!(raw["source"]["wide"], 9_007_199_254_740_993_i64);
    assert_eq!(raw["source"]["false"], false);
    assert!(raw["source"]["null"].is_null());

    let enrolled = client.call(
        "POST",
        &format!("{prefix}/enrollments"),
        None,
        Some(
            &json!({"observation_id": observation_id, "title": "Native client sensor",
                     "owner_confirmed": true, "expected_generation": "1"}),
        ),
        Some("00000000-0000-4000-8000-000000000002"),
        200,
    )?;
    let thing = enrolled["data"]["data"]["thing_id"]
        .as_str()
        .ok_or("missing Thing ID")?;
    let materialized = client.call(
        "POST",
        &format!("{prefix}/materialisations"),
        None,
        Some(&json!({"thing_id": thing, "expected_generation": "2"})),
        Some("00000000-0000-4000-8000-000000000003"),
        200,
    )?;
    assert_eq!(materialized["data"]["generation"], "3");
    let property = client.call(
        "GET",
        &format!("{prefix}/things/{thing}/properties/temperature"),
        Some(reader),
        None,
        None,
        200,
    )?;
    assert_eq!(property, json!(24.3));
    let history = client.call(
        "GET",
        &format!("{prefix}/things/{thing}/history"),
        Some(reader),
        None,
        None,
        200,
    )?;
    assert_eq!(history["data"]["items"][0]["generation"], "3");

    let mut query = json!({
        "schema": "wtr.query-spec.v1",
        "algorithm": "absolute-utc-buckets-v1",
        "id": "native-temperature-history",
        "revision": "native-query-v1",
        "dataset": "measurements",
        "measurement": "temperature",
        "unit": "Cel",
        "series": [thing],
        "qualities": ["valid"],
        "from_at": 1_700_000_000_000_i64,
        "to_at": 1_700_000_000_001_i64,
        "timezone": "Etc/UTC",
        "bucket_ms": 1,
        "aggregation": "last",
        "order": "ascending",
        "max_points": 1,
        "window_semantics": "from_inclusive_to_exclusive",
        "missing_values": "excluded_and_disclosed"
    });
    let digest = Sha256::digest(serde_json::to_vec(&query)?);
    let hex = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    query["identity"] = format!("wtr-json-v1:sha256:{hex}").into();
    let analytics = client.call(
        "POST",
        &format!("{prefix}/analytics/query"),
        Some(reader),
        Some(&query),
        None,
        200,
    )?;
    assert_eq!(analytics["data"]["qualified_rows"], 1);
    assert_eq!(analytics["data"]["series"][0]["points"][0]["value"], 24.3);
    let mut forged = query.clone();
    forged["identity"] = format!("wtr-json-v1:sha256:{}", "0".repeat(64)).into();
    assert_eq!(
        client.call(
            "POST",
            &format!("{prefix}/analytics/query"),
            Some(reader),
            Some(&forged),
            None,
            400
        )?["error"]["code"],
        "invalid_request"
    );

    let events = client.stream(
        &format!("{prefix}/events/stream?cursor={cursor}"),
        reader,
        None,
        3,
    )?;
    assert_eq!(events.len(), 3);
    assert_eq!(
        events
            .iter()
            .map(|event| event["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["1", "2", "3"]
    );
    let resume_cursor = events[1]["cursor"]
        .as_str()
        .ok_or("missing resume cursor")?;
    let resumed = client.stream(
        &format!("{prefix}/events/stream"),
        reader,
        Some(resume_cursor),
        1,
    )?;
    assert_eq!(resumed[0]["id"], "3");

    let revoked = client.call(
        "POST",
        &format!("{prefix}/revocations"),
        None,
        Some(&json!({"credential_id": "reader", "expected_generation": "3"})),
        Some("00000000-0000-4000-8000-000000000004"),
        200,
    )?;
    assert_eq!(revoked["data"]["generation"], "4");
    assert_eq!(
        client.call(
            "GET",
            &format!("{prefix}/state"),
            Some(reader),
            None,
            None,
            401
        )?["error"]["code"],
        "unauthorized"
    );

    println!("NATIVE_PROTOCOL_PASS openapi=true enrollment=true observation=true native_types=true property=true history=true analytics=true sse_resume=true revocation=true");
    Ok(())
}

struct Client<'a> {
    address: SocketAddr,
    token: &'a str,
}

impl Client<'_> {
    fn connect(&self) -> Result<TcpStream, Box<dyn std::error::Error>> {
        let stream = TcpStream::connect_timeout(&self.address, Duration::from_secs(5))?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        Ok(stream)
    }

    fn send(
        &self,
        stream: &mut TcpStream,
        method: &str,
        path: &str,
        credential: Option<&str>,
        body: Option<&Value>,
        operation: Option<&str>,
        extra: Option<(&str, &str)>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let bytes = body
            .map(serde_json::to_vec)
            .transpose()?
            .unwrap_or_default();
        let accept = if path.ends_with("/raw") {
            "application/vnd.wotex.tracker.observation+json"
        } else if path.contains("/events/stream") {
            "text/event-stream"
        } else {
            "application/json"
        };
        let mut request = format!("{method} {path} HTTP/1.1\r\nHost: {}\r\nAccept: {accept}\r\nAccept-Encoding: identity\r\nConnection: close\r\n", self.address);
        if let Some(credential) = credential.filter(|value| !value.is_empty()) {
            request.push_str(&format!("Authorization: Bearer {credential}\r\n"));
        }
        if let Some(operation) = operation {
            request.push_str(&format!("Idempotency-Key: {operation}\r\n"));
        }
        if let Some((name, value)) = extra {
            request.push_str(&format!("{name}: {value}\r\n"));
        }
        if body.is_some() {
            request.push_str(&format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                bytes.len()
            ));
        }
        request.push_str("\r\n");
        stream.write_all(request.as_bytes())?;
        stream.write_all(&bytes)?;
        Ok(())
    }

    fn call(
        &self,
        method: &str,
        path: &str,
        credential: Option<&str>,
        body: Option<&Value>,
        operation: Option<&str>,
        expected: u16,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        let mut stream = self.connect()?;
        let credential = credential.or(Some(self.token));
        self.send(&mut stream, method, path, credential, body, operation, None)?;
        let mut bytes = Vec::new();
        stream.take((LIMIT + 8192) as u64).read_to_end(&mut bytes)?;
        let split = bytes
            .windows(4)
            .position(|part| part == b"\r\n\r\n")
            .ok_or("missing HTTP headers")?;
        let head = std::str::from_utf8(&bytes[..split])?;
        let status: u16 = head
            .split_whitespace()
            .nth(1)
            .ok_or("missing HTTP status")?
            .parse()?;
        if status != expected {
            return Err(format!(
                "{method} {path}: HTTP {status}, expected {expected}: {}",
                String::from_utf8_lossy(&bytes[split + 4..])
            )
            .into());
        }
        let body = &bytes[split + 4..];
        if body.len() > LIMIT {
            return Err("HTTP body exceeds limit".into());
        }
        let body = if head
            .to_ascii_lowercase()
            .contains("transfer-encoding: chunked")
        {
            decode_chunks(body)?
        } else {
            body.to_vec()
        };
        Ok(serde_json::from_slice(&body)?)
    }

    fn stream(
        &self,
        path: &str,
        credential: &str,
        resume: Option<&str>,
        count: usize,
    ) -> Result<Vec<Value>, Box<dyn std::error::Error>> {
        let mut stream = self.connect()?;
        let extra = resume.map(|cursor| ("Last-Event-ID", cursor));
        self.send(
            &mut stream,
            "GET",
            path,
            Some(credential),
            None,
            None,
            extra,
        )?;
        let mut wire = Vec::new();
        let mut bytes = Vec::new();
        let mut chunk = [0u8; 4096];
        let mut events = Vec::new();
        let mut headers = false;
        let mut chunked = false;
        loop {
            let size = stream.read(&mut chunk)?;
            if size == 0 || wire.len() + bytes.len() + size > 65_536 {
                return Err("SSE stream closed or exceeded limit".into());
            }
            wire.extend_from_slice(&chunk[..size]);
            if !headers {
                if let Some(split) = wire.windows(4).position(|part| part == b"\r\n\r\n") {
                    let head = std::str::from_utf8(&wire[..split])?;
                    if !head.starts_with("HTTP/1.1 200 ") {
                        return Err(format!("SSE status: {head}").into());
                    }
                    chunked = head
                        .to_ascii_lowercase()
                        .contains("transfer-encoding: chunked");
                    wire.drain(..split + 4);
                    headers = true;
                }
            }
            if headers {
                if chunked {
                    drain_chunks(&mut wire, &mut bytes)?;
                } else {
                    bytes.append(&mut wire);
                }
                let frames = String::from_utf8_lossy(&bytes).replace("\r\n", "\n");
                let mut consumed = 0;
                for frame in frames.split_terminator("\n\n") {
                    if !frames[consumed + frame.len()..].starts_with("\n\n") {
                        break;
                    }
                    consumed += frame.len() + 2;
                    if frame.lines().any(|line| line == "event: tracker") {
                        let data = frame
                            .lines()
                            .find_map(|line| line.strip_prefix("data: "))
                            .ok_or("missing SSE data")?;
                        events.push(serde_json::from_str(data)?);
                    }
                }
                bytes = frames.as_bytes()[consumed..].to_vec();
                if events.len() >= count {
                    return Ok(events);
                }
            }
        }
    }
}

fn drain_chunks(
    wire: &mut Vec<u8>,
    decoded: &mut Vec<u8>,
) -> Result<(), Box<dyn std::error::Error>> {
    loop {
        let Some(end) = wire.windows(2).position(|part| part == b"\r\n") else {
            return Ok(());
        };
        let size = usize::from_str_radix(
            std::str::from_utf8(&wire[..end])?
                .split(';')
                .next()
                .unwrap(),
            16,
        )?;
        if size == 0 || size > 65_536 || wire.len() < end + 2 + size + 2 {
            return if size == 0 {
                Err("SSE stream ended before expected events".into())
            } else {
                Ok(())
            };
        }
        if &wire[end + 2 + size..end + 4 + size] != b"\r\n" {
            return Err("invalid SSE chunk".into());
        }
        decoded.extend_from_slice(&wire[end + 2..end + 2 + size]);
        wire.drain(..end + 4 + size);
    }
}

fn decode_chunks(mut bytes: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut result = Vec::new();
    loop {
        let end = bytes
            .windows(2)
            .position(|part| part == b"\r\n")
            .ok_or("missing chunk size")?;
        let size = usize::from_str_radix(
            std::str::from_utf8(&bytes[..end])?
                .split(';')
                .next()
                .unwrap(),
            16,
        )?;
        bytes = &bytes[end + 2..];
        if size == 0 {
            break;
        }
        if size > LIMIT - result.len()
            || bytes.len() < size + 2
            || &bytes[size..size + 2] != b"\r\n"
        {
            return Err("invalid or oversized chunk".into());
        }
        result.extend_from_slice(&bytes[..size]);
        bytes = &bytes[size + 2..];
    }
    Ok(result)
}
