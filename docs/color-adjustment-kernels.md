# Color adjustment kernel packaging

Tone Curve and Color Mixer use general Core Image kernels with explicit image
sampling. Their sources remain in `Sources/BrightroomParametric/ToneCurve` and
`Sources/BrightroomParametric/ColorMixer`. The package excludes those two `.metal`
files from automatic Metal compilation and copies the corresponding precompiled
libraries as ordinary resources. Native SwiftPM and Tuist consumers therefore
need no custom Metal flags or build plugins.

The libraries use the legacy Core Image ABI (`-fcikernel` for compilation and
linking), matching the original general-kernel sampling contract. The existing
brush shader library remains separate and unchanged. Kernels are loaded from
`Bundle.module`; shader source is never compiled at runtime.

Four resources target iOS 17, iOS 17 Simulator, macOS 14, and Mac Catalyst 17.
`ColorAdjustmentMetalLibrary` chooses the resource at compile time. Moving the
minimum operating system version requires updating the manifest, package
platforms, and compiler targets deliberately.

## Rebuilding and verifying

Rebuilding requires macOS, Python 3, and a complete Xcode installation with its
Metal toolchain and iOS, Simulator, and macOS SDKs. Select Xcode with
`DEVELOPER_DIR` or `xcode-select`. Consumers only need the checked-in resources.

```sh
python3 Scripts/build-color-adjustment-kernels.py
python3 Scripts/build-color-adjustment-kernels.py --check
```

Run the rebuild after changing either shader or the rebuild script. Commit the
sources, all four `.metallib` files, and
`Sources/BrightroomParametric/ColorAdjustmentKernels/manifest.json` together.
The manifest records SHA-256 fingerprints for both sources, the script, and
every binary, plus compiler versions and platform targets. `--check` verifies
these fingerprints without requiring Xcode; it fails for stale or changed
inputs and resources. It is an integrity check, not a replacement for GPU
rendering tests.

The script streams source bytes through standard input with fixed compile
arguments so Metal's source-file metadata does not contain the checkout or
temporary build directory. With the same toolchain, repeated builds produce
identical library bytes. The script compiles
all platforms successfully before replacing the checked-in resources. Changing
the Xcode or Metal compiler may legitimately change the binaries; rerun the
Tone Curve and Color Mixer numeric/parity tests after rebuilding.

Apple documents the separate legacy and stitchable compilation requirements in
[Explore Core Image kernel improvements](https://developer.apple.com/videos/play/wwdc2021/10159/).
Stitchable general kernels need Core Image Metal linker flags, which SwiftPM's
target manifest does not expose. Ordinary Swift linker settings cannot supply
those flags to the Metal resource build.
