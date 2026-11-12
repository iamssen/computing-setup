"""Exercise the Fish command without sending real Pushover notifications."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[3]
FISH = shutil.which("fish")


@unittest.skipUnless(FISH and shutil.which("jq"), "Fish and jq are required")
class PushoverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-pushover-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.request = self.root / "request.json"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("PUSHOVER_")}
        self.env.update({
            "PATH": str(self.root) + ":" + os.environ["PATH"],
            "PUSHOVER_USER": "fixture-user",
            "PUSHOVER_CHANNEL_FINANCE": "fixture-finance-token",
            "PUSHOVER_CHANNEL_SYSTEM": "fixture-system-token",
            "TEST_REQUEST": str(self.request),
        })
        curl = self.root / "curl"
        curl.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
Path(os.environ["TEST_REQUEST"]).write_text(json.dumps(sys.argv[1:]))
print(os.environ.get("TEST_RESPONSE", '{"status":1,"request":"fixture"}'))
sys.exit(int(os.environ.get("TEST_CURL_STATUS", "0")))
''')
        curl.chmod(0o755)
        self.source = "source " + shlex.quote(str(REPO / "functions.fish")) + "; "

    def run_send(self, *args, **env):
        return subprocess.run(
            [FISH, "--no-config", "-c", self.source + "pushover $argv", "--", *args],
            env=dict(self.env, **env), text=True, capture_output=True)

    def parameters(self):
        args = json.loads(self.request.read_text())
        self.assertEqual(args[-1], "https://api.pushover.net/1/messages.json")
        self.assertIn("--fail-with-body", args)
        self.assertLess(int(args[args.index("--max-time") + 1]), 30)
        return dict(args[i + 1].split("=", 1) for i, arg in enumerate(args)
                    if arg == "--data-urlencode")

    def test_channel_mapping_and_message_are_preserved(self):
        message = '시장 알림: A&B = +100%\n"quotes" \'single\' $HOME $(touch ignored) @file'
        for channel in ("finance", "system", "market_2"):
            with self.subTest(channel=channel):
                result = self.run_send(channel, message,
                                       PUSHOVER_CHANNEL_MARKET_2="fixture-market_2-token")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")
                self.assertEqual(self.parameters(), {
                    "token": "fixture-" + channel + "-token",
                    "user": "fixture-user", "message": message,
                })

    def test_invalid_inputs_do_not_send(self):
        for args in ((), ("system",), ("system", "one", "two"),
                     ("Finance", "text"), ("bad-channel", "text"),
                     ("system\n", "text"), ("system", ""), ("system", "가" * 1025)):
            with self.subTest(args=args[:1]):
                result = self.run_send(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.request.exists())

    def test_missing_configuration_names_the_variable_without_sending(self):
        for key in ("PUSHOVER_USER", "PUSHOVER_CHANNEL_SYSTEM"):
            with self.subTest(key=key):
                result = self.run_send("system", "text", **{key: ""})
                self.assertEqual(result.returncode, 2)
                self.assertIn(key, result.stderr)
                self.assertNotIn("fixture-", result.stderr)
                self.assertFalse(self.request.exists())
        result = self.run_send("unknown", "text")
        self.assertEqual(result.returncode, 2)
        self.assertIn("PUSHOVER_CHANNEL_UNKNOWN", result.stderr)

    def test_api_and_transport_failures_are_unsuccessful(self):
        cases = [
            ('{"status":0,"errors":["invalid token"]}', "0", 1, "invalid token"),
            ('{"status":0,"errors":["message rejected"]}', "22", 22, "message rejected"),
            ('{"status":1}', "22", 22, "delivery failed"),
            ("not json", "0", 1, "invalid response"),
            ("", "28", 28, "delivery failed"),
        ]
        for response, status, expected, error in cases:
            with self.subTest(response=response, status=status):
                result = self.run_send("system", "text", TEST_RESPONSE=response,
                                       TEST_CURL_STATUS=status)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn(error, result.stderr)
                self.assertNotIn("fixture-", result.stderr)

    def test_dagu_sh_command_passes_event_values_literally(self):
        error = 'quoted "error"; $(touch ignored)\nsecond line'
        fish_code = self.source + 'pushover system "Dagu: $DAG_NAME [$STATUS]\n$ERROR"'
        command = shlex.quote(FISH) + " --no-config -c " + shlex.quote(fish_code)
        result = subprocess.run(["/bin/sh", "-c", command],
                                env=dict(self.env, DAG_NAME="daily job", STATUS="failed", ERROR=error),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.parameters()["message"], "Dagu: daily job [failed]\n" + error)


if __name__ == "__main__":
    unittest.main()
