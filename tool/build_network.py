"""Build FYL's unprivileged Minecraft peer helper; never starts the helper."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

if __package__:
    from .build_features import clean_network_directory, multiplayer_enabled, network_directory, write_features
else:
    from build_features import clean_network_directory, multiplayer_enabled, network_directory, write_features

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "native/multiplayer"


def json_objects(text):
    decoder = json.JSONDecoder()
    offset = 0
    while offset < len(text):
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text):
            break
        value, offset = decoder.raw_decode(text, offset)
        yield value


def build(target, output, arch, go):
    if output.is_symlink():
        raise ValueError("Network helper output must not be a symlink")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    executable = output / ("fyl-network.exe" if target == "windows" else "fyl-network")
    if executable.is_symlink() or (output / "THIRD-PARTY-LICENSES.txt").is_symlink():
        raise ValueError("Generated network helper files must not be symlinks")
    env = dict(os.environ, CGO_ENABLED="0", GOTOOLCHAIN="local")
    version = subprocess.check_output([go, "version"], text=True, env=env)
    fingerprint = hashlib.sha256((target + arch + str(output) + version).encode())
    for source in sorted([*SOURCE.glob("*.go"), SOURCE / "go.mod", SOURCE / "go.sum", Path(__file__)]):
        fingerprint.update(source.read_bytes())
    stamps = ROOT / "build/network-stamps"
    stamps.mkdir(parents=True, exist_ok=True)
    stamp = stamps / (hashlib.sha256(str(output).encode()).hexdigest() + ".txt")
    digest = fingerprint.hexdigest()
    if (executable.is_file() and stamp.is_file() and stamp.read_text() == digest
            and (output / "THIRD-PARTY-LICENSES.txt").is_file()):
        return
    os_name = {"windows": "windows", "linux": "linux", "macos": "darwin"}[target]
    architectures = ["amd64", "arm64"] if arch == "universal" else [{"x64": "amd64", "arm64": "arm64"}[arch]]
    built = []
    scratch = ROOT / "build/network-binaries"
    scratch.mkdir(parents=True, exist_ok=True)
    for machine in architectures:
        binary = scratch / f"fyl-network-{target}-{machine}"
        flags = "-s -w" + (" -H=windowsgui" if target == "windows" else "")
        subprocess.run([go, "build", "-trimpath", "-buildvcs=false", "-mod=readonly",
                        "-ldflags", flags, "-o", str(binary), "."],
                       cwd=SOURCE, env=dict(env, GOOS=os_name, GOARCH=machine), check=True)
        built.append(binary)
    if arch == "universal":
        subprocess.run(["/usr/bin/lipo", "-create", *map(str, built), "-output", str(executable)], check=True)
    else:
        shutil.copyfile(built[0], executable)
    executable.chmod(0o755)

    # Ship the licenses for the pinned dependency graph and Go standard library.
    modules = subprocess.check_output([go, "list", "-m", "-json", "all"], cwd=SOURCE, env=env, text=True)
    licenses = []
    for module in json_objects(modules):
        directory = module.get("Dir")
        if not directory or module.get("Main"):
            continue
        for name in ("LICENSE", "LICENSE.txt", "COPYING", "NOTICE", "PATENTS"):
            file = Path(directory) / name
            if file.is_file():
                licenses.append(f"{module['Path']} {module.get('Version', '')} — {name}\n\n" + file.read_text(encoding="utf-8"))
    go_root = subprocess.check_output([go, "env", "GOROOT"], env=env, text=True).strip()
    licenses.append("Go standard library\n\n" + (Path(go_root) / "LICENSE").read_text(encoding="utf-8"))
    (output / "THIRD-PARTY-LICENSES.txt").write_text("\n\n".join(licenses), encoding="utf-8")
    stamp.write_text(digest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("windows", "linux", "macos"), required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundle-root", type=Path, help="Write matching feature metadata into this application bundle")
    feature = parser.add_mutually_exclusive_group()
    feature.add_argument("--enable-multiplayer", action="store_true", help="Explicitly build the experimental helper")
    feature.add_argument("--dart-defines", default="", help="Flutter's base64-encoded DART_DEFINES")
    parser.add_argument("--arch", choices=("x64", "arm64", "universal"))
    parser.add_argument("--archs", help="macOS Xcode ARCHS value")
    parser.add_argument("--go", default=shutil.which("go"))
    args = parser.parse_args()
    enabled = args.enable_multiplayer or multiplayer_enabled(args.dart_defines)
    arch = args.arch or ("arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x64")
    if args.archs:
        machines = set(args.archs.split())
        arch = "universal" if machines == {"x86_64", "arm64"} else "arm64" if machines == {"arm64"} else "x64"
    if arch == "universal" and args.target != "macos":
        parser.error("Universal binaries are only supported on macOS")
    output = args.output
    bundle = args.bundle_root
    if output is None:
        if bundle is None:
            if __package__:
                from .release import bundle_path
            else:
                from release import bundle_path
            bundle = bundle_path(ROOT, args.target)
        output = network_directory(bundle, args.target)
    if bundle is not None and output.absolute() != network_directory(bundle, args.target).absolute():
        parser.error("Network helper output must match the application bundle")
    if enabled:
        if not args.go:
            parser.error("Go 1.24 or later is required when FYL_ENABLE_MULTIPLAYER=true")
        build(args.target, output, arch, args.go)
    else:
        clean_network_directory(output)
    if bundle is not None:
        write_features(bundle, args.target, enabled)


if __name__ == "__main__":
    main()
