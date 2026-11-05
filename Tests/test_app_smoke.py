"""Opt-in graphical integration smoke test for the packaged application.

Uses only synthetic agent events and a temporary state directory. Does not touch
real agent configurations. Requires an active macOS graphical session.
"""
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Splash Finish.app/Contents/MacOS/SplashFinish"


@unittest.skipUnless(os.getenv("SPLASH_FINISH_GUI_TESTS") == "1", "set SPLASH_FINISH_GUI_TESTS=1 for graphical smoke test")
class AppSmokeTests(unittest.TestCase):
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
