"""Version validation, desktop packaging, and tag-based GitHub releases."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile
import zipfile


VERSION = re.compile(
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", re.ASCII
)
TARGETS = ("windows", "macos", "linux")


def version_parts(value):
    match = VERSION.fullmatch(value)
    if not match or any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in (match[4] or "").split(".")
    ):
        raise ValueError(f"Invalid release version: {value}")
    return tuple(int(match[index]) for index in (1, 2, 3)), bool(match[4])


def project_version(root):
    text = (root / "pubspec.yaml").read_text(encoding="utf-8-sig")
    match = re.search(
        r'''^version:[ \t]*(?:"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s#'"\r\n]+))[ \t]*(?:\#.*)?$''',
        text, re.MULTILINE,
    )
    if not match:
        raise ValueError("pubspec.yaml has no version")
    value = next(value for value in match.groups() if value is not None)
    version, separator, build = value.partition("+")
    version_parts(version)
    if separator and (not build.isascii() or not build.isdecimal()):
        raise ValueError("The native build number must be an integer")
    number = int(build) if separator else 1
    if not 1 <= number <= 65535:
        raise ValueError("The native build number must be between 1 and 65535")
    return version, number


def project_prerelease(root, version):
    config = root / ".github/release.json"
    configured = False
    if config.exists():
        data = json.loads(config.read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict) or set(data) != {"prerelease"} or type(data["prerelease"]) is not bool:
            raise ValueError(".github/release.json must contain a boolean prerelease field")
        configured = data["prerelease"]
    return version_parts(version)[1] or configured


def metadata(root, ref, sha):
    version, build = project_version(root)
    core, prerelease = version_parts(version)
    release = ref.startswith("refs/tags/")
    if release:
        tag = ref.removeprefix("refs/tags/")
        if tag != "v" + version:
            raise ValueError(f"Tag {tag} does not match pubspec.yaml version {version}")
    else:
        if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
            raise ValueError("A valid commit SHA is required for development builds")
        version += ("." if prerelease else "-") + "dev." + sha[:8]
    return {
        "version": version,
        "build_name": ".".join(map(str, core)),
        "build_number": str(build),
        "is_release": str(release).lower(),
        "prerelease": str(project_prerelease(root, version)).lower(),
    }


def bundle_path(root, target):
    return root / {
        "windows": "build/windows/x64/runner/Release",
        "macos": "build/macos/Build/Products/Release/free_your_launcher.app",
        "linux": "build/linux/x64/release/bundle",
    }[target]


def architecture(target, executable):
    if target == "macos":
        arches = set(subprocess.check_output(
            ["lipo", "-archs", str(executable)], text=True
        ).split())
        if arches == {"x86_64", "arm64"}:
            return "universal"
        machine = next(iter(arches)) if len(arches) == 1 else ""
        mapping = {"x86_64": "x64", "arm64": "arm64"}
    else:
        with executable.open("rb") as stream:
            header = stream.read(64)
            if target == "windows" and header[:2] == b"MZ" and len(header) == 64:
                stream.seek(struct.unpack_from("<I", header, 60)[0])
                signature = stream.read(6)
                if signature[:4] != b"PE\0\0" or len(signature) != 6:
                    raise ValueError("Invalid Windows executable")
                machine = struct.unpack_from("<H", signature, 4)[0]
                mapping = {0x8664: "x64", 0xAA64: "arm64"}
            elif target == "linux" and header[:6] == b"\x7fELF\x02\x01":
                machine = struct.unpack_from("<H", header, 18)[0]
                mapping = {62: "x64", 183: "arm64"}
            else:
                raise ValueError(f"Invalid {target} executable")
    if machine not in mapping:
        raise ValueError(f"Unsupported {target} architecture: {machine}")
    return mapping[machine]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def package(root, target, version, repository, sha):
    version_parts(version)
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository, re.ASCII):
        raise ValueError("Invalid GitHub repository")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("A full source commit SHA is required")
    bundle = bundle_path(root, target)
    executable = bundle / {
        "windows": "free_your_launcher.exe",
        "macos": "Contents/MacOS/free_your_launcher",
        "linux": "free_your_launcher",
    }[target]
    arch = architecture(target, executable)
    private_names = {"FYL-data", "fyl-storage.json", "fyl-storage.json.bak", "fyl-storage.json.tmp"}
    def private_entry(name):
        return name in private_names or ".fyl-migration-" in name or name.startswith(".fyl-update-")
    storage = bundle / "fyl-storage.json"
    if storage.is_file():
        selected = json.loads(storage.read_text(encoding="utf-8"))["dataDirectory"]
        selected = Path(selected) if Path(selected).is_absolute() else bundle / selected
        if selected.resolve().is_relative_to(bundle.resolve()):
            relative = selected.resolve().relative_to(bundle.resolve())
            if not relative.parts or relative.parts[0] in {"data", "lib", "plugins", executable.name}:
                raise ValueError("Custom data directory overlaps launcher runtime files")
            private_names.add(relative.parts[0])
    for entry in bundle.iterdir():
        if private_entry(entry.name):
            continue
        candidates = [entry, *entry.rglob("*")] if entry.is_dir() and not entry.is_symlink() else [entry]
        for candidate in candidates:
            if candidate.is_symlink() and not candidate.resolve(strict=True).is_relative_to(bundle.resolve()):
                raise ValueError(f"Bundle contains an external symlink: {candidate.name}")
    name = f"FYL-{version}-{target}-{arch}"
    extension = ".tar.gz" if target == "linux" else ".zip"
    output = root / "build/releases" / (name + extension)
    staging = root / "build/release-staging" / name / "FYL"
    if output.exists() or staging.exists():
        raise ValueError("Package output already exists; use a clean build directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    if target == "macos":
        staging.mkdir(parents=True)
        subprocess.run(["ditto", str(bundle), str(staging / bundle.name)], check=True)
    else:
        def ignore_private(directory, names):
            if Path(directory) == bundle:
                return {name for name in names if private_entry(name)}
            return set()
        shutil.copytree(bundle, staging, symlinks=True, ignore=ignore_private)
    shutil.copyfile(root / "LICENSE", staging / "LICENSE-FYL.txt")
    shutil.copyfile(root / "assets/components/SOURCES.txt", staging / "ARTWORK-SOURCES.txt")
    (staging / "SOURCE.txt").write_text(
        f"Source: https://github.com/{repository}/tree/{sha}\n", encoding="utf-8"
    )
    files, links = {}, {}
    for entry in sorted(staging.rglob("*")):
        relative = entry.relative_to(staging).as_posix()
        if relative == "fyl-package.json":
            continue
        if entry.is_symlink():
            destination = os.readlink(entry)
            if Path(destination).is_absolute() or not entry.resolve(strict=True).is_relative_to(staging.resolve()):
                raise ValueError("Package contains an external symlink")
            links[relative] = destination
        elif entry.is_file():
            files[relative] = {"size": entry.stat().st_size, "sha256": digest(entry)}
    entrypoint = executable.relative_to(bundle).as_posix()
    if target == "macos":
        entrypoint = f"{bundle.name}/{entrypoint}"
    (staging / "fyl-package.json").write_text(json.dumps({
        "schemaVersion": 1, "version": version, "target": target, "arch": arch,
        "entrypoint": entrypoint, "sourceCommit": sha, "files": files, "links": links,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if target == "macos":
        subprocess.run([
            "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
            str(staging), str(output),
        ], check=True)
    elif target == "linux":
        with tarfile.open(output, "w:gz") as archive:
            archive.add(staging, arcname="FYL")
    else:
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for entry in sorted(staging.rglob("*")):
                archive.write(entry, entry.relative_to(staging.parent).as_posix())
    output.with_name(output.name + ".sha256").write_text(
        f"{digest(output)}  {output.name}\n", encoding="utf-8"
    )
    print(output.name)
    return output


def release_files(directory, version):
    version_parts(version)
    files = []
    for target in TARGETS:
        extension = ".tar.gz" if target == "linux" else ".zip"
        arches = "(?:x64|arm64|universal)" if target == "macos" else "(?:x64|arm64)"
        pattern = re.compile(rf"FYL-{re.escape(version)}-{target}-{arches}{re.escape(extension)}")
        matches = [entry for entry in directory.iterdir() if pattern.fullmatch(entry.name)]
        if len(matches) != 1:
            raise ValueError(f"Exactly one {target} package is required")
        path = matches[0]
        if path.is_symlink() or not path.is_file() or not path.stat().st_size:
            raise ValueError("Release archives must be nonempty regular files")
        checksum = path.with_name(path.name + ".sha256")
        if checksum.is_symlink() or checksum.read_text(encoding="utf-8").strip() != f"{digest(path)}  {path.name}":
            raise ValueError(f"Checksum mismatch: {path.name}")
        files.append(path)
    allowed = {entry.name for file in files for entry in (file, file.with_name(file.name + ".sha256"))}
    if any(entry.name not in allowed for entry in directory.iterdir()):
        raise ValueError("Unexpected files in release artifacts")
    return files


def publish(root, directory, tag):
    version, _ = project_version(root)
    if tag != "v" + version:
        raise ValueError("Release tag does not match pubspec.yaml")
    core, _ = version_parts(version)
    prerelease = project_prerelease(root, version)
    files = release_files(directory, version)
    existing = subprocess.run(
        ["gh", "release", "view", tag, "--json", "isDraft"],
        capture_output=True, text=True,
    )
    if existing.returncode == 0 and not json.loads(existing.stdout)["isDraft"]:
        print(f"{tag} is already published; leaving it unchanged")
        return
    latest = not prerelease
    if latest:
        current = subprocess.run(
            ["gh", "api", "repos/{owner}/{repo}/releases/latest", "--jq", ".tag_name"],
            capture_output=True, text=True,
        )
        if current.returncode == 0:
            previous, _ = version_parts(current.stdout.strip().removeprefix("v"))
            latest = core > previous
    if existing.returncode != 0:
        command = ["gh", "release", "create", tag, "--verify-tag", "--draft", "--generate-notes"]
        if prerelease:
            command.append("--prerelease")
        subprocess.run(command, check=True)
    subprocess.run([
        "gh", "release", "upload", tag, *(str(file) for file in files), "--clobber",
    ], check=True)
    subprocess.run([
        "gh", "release", "edit", tag, "--draft=false",
        f"--prerelease={str(prerelease).lower()}", f"--latest={str(latest).lower()}",
    ], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    commands = parser.add_subparsers(dest="command", required=True)
    info = commands.add_parser("metadata")
    info.add_argument("--ref", default=os.environ.get("GITHUB_REF", ""))
    info.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    info.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"))
    bundle = commands.add_parser("package")
    bundle.add_argument("--target", choices=TARGETS, required=True)
    bundle.add_argument("--version", required=True)
    bundle.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    bundle.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    upload = commands.add_parser("publish")
    upload.add_argument("--tag", required=True)
    upload.add_argument("--directory", type=Path, default=Path("build/releases"))
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "metadata":
        values = metadata(root, args.ref, args.sha)
        if args.output:
            with Path(args.output).open("a", encoding="utf-8") as stream:
                stream.write("".join(f"{key}={value}\n" for key, value in values.items()))
        print(json.dumps(values))
    elif args.command == "package":
        package(root, args.target, args.version, args.repository, args.sha)
    else:
        publish(root, args.directory.resolve(), args.tag)


if __name__ == "__main__":
    main()
