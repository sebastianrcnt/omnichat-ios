#!/usr/bin/env python3
"""Isolated resumable simulator E2E. Uses only synthetic prompts and a loopback mock.

python3 Tools/resume_smoke.py --device <simulator UUID> --app build/Build/Products/Debug-iphonesimulator/Strata.app
Installs on the explicitly named Simulator, clears only this app's simulator data,
kills the app after a persisted SSE cursor, relaunches, and verifies the tool loop.
"""
import argparse
import json
import subprocess
import threading
import time
from pathlib import Path
from http.server import ThreadingHTTPServer

import mock_server


def sim(device, *args):
    return subprocess.check_output(["xcrun", "simctl", args[0], device, *args[1:]], text=True).strip()


def wait_for(fn, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for simulator recovery")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", required=True)
    args = parser.parse_args()
    mock_server.RESUMABLE = True
    mock_server.DROP_AFTER = 5
    requests = []

    class Handler(mock_server.Handler):
        def do_POST(self):
            requests.append(("POST", self.path))
            super().do_POST()
        def do_GET(self):
            requests.append(("GET", self.path))
            super().do_GET()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    device = args.device
    bundle = "cc.coolservices.strata"
    try:
        subprocess.run(["xcrun", "simctl", "boot", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.check_call(["xcrun", "simctl", "bootstatus", device, "-b"], stdout=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "terminate", device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "uninstall", device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sim(device, "install", str(Path(args.app).resolve()))
        base = f"http://127.0.0.1:{server.server_port}/v1"
        common = ["-StrataMockBaseURL", base, "-StrataMockKey", "test-only-key", "-StrataFakeTools", "1", "-StrataResumeReport", "1"]
        sim(device, "launch", bundle, *common, "-StrataAutoSend", "Describe Liquid Glass with sources")
        data = Path(sim(device, "get_app_container", bundle, "data")) / "Documents"
        checkpoint_path = data / "resume-checkpoint.json"
        def checkpoint():
            if not checkpoint_path.exists():
                return None
            value = json.loads(checkpoint_path.read_text())
            return value if value.get("seq", 0) >= 3 else None
        initial = wait_for(checkpoint)
        first_id = initial["request_id"]
        assert first_id.startswith("req_")
        sim(device, "terminate", bundle)
        time.sleep(1)  # producer continues even while no app process exists
        sim(device, "launch", bundle, *common)
        completed_path = data / "resume-completion.json"
        result = wait_for(lambda: json.loads(completed_path.read_text()) if completed_path.exists() else None)
        assert not result["error"], result["error"]
        assert not result["stopped"] and not result["pending"]
        assert result["steps"] == 2, result["steps"]
        expected = mock_server.ANSWER.format(a=1, b=2, c=3, unknown=97)
        assert result["text"] == expected, "Final text differs (missing/duplicate chunks)"
        posts = [p for m, p in requests if m == "POST" and p == "/v1/chat/completions"]
        resumes = [p for m, p in requests if m == "GET" and p.startswith("/v1/streams/")]
        assert len(posts) == 3, "Duplicated generation request after relaunch"
        assert any(first_id in p for p in resumes), "Relaunch did not resume stored request id"
        assert len(resumes) >= 3, "Forced drop was not recovered in every tool round"
        sim(device, "io", "screenshot", "/tmp/strata-resume-smoke.png")
        print(f"PASS: app kill + relaunch, {len(posts)} tool-loop POSTs, {len(resumes)} replay GETs, exact final text")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
