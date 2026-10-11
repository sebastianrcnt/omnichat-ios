"""Synthetic HTTP tests for the simulator mock; no live gateway/engine traffic."""
import concurrent.futures
import http.client
import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import mock_server as mock

KEY = "f24d815a-5706-43c2-96c0-ce9f396f0e52"


class MockIdempotencyTests(unittest.TestCase):
    def setUp(self):
        mock.RESUMABLE = True
        mock.DROP_AFTER = mock.DROP_BEFORE_HEADERS = 0
        mock.RETENTION_SECONDS = 1800
        with mock.REGISTRY_LOCK:
            mock.STREAMS.clear()
            mock.IDEMPOTENCY.clear()

        class Handler(mock.Handler):
            def log_message(self, *_):
                pass
            def generate(self, *_):
                mock.sse(self, mock.chunk({"content": "hello"}))
                time.sleep(0.02)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.close()
            def before_stream_headers(self, rid, stream, created):
                with self.server.effects_lock:
                    self.server.effects += int(created)
                return super().before_stream_headers(rid, stream, created)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.effects = 0
        self.server.effects_lock = threading.Lock()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}/v1"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def call(self, path="/chat/completions", body=None, owner="synthetic-owner", cursor=None):
        headers = {"Authorization": f"Bearer {owner}", "Idempotency-Key": KEY, "X-Strata-Resumable": "1"}
        if cursor is not None:
            headers["Last-Event-ID"] = str(cursor)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.headers, response.read()

    def test_concurrent_posts_start_one_generation_and_replay_identically(self):
        body = {"model": "m", "stream": True, "messages": []}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda _: self.call(body=body), range(2)))
        self.assertEqual(results[0][0]["X-Billing-Request-Id"], results[1][0]["X-Billing-Request-Id"])
        self.assertEqual(results[0][1], results[1][1])
        self.assertEqual(self.server.effects, 1)
        _, tail = self.call(body=body, cursor=1)
        self.assertEqual(tail, results[0][1].split(b"\n\n", 1)[1])

    def test_conflict_and_lookup_are_owner_scoped(self):
        first, _ = self.call(body={"model": "m", "stream": True})
        with self.assertRaises(urllib.error.HTTPError) as conflict:
            self.call(body={"model": "other", "stream": True})
        self.assertEqual(conflict.exception.code, 422)
        _, status = self.call("/streams/by-key/" + KEY.upper())
        self.assertEqual(json.loads(status)["request_id"], first["X-Billing-Request-Id"])
        with self.assertRaises(urllib.error.HTTPError) as unknown:
            self.call("/streams/by-key/" + KEY, owner="other-synthetic-owner")
        self.assertEqual(unknown.exception.code, 404)
        second, _ = self.call(body={"model": "m", "stream": True}, owner="other-synthetic-owner")
        self.assertNotEqual(first["X-Billing-Request-Id"], second["X-Billing-Request-Id"])
        self.assertEqual(self.server.effects, 2)

    def test_accepted_post_without_headers_retries_one_generation(self):
        mock.DROP_BEFORE_HEADERS = 1
        body = {"model": "m", "stream": True}
        with self.assertRaises(http.client.RemoteDisconnected):
            self.call(body=body)
        headers, data = self.call(body=body)
        self.assertTrue(headers["X-Billing-Request-Id"].startswith("req_"))
        self.assertIn(b"hello", data)
        self.assertEqual(self.server.effects, 1)

    def test_expiry_removes_key_index(self):
        self.call(body={"model": "m", "stream": True})
        mock.RETENTION_SECONDS = 0
        with self.assertRaises(urllib.error.HTTPError) as expired:
            self.call("/streams/by-key/" + KEY)
        self.assertEqual(expired.exception.code, 404)
        self.assertFalse(mock.IDEMPOTENCY)


if __name__ == "__main__":
    unittest.main()
