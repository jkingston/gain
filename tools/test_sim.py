"""Simulator client, watcher and process-lifecycle tests; no SDL required."""
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import sim


class SimulatorToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gain-sim-tools-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.client = sim.Client(self.root)

    def reply(self, *, ok=True, failure=None, seen=None):
        deadline = time.monotonic() + 2
        path = self.root / "request.json"
        while not path.exists():
            if time.monotonic() > deadline:
                return
            time.sleep(0.001)
        request = json.loads(path.read_text())
        if seen is not None:
            seen.append(request)
        path.unlink()
        data = {"id": request["id"], "ok": ok, "failure": failure, "geometry": {}}
        pending = self.root / "response.pending"
        pending.write_text(json.dumps(data))
        pending.replace(self.root / "response.json")

    def test_json_preserves_spaces_unicode_and_explicit_retry_id(self):
        seen = []
        worker = threading.Thread(target=self.reply, kwargs={"seen": seen})
        worker.start()
        self.addCleanup(worker.join)
        path = str(self.root / "Anaïs music" / "app library.dylib")
        self.client.send("load", path=path, request_id=123)
        self.assertEqual(seen[0]["path"], path)
        self.assertEqual(seen[0]["id"], 123)
        self.assertFalse((self.root / "client.lock").exists())

    def test_server_error_is_reported_instead_of_success(self):
        worker = threading.Thread(target=self.reply, kwargs={"ok": False, "failure": "AppRestoreRejected"})
        worker.start()
        self.addCleanup(worker.join)
        with self.assertRaisesRegex(sim.SimulatorError, "AppRestoreRejected"):
            self.client.send("reload")

    def test_stale_response_cannot_acknowledge_new_request(self):
        (self.root / "response.json").write_text('{"id":1,"ok":true}')
        with self.assertRaisesRegex(sim.SimulatorError, "timed out"):
            self.client.send("state", request_id=2, timeout=0.03)
        self.assertFalse((self.root / "client.lock").exists())
        self.assertEqual(json.loads((self.root / "request.json").read_text())["id"], 2)

    def test_parallel_client_and_oversized_request_are_rejected(self):
        (self.root / "client.lock").touch()
        with self.assertRaisesRegex(sim.SimulatorError, "in-flight"):
            self.client.send("state")
        with self.assertRaises(ValueError):
            self.client.send("capture", path="x" * 20000)

    def test_source_watch_excludes_outputs_detects_edits_and_deletions(self):
        source = self.root / "src"
        source.mkdir()
        file = source / "app.zig"
        file.write_text("a")
        baseline = sim.source_signature([self.root])
        output = self.root / "zig-out"
        output.mkdir()
        (output / "app").write_text("new build")
        self.assertEqual(baseline, sim.source_signature([self.root]))
        file.write_text("changed")
        self.assertNotEqual(baseline, sim.source_signature([self.root]))
        file.unlink()
        self.assertEqual((), sim.source_signature([self.root]))


if __name__ == "__main__":
    unittest.main()
