"""Isolated updater integration tests; no real network, signing key, or LaunchAgent."""

import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import unittest


FUNCTION_DIR = Path(__file__).resolve().parents[1]
REPO = FUNCTION_DIR.parents[1]
LATEST = "v2.26.0"
REQUIREMENT = 'identifier "local.dagu" and certificate leaf = fixture'


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-dagu-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.target = self.root / "install bin" / "dagu"
        self.target.parent.mkdir()
        self.plist = self.home / "Library/LaunchAgents/local.dagu.server.plist"
        self.events = self.root / "events"
        self.service_file = self.root / "service.json"
        self.set_service(False)
        self.fixture = self.root / "release"
        self.fixture.mkdir()
        self.make_release()
        self.script = FUNCTION_DIR / "main.sh"
        self.env = dict(os.environ)
        self.env.pop("SERVER", None)
        # SSH로 접속해 테스트를 돌려도 점검 출력이 달라지지 않게 한다.
        self.env.pop("SSH_CONNECTION", None)
        self.env.pop("SSH_TTY", None)
        self.env.update({
            "HOME": str(self.home),
            "PATH": str(self.commands) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "COMPUTING_SETUP_DAGU_BIN": str(self.target),
            "SIGNING_IDENTITY": "A" * 40,
            "DAGU_HOME": str(self.home / "dagu data"),
            "TEST_RELEASE_DIR": str(self.fixture),
            "TEST_EVENTS": str(self.events),
            "TEST_SERVICE": str(self.service_file),
            "TEST_TARGET": str(self.target),
        })
        self.make_command("curl", r'''
            import os, pathlib, shutil, sys
            args = sys.argv[1:]
            url = next(arg for arg in args if arg.startswith("https://"))
            with open(os.environ["TEST_EVENTS"], "a") as events:
                events.write("download:" + url + "\n")
            if os.environ.get("TEST_DOWNLOAD_FAIL"):
                sys.exit(22)
            name = "release.json" if url.endswith("/latest") else url.rsplit("/", 1)[1]
            shutil.copyfile(pathlib.Path(os.environ["TEST_RELEASE_DIR"]) / name, args[args.index("-o") + 1])
        ''')
        self.make_command("codesign", r'''
            import os, pathlib, re, sys
            args = sys.argv[1:]
            binary = pathlib.Path(args[-1])
            body = binary.read_text()
            leaf = re.search(r"^# leaf=(.*)$", body, re.M).group(1)
            requirement = re.search(r"^# requirement=(.*)$", body, re.M).group(1)
            installed_new = binary == pathlib.Path(os.environ["TEST_TARGET"]) and "dagu version v2.26.0" in body
            with open(os.environ["TEST_EVENTS"], "a") as events:
                events.write("codesign:" + " ".join(args[:-1]) + ":" + str(binary) + "\n")
            if "--force" in args:
                if os.environ.get("TEST_SIGN_FAIL"):
                    sys.exit(1)
                leaf = os.environ.get("TEST_NEW_CERT", "certificate-a")
                identifier = args[args.index("--identifier") + 1]
                requirement = os.environ.get("TEST_NEW_DR", 'identifier "' + identifier + '" and certificate leaf = fixture')
                body = re.sub(r"^# leaf=.*$", "# leaf=" + leaf, body, flags=re.M)
                body = re.sub(r"^# requirement=.*$", "# requirement=" + requirement, body, flags=re.M)
                binary.write_text(body)
            elif "--verify" in args:
                if leaf == "unsigned" or (installed_new and os.environ.get("TEST_POST_VERIFY_FAIL")):
                    sys.exit(1)
            elif any(arg.startswith("--extract-certificates=") for arg in args):
                if leaf != "unsigned":
                    if installed_new and os.environ.get("TEST_POST_CERT_MISMATCH"):
                        leaf = "certificate-tampered"
                    prefix = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--extract-certificates="))
                    pathlib.Path(prefix + "0").write_text(leaf)
            elif "--requirements" in args:
                print("designated => " + requirement)
            else:
                sys.exit(2)
        ''')
        self.make_command("launchctl", r'''
            import json, os, pathlib, plistlib, sys
            args = sys.argv[1:]
            state_file = pathlib.Path(os.environ["TEST_SERVICE"])
            state = json.loads(state_file.read_text())
            with open(os.environ["TEST_EVENTS"], "a") as events:
                events.write("launchctl:" + " ".join(args) + "\n")
            action = args[0]
            if action == "print":
                if not state["loaded"]:
                    sys.exit(113)
                print("state = " + ("running" if state["running"] else "waiting"))
            elif action == "bootstrap":
                with open(args[2], "rb") as source:
                    plist = plistlib.load(source)
                binary = pathlib.Path(plist["ProgramArguments"][0])
                assert binary.exists(), "cannot start a missing binary"
                if os.environ.get("TEST_BOOTSTRAP_RETRY") and not state.get("bootstrap_retry_used"):
                    state["bootstrap_retry_used"] = True
                    state_file.write_text(json.dumps(state))
                    sys.exit(5)
                if os.environ.get("TEST_BOOTSTRAP_FAIL") and "dagu version v2.26.0" in binary.read_text():
                    sys.exit(5)
                running = not (os.environ.get("TEST_SERVICE_EXITS") and "dagu version v2.26.0" in binary.read_text())
                state.update(loaded=True, running=running)
            elif action == "bootout":
                if not state["loaded"]:
                    sys.exit(113)
                state.update(loaded=False, running=False)
            elif action == "kickstart":
                assert "-k" not in args, "must not kill an already-running service here"
                if not state["loaded"]:
                    sys.exit(113)
                state["running"] = not os.environ.get("TEST_SERVICE_EXITS")
            else:
                sys.exit(2)
            state_file.write_text(json.dumps(state))
        ''')
        self.make_command("uname", r'''
            import os
            print(os.environ.get("TEST_ARCH", "arm64"))
        ''')
        self.make_command("security", r'''
            import os, sys
            if sys.argv[1] == "show-keychain-info":
                with open(os.environ["TEST_EVENTS"], "a") as events:
                    events.write("security:" + " ".join(sys.argv[1:]) + "\n")
                sys.exit(128 if os.environ.get("TEST_KEYCHAIN_LOCKED") else 0)
            if not os.environ.get("TEST_INVALID_IDENTITY"):
                print('  1) ' + 'A' * 40 + ' "Apple Development: Fixture"')
            print("  1 valid identities found")
        ''')
        self.make_command("sleep", "pass")
        self.make_command("sudo", "raise SystemExit('unexpected sudo call in isolated tests')")

    def make_command(self, name, body):
        script = self.commands / name
        script.write_text("#!/usr/bin/python3\n" + textwrap.dedent(body).lstrip())
        script.chmod(0o755)

    def binary(self, version, leaf="certificate-a", requirement=REQUIREMENT):
        return textwrap.dedent(f'''\
            #!/bin/bash
            # leaf={leaf}
            # requirement={requirement}
            leaf=$(sed -n 's/^# leaf=//p' "$0")
            if [[ $leaf == unsigned ]]; then
                echo 'executed unsigned binary' >&2
                exit 98
            fi
            printf 'execute:%s\\n' "$0" >> "$TEST_EVENTS"
            if [[ $1 == version ]]; then
                if [[ ${{TEST_VERSION_PREFIX:-}} == 1 ]]; then
                    echo 'dagu version {version}'
                else
                    echo '{version}'
                fi
            else
                exit 2
            fi
        ''')

    def make_release(self, binary_version=LATEST):
        (self.fixture / "release.json").write_text(json.dumps({"tag_name": LATEST, "draft": False, "prerelease": False}))
        checksums = []
        for arch in ("arm64", "amd64"):
            asset = f"dagu_{LATEST[1:]}_darwin_{arch}.tar.gz"
            data = self.binary(binary_version, leaf="unsigned").encode()
            with tarfile.open(self.fixture / asset, "w:gz") as archive:
                member = tarfile.TarInfo("dagu")
                member.mode = 0o755
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            checksum = hashlib.sha256((self.fixture / asset).read_bytes()).hexdigest()
            checksums.append(checksum + "  " + asset + "\n")
        (self.fixture / "checksums.txt").write_text("".join(checksums))

    def install_old(self, version="v2.25.0", leaf="certificate-a", requirement=REQUIREMENT):
        self.target.write_text(self.binary(version, leaf, requirement))
        self.target.chmod(0o755)

    def create_agent(self):
        self.plist.parent.mkdir(parents=True, exist_ok=True)
        self.plist.write_bytes(plistlib.dumps({
            "Label": "local.dagu.server",
            "ProgramArguments": [str(self.target), "start-all", "--host", "127.0.0.1", "--port", "8040"],
            "RunAtLoad": True,
            "KeepAlive": True,
            "CustomSetting": "preserve me",
        }))

    def set_service(self, loaded, running=None):
        self.service_file.write_text(json.dumps({"loaded": loaded, "running": loaded if running is None else running}))

    def run_updater(self, *args, **env):
        return subprocess.run(["/bin/bash", str(self.script), *args], env=dict(self.env, **env), text=True, capture_output=True)

    def log(self):
        return self.events.read_text() if self.events.exists() else ""

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(list(self.target.parent.glob(".dagu-*")))

    def test_check_missing_is_read_only(self):
        result = self.run_updater("check", SIGNING_IDENTITY="")
        self.assertEqual(result.returncode, 101)
        self.assertEqual(result.stdout, "[Setup] setup-dagu 0.0.0.0 8040\n[Setup] setup-dagu 127.0.0.1 8040\n")
        self.assertEqual(self.log(), "")
        self.assertNotIn("launchctl:", self.log())
        self.assertNotIn("codesign:", self.log())
        self.assertFalse(self.target.exists())
        self.assertFalse(self.plist.exists())

    def test_check_update_without_certificate_prints_action(self):
        self.install_old()
        previous = self.target.read_bytes()
        result = self.run_updater("check", SIGNING_IDENTITY="")
        self.assertEqual(result.returncode, 100, result.stderr)
        self.assertEqual(result.stdout, "[Update v2.25.0 → " + LATEST + "] update-dagu\n")
        self.assertEqual(self.target.read_bytes(), previous)
        self.assertNotIn("codesign:", self.log())
        self.assertNotIn("launchctl:", self.log())
        self.assertFalse(self.plist.exists())

    def test_check_over_ssh_with_locked_keychain_prints_unlock_first(self):
        unlock = "[Unlock keychain] security unlock-keychain ~/Library/Keychains/login.keychain-db\n"
        for ssh in ({"SSH_CONNECTION": "192.168.1.64 50000 192.168.1.10 22"}, {"SSH_TTY": "/dev/ttys001"}):
            ssh = dict(ssh, TEST_KEYCHAIN_LOCKED="1")
            with self.subTest(ssh=ssh):
                self.target.unlink(missing_ok=True)
                result = self.run_updater("check", SIGNING_IDENTITY="", **ssh)
                self.assertEqual(result.returncode, 101, result.stderr)
                self.assertEqual(
                    result.stdout,
                    unlock + "[Setup] setup-dagu 0.0.0.0 8040\n[Setup] setup-dagu 127.0.0.1 8040\n",
                )

                self.install_old()
                result = self.run_updater("check", SIGNING_IDENTITY="", **ssh)
                self.assertEqual(result.returncode, 100, result.stderr)
                self.assertEqual(result.stdout, unlock + "[Update v2.25.0 → " + LATEST + "] update-dagu\n")

                self.install_old(LATEST)
                result = self.run_updater("check", SIGNING_IDENTITY="", **ssh)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("unlock-keychain", result.stdout)

    def test_check_skips_unlock_when_keychain_is_open_or_not_ssh(self):
        # 화면 로그인 세션에서는 잠금 해제 창이 뜰 수 있으므로 키체인을 조회하지도 않아야 한다.
        cases = (
            ({"SSH_TTY": "/dev/ttys001"}, True),
            ({"TEST_KEYCHAIN_LOCKED": "1"}, False),
        )
        for env, queried in cases:
            with self.subTest(env=env):
                self.events.unlink(missing_ok=True)
                result = self.run_updater("check", SIGNING_IDENTITY="", **env)
                self.assertEqual(result.returncode, 101, result.stderr)
                self.assertEqual(result.stdout, "[Setup] setup-dagu 0.0.0.0 8040\n[Setup] setup-dagu 127.0.0.1 8040\n")
                self.assertEqual("security:show-keychain-info" in self.log(), queried)

    def test_check_current_and_newer_versions(self):
        for version in (LATEST, "v3.0.0"):
            with self.subTest(version=version):
                self.install_old(version)
                self.assert_success(self.run_updater("check", SIGNING_IDENTITY=""))
                self.assertFalse(self.plist.exists())

    def test_update_requires_install(self):
        result = self.run_updater("update")
        self.assertEqual(result.returncode, 1)
        self.assertIn("setup-dagu", result.stderr)
        self.assertEqual(self.log(), "")

    def test_fresh_install_signs_before_execution_and_registers_agent(self):
        self.assert_success(self.run_updater("setup", "127.0.0.1", "8040"))
        self.assertIn("dagu version " + LATEST, self.target.read_text())
        self.assertLess(self.log().index("codesign:--force"), self.log().index("execute:"))
        agent = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(agent["ProgramArguments"], [str(self.target), "start-all", "--host", "127.0.0.1", "--port", "8040"])
        self.assertEqual(agent["EnvironmentVariables"]["PATH"], self.env["PATH"])
        self.assertEqual(agent["EnvironmentVariables"]["DAGU_HOME"], self.env["DAGU_HOME"])
        self.assertNotIn("SIGNING_IDENTITY", agent["EnvironmentVariables"])
        self.assertTrue(agent["RunAtLoad"] and agent["KeepAlive"])

    def test_major_upgrade_preserves_signature_and_existing_plist(self):
        self.install_old("v1.30.0")
        self.create_agent()
        self.set_service(True)
        previous_agent = self.plist.read_bytes()
        self.assert_success(self.run_updater("update"))
        self.assertEqual(self.plist.read_bytes(), previous_agent)
        self.assertIn("dagu version " + LATEST, self.target.read_text())
        self.assertLess(self.log().index("codesign:--force"), self.log().index("launchctl:bootout"))
        self.assertTrue(json.loads(self.service_file.read_text())["running"])

    def test_prefixed_version_output_is_also_supported(self):
        self.install_old()
        self.create_agent()
        self.assert_success(self.run_updater("update", TEST_VERSION_PREFIX="1"))

    def test_transient_bootstrap_failure_is_retried(self):
        self.install_old()
        self.create_agent()
        self.set_service(True)
        self.assert_success(self.run_updater("update", TEST_BOOTSTRAP_RETRY="1"))
        self.assertEqual(self.log().count("launchctl:bootstrap"), 2)
        self.assertTrue(json.loads(self.service_file.read_text())["running"])

    def test_setup_rejects_existing_installation_without_any_changes(self):
        for version in ("v2.25.0", LATEST, "v3.0.0"):
            with self.subTest(version=version):
                self.install_old(version)
                previous = self.target.read_bytes()
                result = self.run_updater("setup", "127.0.0.1", "8040", SIGNING_IDENTITY="")
                self.assertEqual(result.returncode, 1)
                self.assertIn("already installed", result.stderr)
                self.assertEqual(self.target.read_bytes(), previous)
                self.assertEqual(self.log(), "")
                self.assertFalse(self.plist.exists())

    def test_setup_uses_explicit_host_and_port_independently_of_environment(self):
        for host, port, server in (("0.0.0.0", "8040", "false"),
                                   ("127.0.0.1", "8040", "true"),
                                   ("127.0.0.1", "9055", "true")):
            with self.subTest(host=host, port=port):
                self.assert_success(self.run_updater("setup", host, port, SERVER=server))
                agent = plistlib.loads(self.plist.read_bytes())
                self.assertEqual(agent["ProgramArguments"][-4:], ["--host", host, "--port", port])
                self.target.unlink()
                self.plist.unlink()
                self.set_service(False)

    def test_invalid_setup_arguments_fail_without_changes(self):
        for args in (("setup",), ("setup", "127.0.0.1"),
                     ("setup", "127.0.0.1", "8040", "extra"),
                     ("setup", "", "8040"), ("setup", "--host", "8040"),
                     ("setup", "two hosts", "8040"),
                     *(("setup", "127.0.0.1", port) for port in ("", "0", "65536", "-1", "abc", "80.0")),
                     (), ("--check",), ("check", "extra"), ("update", "extra")):
            with self.subTest(args=args):
                result = self.run_updater(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(self.log(), "")
                self.assertFalse(self.target.exists())
                self.assertFalse(self.plist.exists())

    def test_update_preserves_selected_network_and_other_agent_settings(self):
        for host, port, server in (("0.0.0.0", "8480", "false"),
                                   ("127.0.0.1", "9055", "true")):
            with self.subTest(host=host, port=port):
                self.install_old()
                self.create_agent()
                agent = plistlib.loads(self.plist.read_bytes())
                agent["ProgramArguments"] = [str(self.target), "start-all", "--config", "custom config.yaml", "--host", host, "--port", port]
                self.plist.write_bytes(plistlib.dumps(agent))
                previous_agent = self.plist.read_bytes()
                self.set_service(True)
                self.assert_success(self.run_updater("update", SERVER=server))
                self.assertEqual(self.plist.read_bytes(), previous_agent)
                self.assertTrue(json.loads(self.service_file.read_text())["running"])

    def test_update_without_agent_configuration_fails_without_changes(self):
        self.install_old("v3.0.0")
        previous = self.target.read_bytes()
        result = self.run_updater("update")
        self.assertEqual(result.returncode, 1)
        self.assertIn("configuration is missing", result.stderr)
        self.assertEqual(self.target.read_bytes(), previous)
        self.assertFalse(self.plist.exists())
        self.assertEqual(self.log(), "")

    def test_setup_does_not_overwrite_existing_agent_configuration(self):
        self.create_agent()
        previous_agent = self.plist.read_bytes()
        result = self.run_updater("setup", "0.0.0.0", "9055", SIGNING_IDENTITY="")
        self.assertEqual(result.returncode, 1)
        self.assertIn("already configured", result.stderr)
        self.assertEqual(self.plist.read_bytes(), previous_agent)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.log(), "")

    def test_up_to_date_loaded_service_is_not_restarted(self):
        self.install_old(LATEST)
        self.create_agent()
        self.set_service(True)
        self.assert_success(self.run_updater("update"))
        self.assertNotIn("launchctl:bootout", self.log())
        self.assertNotIn("launchctl:bootstrap", self.log())

    def test_certificate_and_requirement_changes_fail_before_replacement(self):
        for env in ({"TEST_NEW_CERT": "certificate-b"}, {"TEST_NEW_DR": 'identifier "different"'}):
            with self.subTest(env=env):
                self.install_old()
                self.create_agent()
                self.set_service(True)
                previous = self.target.read_bytes()
                result = self.run_updater("update", **env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("designated requirement changed", result.stderr)
                self.assertEqual(self.target.read_bytes(), previous)
                self.assertNotIn("launchctl:bootout", self.log())
                self.assertNotIn("execute:" + str(self.home), self.log())
                self.assertEqual(self.log().count("execute:"), 1)
                self.events.unlink()

    def test_existing_unsigned_binary_is_not_executed(self):
        self.install_old(leaf="unsigned")
        self.create_agent()
        result = self.run_updater("update")
        self.assertEqual(result.returncode, 1)
        self.assertIn("existing Dagu signature", result.stderr)
        self.assertNotIn("execute:", self.log())
        self.assertNotIn("download:", self.log())

    def test_download_checksum_signing_and_version_failures_preserve_installation(self):
        for failure in ("download", "checksum", "signing", "version"):
            with self.subTest(failure=failure):
                self.make_release("v2.0.0" if failure == "version" else LATEST)
                if failure == "checksum":
                    contents = (self.fixture / "checksums.txt").read_text()
                    (self.fixture / "checksums.txt").write_text("0" * 64 + contents[64:])
                self.install_old()
                self.create_agent()
                self.set_service(True)
                previous = self.target.read_bytes()
                env = {"TEST_DOWNLOAD_FAIL": "1"} if failure == "download" else {"TEST_SIGN_FAIL": "1"} if failure == "signing" else {}
                result = self.run_updater("update", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.target.read_bytes(), previous)
                self.assertNotIn("launchctl:bootout", self.log())
                if failure in ("download", "checksum"):
                    self.assertNotIn("codesign:--force", self.log())
                self.events.unlink()

    def test_post_install_signature_failures_restore_binary_and_service(self):
        for env in ({"TEST_POST_VERIFY_FAIL": "1"}, {"TEST_POST_CERT_MISMATCH": "1"}):
            with self.subTest(env=env):
                self.install_old()
                self.create_agent()
                self.set_service(True)
                previous = self.target.read_bytes()
                result = self.run_updater("update", **env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Restored the previous Dagu binary", result.stderr)
                self.assertEqual(self.target.read_bytes(), previous)
                self.assertTrue(json.loads(self.service_file.read_text())["running"])
                self.assertFalse(list(self.target.parent.glob(".dagu-*")))
                self.events.unlink()

    def test_start_failure_restores_previous_binary_and_service(self):
        self.install_old()
        self.create_agent()
        self.set_service(True)
        previous = self.target.read_bytes()
        result = self.run_updater("update", TEST_BOOTSTRAP_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), previous)
        self.assertTrue(json.loads(self.service_file.read_text())["running"])
        self.assertFalse(list(self.target.parent.glob(".dagu-*")))

    def test_fresh_install_start_failure_removes_new_binary_and_agent(self):
        result = self.run_updater("setup", "127.0.0.1", "8040", TEST_BOOTSTRAP_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.target.exists())
        self.assertFalse(self.plist.exists())
        self.assertFalse(json.loads(self.service_file.read_text())["loaded"])

    def test_crashing_service_is_treated_as_failure(self):
        self.install_old()
        self.create_agent()
        self.set_service(True)
        previous = self.target.read_bytes()
        result = self.run_updater("update", TEST_SERVICE_EXITS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not stay running", result.stderr)
        self.assertEqual(self.target.read_bytes(), previous)
        self.assertTrue(json.loads(self.service_file.read_text())["running"])

    def test_intel_asset_and_invalid_release_metadata(self):
        self.assert_success(self.run_updater("setup", "127.0.0.1", "8040", TEST_ARCH="x86_64"))
        self.assertIn("darwin_amd64.tar.gz", self.log())
        (self.fixture / "release.json").write_text(json.dumps({"tag_name": LATEST, "draft": False, "prerelease": True}))
        result = self.run_updater("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("latest stable release", result.stderr)

    @unittest.skipUnless(shutil.which("fish"), "Fish is required")
    def test_fish_rejects_arguments_and_checks_signing_identity(self):
        source = "source " + shlex.quote(str(REPO / "functions.fish")) + "; "
        for function in ("setup-dagu", "update-dagu", "check-dagu-update"):
            with self.subTest(function=function):
                result = subprocess.run([shutil.which("fish"), "--no-config", "-c", source + function + " --major"], env=self.env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(self.log(), "")
        result = subprocess.run([shutil.which("fish"), "--no-config", "-c", source + "setup-dagu 127.0.0.1 8040"], env=dict(self.env, TEST_INVALID_IDENTITY="1"), text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("signing certificate is not valid", result.stderr)
        self.assertEqual(self.log(), "")
        result = subprocess.run([shutil.which("fish"), "--no-config", "-c", source + "setup-dagu 127.0.0.1 8040"], env=self.env, text=True, capture_output=True)
        self.assert_success(result)
        previous = self.target.read_bytes()
        self.events.unlink()
        result = subprocess.run([shutil.which("fish"), "--no-config", "-c", source + "setup-dagu 127.0.0.1 8040"], env=dict(self.env, SIGNING_IDENTITY="", TEST_INVALID_IDENTITY="1"), text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("already installed", result.stderr)
        self.assertEqual(self.target.read_bytes(), previous)
        self.assertEqual(self.log(), "")


if __name__ == "__main__":
    unittest.main()
