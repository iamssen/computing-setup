"""Signing identity validation tests with a fixture keychain listing."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


FUNCTION_DIR = Path(__file__).resolve().parents[1]
REPO = FUNCTION_DIR.parents[1]
IDENTITY = "A" * 40


class ValidateSigningIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-signing-identity-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        security = self.root / "security"
        security.write_text('''#!/usr/bin/python3
import sys
assert sys.argv[1:] == ["find-identity", "-v", "-p", "codesigning"], sys.argv
print('  1) ''' + IDENTITY + ''' "Apple Development: Fixture"')
print("     1 valid identities found")
''')
        security.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root) + ":/usr/bin:/bin:/usr/sbin:/sbin")

    def run_script(self, *args):
        return subprocess.run(["/bin/bash", str(FUNCTION_DIR / "main.sh"), *args],
                              env=self.env, text=True, capture_output=True)

    def test_listed_identity_is_valid(self):
        result = self.run_script(IDENTITY)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_unlisted_identity_is_rejected(self):
        # "1"은 목록의 요약 줄("1 valid identities found")에만 나오는 값이다.
        for identity in ("B" * 40, IDENTITY[:-1], "1"):
            with self.subTest(identity=identity):
                result = self.run_script(identity)
                self.assertEqual(result.returncode, 1)
                self.assertIn("signing certificate is not valid", result.stderr)

    def test_empty_identity_names_the_variable(self):
        result = self.run_script("")
        self.assertEqual(result.returncode, 1)
        self.assertIn("SIGNING_IDENTITY", result.stderr)

    def test_wrong_argument_count_is_a_usage_error(self):
        for args in ((), (IDENTITY, "extra")):
            with self.subTest(args=args):
                self.assertEqual(self.run_script(*args).returncode, 2)

    @unittest.skipUnless(shutil.which("fish"), "Fish is required")
    def test_fish_command_returns_the_script_status(self):
        source = "source " + shlex.quote(str(REPO / "functions.fish")) + "; "
        for identity, expected in ((IDENTITY, 0), ("B" * 40, 1)):
            with self.subTest(identity=identity):
                result = subprocess.run(
                    [shutil.which("fish"), "--no-config", "-c", source + "validate-signing-identity " + identity],
                    env=self.env, text=True, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
