import json
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tool import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write("pubspec.yaml", "version: 0.1.0+7\n")
        self.write("LICENSE", "license fixture")
        self.write("assets/components/SOURCES.txt", "artwork attribution fixture")

    def write(self, name, value):
        file = self.root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(value, encoding="utf-8")
        return file

    def test_tag_must_match_project_version(self):
        data = release.metadata(self.root, "refs/tags/v0.1.0", "a" * 40)
        self.assertEqual(data["version"], "0.1.0")
        self.assertEqual(data["build_number"], "7")
        self.assertEqual(data["prerelease"], "false")
        for ref in ("refs/tags/v0.2.0", "refs/tags/v0.1.0-beta.1", "refs/tags/0.1.0"):
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                release.metadata(self.root, ref, "a" * 40)

    def test_beta_and_development_versions_are_distinct(self):
        self.write("pubspec.yaml", "version: 0.2.0-beta.1+8\n")
        beta = release.metadata(self.root, "refs/tags/v0.2.0-beta.1", "b" * 40)
        self.assertEqual(beta["version"], "0.2.0-beta.1")
        self.assertEqual(beta["build_name"], "0.2.0")
        self.assertEqual(beta["prerelease"], "true")
        dev = release.metadata(self.root, "refs/heads/main", "b" * 40)
        self.assertEqual(dev["is_release"], "false")
        self.assertEqual(dev["version"], "0.2.0-beta.1.dev.bbbbbbbb")
        self.assertEqual(dev["prerelease"], "true")

    def test_invalid_versions_and_native_build_numbers_are_rejected(self):
        for value in ("01.2.3", "1.2", "1.2.3-beta.01", "1.2.3\nunsafe", "1.2.3+bad", "1.2.3+0", "1.2.3+65536"):
            with self.subTest(version=value), self.assertRaises(ValueError):
                self.write("pubspec.yaml", "version: '" + value + "'\n")
                release.metadata(self.root, "refs/heads/main", "c" * 40)

    def binary(self, target, machine=None):
        directory = release.bundle_path(self.root, target)
        file = directory / ("free_your_launcher.exe" if target == "windows" else "free_your_launcher")
        file.parent.mkdir(parents=True, exist_ok=True)
        data = bytearray(128)
        if target == "windows":
            data[:2] = b"MZ"
            struct.pack_into("<I", data, 60, 64)
            data[64:68] = b"PE\0\0"
            struct.pack_into("<H", data, 68, machine or 0x8664)
        else:
            data[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", data, 18, machine or 62)
        file.write_bytes(data)
        file.chmod(0o755)
        return file

    def test_architecture_comes_from_executable(self):
        self.assertEqual(release.architecture("windows", self.binary("windows", 0xAA64)), "arm64")
        self.assertEqual(release.architecture("linux", self.binary("linux", 183)), "arm64")
        with patch.object(release.subprocess, "check_output", return_value="x86_64 arm64\n"):
            self.assertEqual(release.architecture("macos", Path("example")), "universal")
        with self.assertRaises(ValueError):
            release.architecture("windows", self.binary("windows", 0x14C))

    def test_windows_archive_includes_runtime_and_source_information(self):
        self.binary("windows")
        self.write("build/windows/x64/runner/Release/data/flutter_assets/example", "resource")
        archive = release.package(self.root, "windows", "0.1.0", "owner/repo", "a" * 40)
        self.assertEqual(archive.name, "FYL-0.1.0-windows-x64.zip")
        with zipfile.ZipFile(archive) as contents:
            self.assertEqual(contents.read("FYL/data/flutter_assets/example"), b"resource")
            self.assertEqual(contents.read("FYL/LICENSE-FYL.txt"), b"license fixture")
            self.assertIn(("a" * 40).encode(), contents.read("FYL/SOURCE.txt"))
        self.assertEqual(archive.with_name(archive.name + ".sha256").read_text().split()[0], release.digest(archive))

    def test_linux_archive_preserves_executable_permissions(self):
        self.binary("linux")
        archive = release.package(self.root, "linux", "0.1.0-beta.1", "owner/repo", "a" * 40)
        with tarfile.open(archive) as contents:
            executable = contents.getmember("FYL/free_your_launcher")
            if os.name != "nt":
                self.assertEqual(executable.mode & 0o111, 0o111)
            self.assertIsNotNone(contents.getmember("FYL/ARTWORK-SOURCES.txt"))

    def test_bundle_must_not_link_to_files_outside_it(self):
        self.binary("linux")
        outside = self.write("private.txt", "do not package")
        link = release.bundle_path(self.root, "linux") / "private-link"
        try:
            link.symlink_to(outside)
        except OSError:
            self.skipTest("Symlink creation is unavailable")
        with self.assertRaisesRegex(ValueError, "external symlink"):
            release.package(self.root, "linux", "0.1.0", "owner/repo", "a" * 40)

    def artifacts(self, version="0.1.0"):
        directory = self.root / "artifacts"
        directory.mkdir(exist_ok=True)
        for target in release.TARGETS:
            extension = ".tar.gz" if target == "linux" else ".zip"
            file = directory / f"FYL-{version}-{target}-x64{extension}"
            file.write_bytes(b"archive fixture")
            file.with_name(file.name + ".sha256").write_text(f"{release.digest(file)}  {file.name}\n")
        return directory

    def test_all_platforms_and_valid_checksums_are_required(self):
        directory = self.artifacts()
        files = release.release_files(directory, "0.1.0")
        self.assertEqual(len(files), 4)
        self.assertEqual(len(files[-1].read_text().splitlines()), 3)
        files[0].write_bytes(b"modified archive")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            release.release_files(directory, "0.1.0")
        files[0].unlink()
        with self.assertRaisesRegex(ValueError, "Exactly one windows"):
            release.release_files(directory, "0.1.0")

    def test_unrelated_files_and_duplicate_platforms_are_rejected(self):
        directory = self.artifacts()
        extra = directory / "local-credentials.json"
        extra.write_text("not a release file")
        with self.assertRaisesRegex(ValueError, "Unexpected files"):
            release.release_files(directory, "0.1.0")
        extra.unlink()
        (directory / "FYL-0.1.0-windows-arm64.zip").write_bytes(b"duplicate")
        with self.assertRaisesRegex(ValueError, "Exactly one windows"):
            release.release_files(directory, "0.1.0")

    def run_publish(self, version="0.1.0", latest="v0.0.9", existing=None, fail_upload=False):
        self.write("pubspec.yaml", f"version: {version}+7\n")
        directory = self.artifacts(version)
        calls = []

        def command(args, **kwargs):
            calls.append(args)
            if args[1:3] == ["release", "view"]:
                return subprocess.CompletedProcess(args, 1 if existing is None else 0, json.dumps({"isDraft": existing}))
            if args[1] == "api":
                return subprocess.CompletedProcess(args, 0, latest)
            if fail_upload and args[1:3] == ["release", "upload"]:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, "")

        with patch.object(release.subprocess, "run", side_effect=command):
            if fail_upload:
                with self.assertRaises(subprocess.CalledProcessError):
                    release.publish(self.root, directory, "v" + version)
            else:
                release.publish(self.root, directory, "v" + version)
        return calls

    def test_beta_stays_prerelease_and_never_becomes_latest(self):
        calls = self.run_publish("0.2.0-beta.1")
        create = next(call for call in calls if call[1:3] == ["release", "create"])
        self.assertIn("--draft", create)
        self.assertIn("--verify-tag", create)
        self.assertIn("--prerelease", create)
        self.assertIn("--prerelease=true", calls[-1])
        self.assertIn("--latest=false", calls[-1])

    def test_stable_release_is_published_after_upload(self):
        calls = self.run_publish()
        self.assertEqual(calls[-2][1:3], ["release", "upload"])
        self.assertIn("--draft=false", calls[-1])
        self.assertIn("--prerelease=false", calls[-1])
        self.assertIn("--latest=true", calls[-1])

    def test_failed_upload_leaves_release_unpublished(self):
        calls = self.run_publish(fail_upload=True)
        self.assertFalse(any(call[1:3] == ["release", "edit"] for call in calls))

    def test_rerun_resumes_draft_and_does_not_replace_published_release(self):
        calls = self.run_publish(existing=True)
        self.assertFalse(any(call[1:3] == ["release", "create"] for call in calls))
        calls = self.run_publish(existing=False)
        self.assertEqual(len(calls), 1)

    def test_older_stable_release_does_not_replace_latest(self):
        calls = self.run_publish(latest="v0.2.0")
        self.assertIn("--latest=false", calls[-1])


if __name__ == "__main__":
    unittest.main()
