"""Shared compile-time feature flags for desktop builds and packaging."""
import base64
import binascii
import json
from pathlib import Path


MULTIPLAYER_DEFINE = "FYL_ENABLE_MULTIPLAYER"


def multiplayer_enabled(dart_defines=""):
    enabled = False
    for encoded in dart_defines.split(","):
        if not encoded:
            continue
        try:
            decoded = base64.b64decode(encoded, validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError) as error:
            raise ValueError("Invalid base64 DART_DEFINES") from error
        key, _, value = decoded.partition("=")
        if key == MULTIPLAYER_DEFINE:
            # Matches bool.fromEnvironment, including last-definition wins.
            enabled = value == "true"
    return enabled


def network_directory(bundle, target):
    return Path(bundle) / ("Contents/Resources/fyl-network" if target == "macos" else "data/fyl-network")


def feature_manifest(bundle, target):
    return network_directory(bundle, target).parent / "fyl-build-flags.json"


def write_features(bundle, target, enabled):
    root = Path(bundle).resolve()
    file = feature_manifest(bundle, target)
    if file.is_symlink() or not file.parent.resolve().is_relative_to(root):
        raise ValueError("Build feature metadata must stay inside the bundle")
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps({"schemaVersion": 1, "multiplayer": enabled}) + "\n", encoding="utf-8")


def read_features(bundle, target):
    file = feature_manifest(bundle, target)
    if not file.exists():
        return False
    data = json.loads(file.read_text(encoding="utf-8"))
    if (not isinstance(data, dict) or data.get("schemaVersion") != 1
            or type(data.get("multiplayer")) is not bool):
        raise ValueError("Invalid build feature metadata")
    return data["multiplayer"]


def clean_network_directory(output):
    """Remove only known generated helper files; never recursively delete data."""
    output = Path(output).absolute()
    if output.parent == output:
        raise ValueError("Invalid network helper output directory")
    if output.is_symlink():
        output.unlink()
        return
    if not output.exists():
        return
    for name in ("fyl-network", "fyl-network.exe", "THIRD-PARTY-LICENSES.txt"):
        file = output / name
        if file.is_symlink() or file.exists():
            file.unlink()
    try:
        output.rmdir()
    except OSError as error:
        raise ValueError(f"Unexpected files in generated network helper directory: {output}") from error
