#!/usr/bin/env python3
"""Rebuild or verify Brightroom's package-owned Core Image Metal resources."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = Path(__file__).resolve().relative_to(ROOT)
SOURCES = [
    Path("Sources/BrightroomParametric/ToneCurve/ToneCurveKernels.metal"),
    Path("Sources/BrightroomParametric/ColorMixer/ColorMixerKernels.metal"),
]
RESOURCE_DIRECTORY = ROOT / "Sources/BrightroomParametric/ColorAdjustmentKernels"
MANIFEST = RESOURCE_DIRECTORY / "manifest.json"
PLATFORMS = [
    ("ios", "iphoneos", "air64-apple-ios17.0"),
    ("simulator", "iphonesimulator", "air64-apple-ios17.0-simulator"),
    ("macos", "macosx", "air64-apple-macos14.0"),
    ("catalyst", "macosx", "air64-apple-ios17.0-macabi"),
]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    return {str(path): sha256(ROOT / path) for path in [SCRIPT, *SOURCES]}


def output_name(platform):
    return f"BrightroomColorAdjustments-{platform}.metallib"


def run(arguments, cwd=None, source=None):
    return subprocess.check_output(arguments, cwd=cwd, input=source, text=True).strip()


def check():
    manifest = json.loads(MANIFEST.read_text())
    if manifest["schemaVersion"] != 1:
        raise RuntimeError("Unsupported kernel manifest schema.")
    if manifest["inputs"] != inputs():
        raise RuntimeError("Kernel sources or rebuild script changed; regenerate the libraries.")
    if manifest["targets"] != {platform: target for platform, _, target in PLATFORMS}:
        raise RuntimeError("The manifest platform targets do not match the rebuild contract.")
    expected_names = {output_name(platform) for platform, _, _ in PLATFORMS}
    if set(manifest["outputs"]) != expected_names:
        raise RuntimeError("The manifest does not contain every supported platform.")
    for name, digest in manifest["outputs"].items():
        if sha256(RESOURCE_DIRECTORY / name) != digest:
            raise RuntimeError(f"Kernel resource fingerprint mismatch: {name}")
    print("Color adjustment kernel sources, script, and all four libraries match the manifest.")


def build():
    RESOURCE_DIRECTORY.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="Brightroom-ColorKernels-") as temporary:
        staging = Path(temporary)
        for platform, sdk, target in PLATFORMS:
            (staging / platform).mkdir()
            sdk_path = run(["xcrun", "--sdk", sdk, "--show-sdk-path"])
            objects = []
            for source in SOURCES:
                object_path = f"{platform}/{source.stem}.air"
                run([
                    "xcrun", "--sdk", sdk, "metal", "-c", "-target", target,
                    "-isysroot", sdk_path, "-fcikernel",
                    "-fmetal-math-mode=fast", "-fmetal-math-fp32-functions=fast",
                    "-x", "metal", "-", "-o", object_path,
                ], cwd=staging, source=(ROOT / source).read_text())
                # Feeding source bytes through stdin avoids absolute checkout
                # paths in Metal's air.source_file_name metadata. Prefix-map
                # compiler flags do not rewrite that Core Image metadata.
                objects.append(object_path)
            run([
                "xcrun", "--sdk", sdk, "metal", "-target", target,
                "-fcikernel", *objects, "-o", output_name(platform),
            ], cwd=staging)

        # Publish only after every platform compiles and links successfully.
        for platform, _, _ in PLATFORMS:
            name = output_name(platform)
            shutil.copyfile(staging / name, RESOURCE_DIRECTORY / name)

    manifest = {
        "schemaVersion": 1,
        "toolchain": {
            "xcode": run(["xcodebuild", "-version"]),
            "metal": run(["xcrun", "metal", "--version"]),
        },
        "targets": {platform: target for platform, _, target in PLATFORMS},
        "inputs": inputs(),
        "outputs": {
            output_name(platform): sha256(RESOURCE_DIRECTORY / output_name(platform))
            for platform, _, _ in PLATFORMS
        },
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    check()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify fingerprints without compiling.")
    arguments = parser.parse_args()
    try:
        check() if arguments.check else build()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
