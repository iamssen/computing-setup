"""The overview checks availability without invoking any update command."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest


REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(shutil.which("fish"), "Fish is required")
class ComputingSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-computing-setup-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.events = self.root / "events"
        self.env = dict(os.environ, PATH=str(self.root) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        TEST_EVENTS=str(self.events), NO_COLOR="1",
                        XDG_CONFIG_HOME=str(self.root / "config"))
        for name, body in {
            "brew": '''
                assert args == ["outdated", "--verbose"], args
                print("jq (1.7) < 1.8")
            ''',
            "rustup": '''
                assert args == ["check"], args
                print("stable - Update available")
                sys.exit(100)
            ''',
            "npm": '''
                assert args == ["outdated", "--global", "--json"], args
                if os.environ.get("TEST_NPM_ERROR"):
                    print('{"error":{"code":"EAI_AGAIN"}}')
                    sys.exit(1)
                if os.environ.get("TEST_NPM_CURRENT"):
                    print('{}')
                    sys.exit(0)
                print('{"npm-check":{"current":"6.0.0","latest":"6.1.0"}}')
                sys.exit(1)
            ''',
            "npm-check": '''
                raise SystemExit("The overview must not run interactive updates")
            ''',
        }.items():
            script = self.root / name
            header = '''import os, sys
args = sys.argv[1:]
with open(os.environ["TEST_EVENTS"], "a") as events:
    events.write(os.path.basename(sys.argv[0]) + ":" + " ".join(args) + "\\n")
'''
            script.write_text("#!/usr/bin/python3\n" + header + textwrap.dedent(body))
            script.chmod(0o755)
        self.source = "source " + shlex.quote(str(REPO / "functions.fish")) + "; "
        self.checks = '''
            function check-node-update
                echo '[Update v26.3.0 → v26.8.0] install-node latest-v26.x'
                return $TEST_NODE_STATUS
            end
            function check-dagu-update
                echo '[Setup] setup-dagu 0.0.0.0 8040'
                echo '[Setup] setup-dagu 127.0.0.1 8040'
                return 101
            end
        '''

    def run_check(self, suffix="computing-setup", **env):
        return subprocess.run([shutil.which("fish"), "--no-config", "-c", self.source + self.checks + suffix],
                              env=dict(self.env, TEST_NODE_STATUS="100", **env), text=True, capture_output=True)

    def log(self):
        return self.events.read_text() if self.events.exists() else ""

    def test_checks_only_and_treats_available_actions_as_success(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for line in ("[Upgrade] brew upgrade", "[Update] rustup update", "[Update] npm-check -gu",
                     "[Setup] setup-dagu 0.0.0.0 8040", "install-node latest-v26.x"):
            self.assertIn(line, result.stdout)
        self.assertIn("[Setup] setup-dagu 127.0.0.1 8040", result.stdout)
        self.assertEqual(self.log().splitlines(), ["brew:outdated --verbose", "rustup:check", "npm:outdated --global --json"])
        self.assertEqual(list((self.root / "config").glob("fish/conf.d/*")), [])

    def test_one_failed_check_does_not_skip_remaining_sections(self):
        env = dict(self.env, TEST_NODE_STATUS="1")
        result = subprocess.run([shutil.which("fish"), "--no-config", "-c", self.source + self.checks + "computing-setup"],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[Setup] setup-dagu 0.0.0.0 8040", result.stdout)
        self.assertIn("npm:outdated", self.log())

    def test_npm_errors_are_not_reported_as_available_updates(self):
        result = self.run_check(TEST_NPM_ERROR="1")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("[Update] npm-check -gu", result.stdout)

    def test_no_npm_updates_omits_the_update_command(self):
        result = self.run_check(TEST_NPM_CURRENT="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("npm - up to date", result.stdout)
        self.assertNotIn("[Update] npm-check -gu", result.stdout)


if __name__ == "__main__":
    unittest.main()
