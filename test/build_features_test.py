import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tool import build_network
from tool.build_features import clean_network_directory, multiplayer_enabled, network_directory, read_features


def defines(*values):
    return ",".join(base64.b64encode(value.encode()).decode() for value in values)


class BuildFeatureTests(unittest.TestCase):
    def test_encoded_defines_are_explicit_and_match_dart_boolean_values(self):
        self.assertFalse(multiplayer_enabled())
        self.assertFalse(multiplayer_enabled(defines("OTHER_FLAG=true")))
        self.assertTrue(multiplayer_enabled(defines("FYL_ENABLE_MULTIPLAYER=true")))
        for value in ("false", "TRUE", "1", ""):
            self.assertFalse(multiplayer_enabled(defines("FYL_ENABLE_MULTIPLAYER=true", "FYL_ENABLE_MULTIPLAYER=" + value)))
        self.assertTrue(multiplayer_enabled(defines("FYL_ENABLE_MULTIPLAYER=false", "FYL_ENABLE_MULTIPLAYER=true")))
        with self.assertRaises(ValueError):
            multiplayer_enabled("not base64")

    def test_disabled_native_build_needs_no_go_and_removes_previous_helper(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            helper = network_directory(bundle, "windows")
            helper.mkdir(parents=True)
            (helper / "fyl-network.exe").write_text("old helper")
            (helper / "THIRD-PARTY-LICENSES.txt").write_text("old license")
            args = ["build_network.py", "--target", "windows", "--bundle-root", str(bundle)]
            with patch.object(sys, "argv", args), patch.object(build_network.shutil, "which", return_value=None), patch.object(build_network, "build") as compile_helper:
                build_network.main()
            compile_helper.assert_not_called()
            self.assertFalse(helper.exists())
            self.assertFalse(read_features(bundle, "windows"))

    def test_opt_in_reaches_the_native_builder_and_records_matching_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            args = ["build_network.py", "--target", "macos", "--bundle-root", str(bundle),
                    "--dart-defines", defines("FYL_ENABLE_MULTIPLAYER=true"), "--arch", "universal", "--go", "go-fixture"]
            with patch.object(sys, "argv", args), patch.object(build_network, "build") as compile_helper:
                build_network.main()
            compile_helper.assert_called_once_with("macos", network_directory(bundle, "macos"), "universal", "go-fixture")
            self.assertTrue(read_features(bundle, "macos"))

    def test_cleanup_preserves_unrecognized_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            helper = Path(temporary) / "fyl-network"
            helper.mkdir()
            private = helper / "keep-me.json"
            private.write_text("private")
            with self.assertRaisesRegex(ValueError, "Unexpected files"):
                clean_network_directory(helper)
            self.assertEqual(private.read_text(), "private")

    def test_cleanup_unlinks_a_helper_symlink_without_touching_its_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            actual = root / "keep"
            actual.mkdir()
            (actual / "fyl-network.exe").write_text("preserve")
            link = root / "fyl-network"
            try:
                link.symlink_to(actual, target_is_directory=True)
            except OSError:
                self.skipTest("Symlink creation is unavailable")
            clean_network_directory(link)
            self.assertFalse(link.exists())
            self.assertEqual((actual / "fyl-network.exe").read_text(), "preserve")

    def test_native_configuration_can_run_without_go_on_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, "tool/build_network.py", "--target", "windows",
                "--bundle-root", temporary, "--go", "nonexistent-go"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            marker = Path(temporary) / "data/fyl-build-flags.json"
            self.assertEqual(json.loads(marker.read_text())["multiplayer"], False)


if __name__ == "__main__":
    unittest.main()
