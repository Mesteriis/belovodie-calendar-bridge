import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receiver", ROOT / "adapters/ha_ssh_receiver.py")
receiver = importlib.util.module_from_spec(spec); spec.loader.exec_module(receiver)

installer_spec = importlib.util.spec_from_file_location("installer", ROOT / "scripts/install-agent.py")
installer = importlib.util.module_from_spec(installer_spec); installer_spec.loader.exec_module(installer)

class BackgroundToolsTests(unittest.TestCase):
    def snapshot(self):
        return {"version": 1, "observedAt": "2026-10-05T00:00:00.000Z", "window": {"start": "2026-10-01T00:00:00.000Z", "end": "2026-11-01T00:00:00.000Z"}, "calendars": [], "removals": []}

    def test_receiver_fixed_authenticated_service_and_no_response_body_output(self):
        snapshot = self.snapshot(); captured = []
        class Response:
            status = 200
            def read(self, _): return b'[]'
            def __enter__(self): return self
            def __exit__(self, *_): pass
        def opener(request, timeout):
            captured.append(request)
            self.assertEqual(timeout, 20)
            return Response()
        receiver.publish(snapshot, lambda: ("http://ha.test/", "test-only-token"), opener)
        request = captured[0]
        self.assertEqual(request.full_url, "http://ha.test/api/services/belovodie_calendar_bridge/publish")
        self.assertEqual(request.headers["Authorization"], "Bearer test-only-token")
        self.assertEqual(json.loads(request.data), {"snapshot": snapshot})
        self.assertEqual(receiver.parse_snapshot(io.BytesIO(json.dumps(snapshot).encode())), snapshot)

    def test_receiver_rejects_duplicate_version_extra_root_nonfinite_and_oversize(self):
        for payload in [b'{"version":1,"version":1}', b'{"version":true}', b'{"version":NaN}', b'[]', b'{}', b'{} {}']:
            with self.assertRaises((ValueError, TypeError)):
                receiver.parse_snapshot(io.BytesIO(payload))
        value = self.snapshot(); value["token"] = "not-allowed"
        with self.assertRaises(ValueError): receiver.parse_snapshot(io.BytesIO(json.dumps(value).encode()))
        original = receiver.MAX_PAYLOAD_BYTES
        try:
            receiver.MAX_PAYLOAD_BYTES = 3
            with self.assertRaises(ValueError): receiver.parse_snapshot(io.BytesIO(b'1234'))
        finally: receiver.MAX_PAYLOAD_BYTES = original

    def test_stop_then_uninstall_removes_already_unloaded_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            destination = home / "Library/LaunchAgents" / (installer.LABEL + ".plist")
            destination.parent.mkdir(parents=True); destination.write_bytes(b"test plist")
            outcomes = iter([0, 3])
            def launchctl(arguments, **kwargs):
                self.assertEqual(arguments, ["/bin/launchctl", "bootout", "gui/" + str(installer.os.getuid()) + "/" + installer.LABEL])
                code = next(outcomes)
                if kwargs.get("check") and code: raise subprocess.CalledProcessError(code, arguments)
                return subprocess.CompletedProcess(arguments, code)
            with patch.object(installer.Path, "home", return_value=home), patch.object(installer.subprocess, "run", side_effect=launchctl):
                with patch.object(installer.sys, "argv", ["install-agent.py", "stop"]): self.assertEqual(installer.main(), 0)
                self.assertTrue(destination.exists())
                with patch.object(installer.sys, "argv", ["install-agent.py", "uninstall"]): self.assertEqual(installer.main(), 0)
            self.assertFalse(destination.exists())

    def test_uninstall_preserves_plist_on_genuine_launchctl_error(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            destination = home / "Library/LaunchAgents" / (installer.LABEL + ".plist")
            destination.parent.mkdir(parents=True); destination.write_bytes(b"test plist")
            def launchctl(arguments, **kwargs):
                if kwargs.get("check"): raise subprocess.CalledProcessError(5, arguments)
                return subprocess.CompletedProcess(arguments, 5)
            with patch.object(installer.Path, "home", return_value=home), patch.object(installer.subprocess, "run", side_effect=launchctl), patch.object(installer.sys, "argv", ["install-agent.py", "uninstall"]):
                with self.assertRaises(subprocess.CalledProcessError): installer.main()
            self.assertEqual(destination.read_bytes(), b"test plist")

    def test_generate_agent_escapes_paths_and_does_not_enable_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Space & Name.app"
            binary = app / "Contents/MacOS/BelovodieCalendarBridge"
            binary.parent.mkdir(parents=True); binary.touch()
            output = Path(directory) / "agent.plist"
            result = subprocess.run(["python3", str(ROOT / "scripts/install-agent.py"), "generate", "--app", str(app), "--output", str(output)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            agent = plistlib.loads(output.read_bytes())
            self.assertEqual(agent["ProgramArguments"], [str(binary.resolve()), "--background"])
            self.assertTrue(agent["RunAtLoad"])
            self.assertTrue(agent["KeepAlive"])
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertFalse((Path(directory) / "write-intent.json").exists())
            lint = subprocess.run(["/usr/bin/plutil", "-lint", str(output)], capture_output=True)
            self.assertEqual(lint.returncode, 0)

if __name__ == "__main__": unittest.main()
