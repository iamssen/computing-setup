"""Release selection and pkg installation tests with no network or system changes."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest


FUNCTION_DIR = Path(__file__).resolve().parents[1]
REPO = FUNCTION_DIR.parents[1]


class NodeInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-node-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.target = self.root / "install bin/node"
        self.target.parent.mkdir()
        self.events = self.root / "events"
        self.fixture = self.root / "releases"
        self.fixture.mkdir()
        self.script = FUNCTION_DIR / "main.sh"
        self.env = dict(os.environ, PATH=str(self.commands) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        COMPUTING_SETUP_NODE_BIN=str(self.target),
                        TEST_TARGET=str(self.target), TEST_EVENTS=str(self.events),
                        TEST_RELEASES=str(self.fixture))
        for version in ("v26.3.0", "v26.8.0", "v27.3.0", "v21.7.3"):
            self.make_release(version)
        self.alias("latest", "v27.3.0")
        self.alias("latest-v26.x", "v26.8.0")
        self.alias("latest-v21.x", "v21.7.3")
        self.make_command("curl", r'''
            import os, pathlib, shutil, sys
            args = sys.argv[1:]
            url = next(arg for arg in args if arg.startswith("https://"))
            with open(os.environ["TEST_EVENTS"], "a") as events:
                events.write("download:" + url + "\n")
            if os.environ.get("TEST_DOWNLOAD_FAIL"):
                sys.exit(22)
            relative = url.split("/download/release/", 1)[1]
            source = pathlib.Path(os.environ["TEST_RELEASES"]) / relative
            if not source.is_file():
                sys.exit(22)
            shutil.copyfile(source, args[args.index("-o") + 1])
        ''')
        self.make_command("pkgutil", r'''
            import os, sys
            assert sys.argv[1] == "--check-signature"
            with open(os.environ["TEST_EVENTS"], "a") as events:
                events.write("signature:" + sys.argv[2] + "\n")
            if os.environ.get("TEST_SIGNATURE_FAIL"):
                sys.exit(1)
        ''')
        self.make_command("sudo", r'''
            import json, os, pathlib, sys
            args = sys.argv[1:]
            assert args[0] == "/usr/sbin/installer", args
            assert args[-2:] == ["-target", "/"], args
            package = pathlib.Path(args[args.index("-pkg") + 1])
            version = json.loads(package.read_text())["version"]
            with open(os.environ["TEST_EVENTS"], "a") as events:
                events.write("install:" + version + "\n")
            if os.environ.get("TEST_INSTALL_FAIL"):
                sys.exit(1)
            if not os.environ.get("TEST_WRONG_INSTALLED_VERSION"):
                target = pathlib.Path(os.environ["TEST_TARGET"])
                target.write_text("#!/bin/sh\nprintf '%s\\n' '" + version + "'\n")
                target.chmod(0o755)
        ''')
        self.make_command("pm2", r'''
            import os, sys
            assert sys.argv[1:] == ["update"]
            with open(os.environ["TEST_EVENTS"], "a") as events:
                events.write("pm2:update\n")
            if os.environ.get("TEST_PM2_FAIL"):
                sys.exit(1)
        ''')

    def make_command(self, name, body):
        path = self.commands / name
        path.write_text("#!/usr/bin/python3\n" + textwrap.dedent(body).lstrip())
        path.chmod(0o755)

    def make_release(self, version):
        directory = self.fixture / version
        directory.mkdir(exist_ok=True)
        package = directory / ("node-" + version + ".pkg")
        package.write_text(json.dumps({"version": version}))
        checksum = hashlib.sha256(package.read_bytes()).hexdigest()
        (directory / "SHASUMS256.txt").write_text(checksum + "  " + package.name + "\n")

    def alias(self, name, version):
        path = self.fixture / name
        path.mkdir(exist_ok=True)
        shutil.copyfile(self.fixture / version / "SHASUMS256.txt", path / "SHASUMS256.txt")

    def install_old(self, version="v26.3.0"):
        self.target.write_text("#!/bin/sh\nprintf '%s\\n' '" + version + "'\n")
        self.target.chmod(0o755)

    def run_installer(self, *args, **env):
        return subprocess.run(["/bin/bash", str(self.script), *args], env=dict(self.env, **env),
                              text=True, capture_output=True)

    def run_fish(self, command, **env):
        source = "source " + shlex.quote(str(REPO / "functions.fish")) + "; "
        return subprocess.run([shutil.which("fish"), "--no-config", "-c", source + command],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def log(self):
        return self.events.read_text() if self.events.exists() else ""

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_check_resolves_latest_without_installing(self):
        result = self.run_installer("check")
        self.assertEqual(result.returncode, 101, result.stderr)
        self.assertEqual(result.stdout, "[Install v27.3.0] install-node latest\n")
        self.assertFalse(self.target.exists())
        self.assertNotIn("install:", self.log())
        self.assertNotIn("signature:", self.log())

    def test_check_reports_both_same_major_and_major_updates(self):
        self.install_old()
        old = self.target.read_bytes()
        result = self.run_installer("check")
        self.assertEqual(result.returncode, 100, result.stderr)
        self.assertEqual(result.stdout, "[Update v26.3.0 → v26.8.0] install-node latest-v26.x\n"
                                       "[Update v26.3.0 → v27.3.0] install-node latest\n")
        self.assertIn("latest-v26.x/SHASUMS256.txt", self.log())
        self.assertEqual(self.target.read_bytes(), old)
        self.assertNotIn("install:", self.log())

    def test_check_same_major_latest_prints_only_one_update(self):
        self.alias("latest", "v26.8.0")
        self.install_old()
        result = self.run_installer("check")
        self.assertEqual(result.returncode, 100, result.stderr)
        self.assertEqual(result.stdout, "[Update v26.3.0 → v26.8.0] install-node latest-v26.x\n")
        self.assertIn("latest-v26.x/SHASUMS256.txt", self.log())

    def test_check_major_only(self):
        self.install_old("v26.8.0")
        result = self.run_installer("check")
        self.assertEqual(result.returncode, 100, result.stderr)
        self.assertEqual(result.stdout, "[Update v26.8.0 → v27.3.0] install-node latest\n")

    def test_check_current_or_newer_never_offers_a_downgrade(self):
        self.alias("latest", "v26.8.0")
        for version in ("v26.8.0", "v28.0.0"):
            with self.subTest(version=version):
                self.install_old(version)
                result = self.run_installer("check")
                self.assert_success(result)
                self.assertNotIn("[Update", result.stdout)
                self.assertNotIn("install:", self.log())

    def test_explicit_selectors_install_resolved_versions(self):
        for selector, target in (("latest", "v27.3.0"), ("latest-v26.x", "v26.8.0"),
                                 ("v26.3.0", "v26.3.0"), ("latest-v21.x", "v21.7.3")):
            with self.subTest(selector=selector):
                self.assert_success(self.run_installer("install", selector))
                self.assertIn(target, self.target.read_text())
                log = self.log()
                self.assertIn("/" + target + "/node-" + target + ".pkg", log)
                self.assertLess(log.index("signature:"), log.index("install:"))
                self.target.unlink()
                self.events.unlink()

    def test_an_explicit_older_version_is_allowed(self):
        self.install_old()
        self.assert_success(self.run_installer("install", "v21.7.3"))
        self.assertIn("v21.7.3", self.target.read_text())

    def test_same_selected_version_skips_the_package_install(self):
        self.install_old("v26.8.0")
        self.assert_success(self.run_installer("install", "latest-v26.x"))
        self.assertNotIn("install:", self.log())
        self.assertNotIn("signature:", self.log())

    def test_rejects_missing_or_non_directory_arguments_before_network(self):
        for args in ((), ("--major",), ("v26.3",), ("v21.x",), ("../latest",),
                     ("latest/",), ("latest", "extra")):
            with self.subTest(args=args):
                result = self.run_installer("install", *args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(self.log(), "")

    def test_bad_manifest_or_checksum_never_reaches_installer(self):
        self.install_old()
        old = self.target.read_bytes()
        manifest = self.fixture / "latest-v26.x/SHASUMS256.txt"
        original = manifest.read_text()
        for content in ("", "0" * 64 + original[64:],
                        (self.fixture / "v27.3.0/SHASUMS256.txt").read_text()):
            with self.subTest(content=content):
                manifest.write_text(content)
                result = self.run_installer("install", "latest-v26.x")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_bytes(), old)
                self.assertNotIn("install:", self.log())
                self.assertNotIn("signature:", self.log())

    def test_exact_version_directory_must_contain_the_requested_version(self):
        self.alias("v26.3.0", "v26.8.0")
        result = self.run_installer("install", "v26.3.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different version", result.stderr)
        self.assertNotIn("install:", self.log())

    def test_download_or_signature_failure_preserves_current_version(self):
        self.install_old()
        old = self.target.read_bytes()
        for failure in ("TEST_DOWNLOAD_FAIL", "TEST_SIGNATURE_FAIL"):
            with self.subTest(failure=failure):
                result = self.run_installer("install", "latest", **{failure: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_bytes(), old)
                self.assertNotIn("install:", self.log())

    def test_current_prints_the_installed_version_or_nothing(self):
        result = self.run_installer("current")
        self.assert_success(result)
        self.assertEqual(result.stdout, "")
        self.install_old()
        result = self.run_installer("current")
        self.assert_success(result)
        self.assertEqual(result.stdout, "v26.3.0\n")

    def test_unknown_or_missing_subcommand_is_a_usage_error(self):
        for args in ((), ("--check",), ("latest",)):
            with self.subTest(args=args):
                result = self.run_installer(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(self.log(), "")

    def test_installed_version_is_verified(self):
        self.install_old()
        result = self.run_installer("install", "latest", TEST_WRONG_INSTALLED_VERSION="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match the selected release", result.stderr)

    @unittest.skipUnless(shutil.which("fish"), "Fish is required")
    def test_pm2_updates_only_after_a_successful_version_change(self):
        self.install_old()
        self.assert_success(self.run_fish("install-node latest-v26.x"))
        self.assertEqual(self.log().count("pm2:update"), 1)
        self.assert_success(self.run_fish("install-node latest-v26.x"))
        self.assertEqual(self.log().count("pm2:update"), 1)
        result = self.run_fish("install-node latest", TEST_INSTALL_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log().count("pm2:update"), 1)

    @unittest.skipUnless(shutil.which("fish"), "Fish is required")
    def test_fish_requires_a_release_and_rejects_options(self):
        for command in ("install-node", "install-node --check", "install-node latest extra", "check-node-update extra"):
            with self.subTest(command=command):
                result = self.run_fish(command)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(self.log(), "")


if __name__ == "__main__":
    unittest.main()
