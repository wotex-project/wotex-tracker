"""CLI custody, admission, network failure and finite-response tests."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
import uuid

CLI = Path(__file__).resolve().parents[1] / "bin/trackerctl"


class CLITest(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[1] / "_build/test/cli-unit"
        root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=root)
        self.directory = Path(self.temporary.name)
        self.token = self.directory / "operator.token"
        self.token.write_text("A" * 43 + "\n")
        self.token.chmod(0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def run_cli(self, arguments, port=1):
        result = subprocess.run([str(CLI), "--url", f"http://127.0.0.1:{port}", "--scope", "workshop",
            "--token-file", str(self.token), *arguments], capture_output=True, text=True, timeout=8,
            env={**os.environ, "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1"})
        self.assertNotIn("A" * 43, result.stdout + result.stderr)
        return result

    def peer(self, response, arguments, pending=False):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(3)
        observations = []

        def serve():
            with listener:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(3)
                    request = b""
                    while b"\r\n\r\n" not in request:
                        request += connection.recv(4096)
                        if len(request) > 16384:
                            raise AssertionError("test request exceeded bounds")
                    observations.append("accepted")
                    if response:
                        try:
                            connection.sendall(response)
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                    if pending:
                        observations.append("closed" if not connection.recv(1) else "unexpected")

        thread = threading.Thread(target=serve)
        thread.start()
        result = self.run_cli(arguments, listener.getsockname()[1])
        thread.join(timeout=4)
        self.assertFalse(thread.is_alive())
        self.assertEqual(observations.count("accepted"), 1)
        return result, observations

    def test_private_token_and_local_input_fail_before_mutation_attempt(self):
        self.token.chmod(0o644)
        result = self.run_cli(["materialize", "thing", "--generation", "0"])
        error = json.loads(result.stderr.splitlines()[-1])["error"]
        self.assertEqual(error["outcome"], "not_committed")
        self.assertEqual(result.returncode, 1)
        self.token.chmod(0o600)
        duplicate = self.directory / "observation.json"
        duplicate.write_text('{"payload":1,"payload":2}')
        result = self.run_cli(["import", str(duplicate), "--generation", "0"])
        self.assertEqual(json.loads(result.stderr)["error"]["code"], "duplicate_json_key")
        self.assertEqual(result.returncode, 1)
        duplicate.write_bytes(b" " * 1_048_577)
        self.assertEqual(json.loads(self.run_cli(["import", str(duplicate), "--generation", "0"]).stderr)["error"]["code"], "input_too_large")

    def test_a_disconnected_mutation_is_unknown_and_is_not_retried(self):
        operation = str(uuid.uuid4())
        result, _ = self.peer(b"", ["materialize", "thing", "--generation", "0", "--operation", operation])
        self.assertEqual(result.returncode, 3)
        error = json.loads(result.stderr.splitlines()[-1])["error"]
        self.assertEqual(error["outcome"], "unknown")
        self.assertEqual(error["operation_id"], operation)

    def test_accepted_unknown_receipt_keeps_the_operation_identity(self):
        operation = str(uuid.uuid4())
        body = json.dumps({"schema": "wtr.response.v1", "data": {"outcome": "unknown", "operation_id": operation}}).encode()
        response = b"HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
        result, _ = self.peer(response, ["materialize", "thing", "--generation", "0", "--operation", operation])
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["data"]["operation_id"], operation)

    def test_response_byte_header_media_and_version_limits(self):
        cases = [
            (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4194305\r\n\r\n" + b" " * 4_194_305, "response_too_large"),
            (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" + b"X: y\r\n" * 32 + b"Content-Length: 0\r\n\r\n", "response_headers_too_large"),
            (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}", "invalid_media_type"),
            (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}", "unsupported_content_encoding"),
            (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", "unsupported_version"),
            (b"HTTP/1.1 302 Found\r\nLocation: https://untrusted.example/\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n", "invalid_media_type"),
        ]
        for response, code in cases:
            with self.subTest(code=code):
                result, _ = self.peer(response, ["capabilities"])
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stderr)["error"]["code"], code)

    def test_property_stream_preserves_native_values_and_rejects_invalid_samples(self):
        handshake = b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        prefix = b"id: wtrc1.opaque\nevent: property:event:4:4\ndata: "
        for value in (b"0", b"1.0", b"false"):
            result, _ = self.peer(handshake + prefix + value + b"\n\n", ["observe", "thing", "temperature", "--max-events", "1"])
            self.assertEqual(result.returncode, 0)
            sample = json.loads(result.stdout)
            self.assertEqual(sample["schema"], "wtr.property.v1")
            self.assertEqual(type(sample["value"]), type(json.loads(value)))
            self.assertEqual(sample["value"], json.loads(value))
            self.assertEqual(sample["generation"], "4")
        for frame in (prefix + b"null\n\n", prefix + b"{}\n\n", b"data: 1\n\n",
                      b"id: invalid\nevent: property:event:4:4\ndata: 1\n\n",
                      prefix + b"1\ndata: 2\n\n"):
            result, _ = self.peer(handshake + frame, ["observe", "thing", "temperature"])
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stderr)["error"]["code"], "invalid_event")
        result = self.run_cli(["observe", "thing", "temperature", "--seconds", "301"])
        self.assertEqual(json.loads(result.stderr)["error"]["code"], "invalid_stream_limit")

    def test_stream_deadline_closes_the_socket_and_oversized_frames_fail(self):
        handshake = b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        result, observations = self.peer(handshake, ["events", "--cursor", "cursor", "--stream", "--seconds", "1"], pending=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stderr)["error"]["code"], "deadline_exceeded")
        self.assertIn("closed", observations)
        result, _ = self.peer(handshake + b"data: " + b"x" * 32769, ["events", "--cursor", "cursor", "--stream"])
        self.assertEqual(json.loads(result.stderr)["error"]["code"], "event_too_large")


if __name__ == "__main__":
    unittest.main()
