"""Opt-in graphical integration smoke test for the packaged application.

Uses only synthetic agent events and a temporary state directory. Does not touch
real agent configurations. Requires an active macOS graphical session.
"""
import json
import os
import socket
import stat
import subprocess
import threading
import uuid
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Splash Finish.app/Contents/MacOS/SplashFinish"


@unittest.skipUnless(os.getenv("SPLASH_FINISH_GUI_TESTS") == "1", "set SPLASH_FINISH_GUI_TESTS=1 for graphical smoke test")
class AppSmokeTests(unittest.TestCase):
    def test_cli_version_matches_app_bundle(self):
        self.assertTrue(APP.is_file(), "Build the packaged app before running this check")
        expected = subprocess.check_output([
            "/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
            str(APP.parents[1] / "Info.plist")
        ], text=True).strip()
        actual = subprocess.check_output([str(APP), "--version"], text=True).strip()
        self.assertEqual(actual, expected)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="splash-finish-e2e-")
        self.addCleanup(self.temp.cleanup)
        self.env = {**os.environ, "SPLASH_FINISH_HOME": self.temp.name}
        self.app = subprocess.Popen([str(APP)], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_app)
        time.sleep(1)
        self.assertIsNone(self.app.poll(), "Another app may already be running")

    def stop_app(self):
        self.app.terminate()
        try:
            self.app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.app.kill()
            self.app.wait(timeout=5)
        if self.app.stderr:
            self.app.stderr.close()

    def run_cli(self, *args, input=None):
        return subprocess.run([str(APP), *args], input=input, env=self.env, text=True,
                              capture_output=True, check=True, timeout=10)

    def state(self):
        # Apple events are asynchronous: poll for persisted state before assertions.
        deadline = time.time() + 4
        while time.time() < deadline:
            path = Path(self.temp.name) / "state.json"
            if path.exists():
                return json.loads(path.read_text())
            time.sleep(0.05)
        self.fail("App did not persist the event")

    def wait_for(self, predicate):
        deadline = time.time() + 4
        while time.time() < deadline:
            state = self.state()
            if predicate(state):
                return state
            time.sleep(0.05)
        self.fail(f"State did not converge: {state}")

    def test_rich_question_connection_and_clear(self):
        directory = Path('/tmp') / f'sf-{os.getuid()}'
        directory.mkdir(mode=0o700, exist_ok=True)
        self.assertEqual(directory.lstat().st_uid, os.getuid())
        self.assertEqual(stat.S_IMODE(directory.lstat().st_mode) & 0o077, 0)
        request_id = uuid.uuid4().hex
        path = directory / f'{request_id}.sock'
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(server.close)
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        server.bind(str(path)); server.listen(1); server.settimeout(6)
        question = {'questions': [{'id': 'q1', 'label': 'First', 'prompt': 'Synthetic private question', 'type': 'single',
                                   'options': [{'value': 'one', 'label': 'One'}, {'value': 'two', 'label': 'Two'}]}],
                    'project': 'test', 'session': 'test-session'}
        connected = threading.Event()
        release = threading.Event()
        def serve():
            with server.accept()[0] as conn:
                conn.sendall((json.dumps(question) + '\n').encode())
                connected.set(); release.wait(8)
                conn.sendall(b'{"type":"closed"}\n')  # terminal-answer / shutdown marker
        thread = threading.Thread(target=serve, daemon=True); thread.start()
        self.addCleanup(release.set)
        subprocess.run(['/usr/bin/open', '-g', '-a', str(APP.parents[2]), f'splash-finish://question?id={request_id}'], check=True, timeout=5)
        self.assertTrue(connected.wait(6), 'App did not connect to the local question socket')
        state = self.wait_for(lambda s: any(x['task'] == f'question-{request_id}' for x in s['items']))
        self.assertNotIn('Synthetic private question', json.dumps(state))
        self.run_cli('clear')
        self.wait_for(lambda s: any(x['task'] == f'question-{request_id}' for x in s['items']))
        release.set(); thread.join(5)
        self.wait_for(lambda s: all(x['task'] != f'question-{request_id}' for x in s['items']))

    def test_delivery_snooze_and_hook_lifecycle(self):
        self.run_cli("notify", "--agent", "Codex", "--task", "one", "--title", "First task")
        self.wait_for(lambda s: len(s["items"]) == 1)
        self.run_cli("snooze")
        self.wait_for(lambda s: bool(s.get("snoozedUntil")))
        self.run_cli("notify", "--agent", "pi", "--task", "two", "--title", "Second task")
        state = self.wait_for(lambda s: len(s["items"]) == 2 and not s.get("snoozedUntil"))
        self.assertEqual({item["task"] for item in state["items"]}, {"one", "two"})
        hook = {"session_id": "three", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/tmp/demo"}
        result = self.run_cli("hook", "claude", "--managed-splash-finish", input=json.dumps(hook))
        self.assertEqual(result.stdout.strip(), "{}")
        state = self.wait_for(lambda s: len(s["items"]) == 3)
        self.assertEqual(next(x for x in state["items"] if x["task"] == "three")["status"], "attention")
        hook.update(hook_event_name="Stop", last_assistant_message="Finished safely")
        self.run_cli("hook", "claude", "--managed-splash-finish", input=json.dumps(hook))
        self.wait_for(lambda s: any(x["task"] == "three" and x["status"] == "done" for x in s["items"]))
        self.run_cli("notify", "--agent", "pi", "--task", "two", "--status", "running")
        self.wait_for(lambda s: len(s["items"]) == 2 and all(x["task"] != "two" for x in s["items"]))
        self.run_cli("clear")
        self.wait_for(lambda s: not s["items"])


if __name__ == "__main__":
    unittest.main()
