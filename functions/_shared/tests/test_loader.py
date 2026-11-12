"""functions.fish loader tests: command registration and the conf.d link."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[3]
LOADER = REPO / "functions.fish"
FISH = shutil.which("fish")


@unittest.skipUnless(FISH, "Fish is required")
class LoaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-loader-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.root / "config"))
        self.conf_d = self.root / "config" / "fish" / "conf.d"
        self.link = self.conf_d / "computing-setup.fish"

    def source(self, *flags, then="true"):
        command = "source " + shlex.quote(str(LOADER)) + "; set -l loaded $status; " + then + "; exit $loaded"
        return subprocess.run([FISH, "--no-config", *flags, "-c", command],
                              env=self.env, text=True, capture_output=True, stdin=subprocess.DEVNULL)

    def test_exposes_only_the_public_command_names(self):
        result = self.source(then='''
            functions -q computing-setup check-node-update install-node check-dagu-update setup-dagu \\
                update-dagu pushover validate-signing-identity; or exit 1
            for old in outdated install-dagu update-node setup-node delete-dagu delete-node
                if functions -q $old
                    exit 1
                end
            end
        ''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_interactive_source_does_not_touch_the_configuration(self):
        result = self.source()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertEqual(list(self.conf_d.glob("*")), [])

    def test_interactive_source_links_the_loader_once(self):
        result = self.source("--interactive")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.link.is_symlink())
        self.assertEqual(self.link.resolve(), LOADER.resolve())
        self.assertIn("linked " + str(self.link), result.stdout)
        # 두 번째부터는 이미 연결되어 있으므로 아무것도 출력하지 않는다.
        result = self.source("--interactive")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual([p.name for p in self.conf_d.iterdir()], ["computing-setup.fish"])

    def test_sourcing_through_the_link_registers_the_commands(self):
        self.conf_d.mkdir(parents=True)
        self.link.symlink_to(LOADER)
        command = "source " + shlex.quote(str(self.link)) + "; functions -q computing-setup pushover"
        result = subprocess.run([FISH, "--no-config", "--interactive", "-c", command],
                                env=self.env, text=True, capture_output=True, stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")

    def test_existing_link_under_another_name_is_detected_by_target(self):
        self.conf_d.mkdir(parents=True)
        (self.conf_d / "my-loader.fish").symlink_to(LOADER)
        result = self.source("--interactive")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([p.name for p in self.conf_d.iterdir()], ["my-loader.fish"])
        self.assertEqual(result.stdout, "")

    def test_unrelated_file_with_the_link_name_is_not_overwritten(self):
        self.conf_d.mkdir(parents=True)
        self.link.write_text("# user file\n")
        result = self.source("--interactive", then="functions -q computing-setup; or exit 3")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.link.read_text(), "# user file\n")
        self.assertIn("already exists", result.stderr)


if __name__ == "__main__":
    unittest.main()
