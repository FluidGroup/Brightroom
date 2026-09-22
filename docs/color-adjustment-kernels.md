# Building the color adjustment kernels

Tone Curve and Color Mixer ship as `.metal` source in
`Sources/BrightroomColorAdjustmentKernels`. The build system generates and
bundles their libraries. There are no checked-in `.metallib` files, manual
regeneration steps, or runtime source compilation.

The separate target owns these resources because its general Core Image
kernels require `-fcikernel` during compilation and linking. Applying that flag
to `BrightroomParametric` would break its existing stitchable brush kernel.
The original sampler ABI and shader math are preserved.

## SwiftPM and Xcode package integration

`BuildColorAdjustmentKernels` is a SwiftPM build-tool plugin attached to the
kernel target. It invokes Xcode's Metal compiler directly through `xcrun`, with
both shaders declared as inputs and each library declared as an output.
Editing either shader causes the next ordinary build to regenerate the
libraries. SwiftPM automatically packages generated resource outputs in the
target's `Bundle.module`.

The plugin produces fixed outputs for iOS 17, iOS 17 Simulator, macOS 14, and
Mac Catalyst 17. Fixed names avoid giving one output different contents when
plugin work directories are shared by destination builds. The Swift loader
selects the matching library at compile time. Update these targets alongside
`Package.swift` when changing deployment requirements.

Use a complete Xcode installation with its Metal toolchain and iOS, Simulator,
and macOS SDKs. Select it with `DEVELOPER_DIR` or `xcode-select`. Xcode may ask to
trust the build-tool plugin when first opening the package; CI can use
`-skipPackagePluginValidation` in a trusted checkout.

The source files are also visible to SwiftPM's ordinary Metal resource pass.
Their `__METAL_CIKERNEL__` guards emit the general kernels only when compiled
with `-fcikernel`; the ordinary pass therefore creates an unused empty default
library. This keeps the same sources available to build systems that compile
package targets directly.

## Tuist external packages

Tuist's `Tuist/Package.swift` plus `.external(name:)` integration converts the
package into Xcode targets and does not execute its SwiftPM build-tool plugin.
Configure the isolated kernel target in `PackageSettings.targetSettings`:

```swift
"BrightroomColorAdjustmentKernels": .settings(base: [
  "MTL_COMPILER_FLAGS": "$(inherited) -fcikernel -fmetal-math-mode=fast -fmetal-math-fp32-functions=fast",
  "MTLLINKER_FLAGS": "$(inherited) -fcikernel",
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) BRIGHTROOM_COLOR_ADJUSTMENTS_DEFAULT_LIBRARY",
]),
```

Xcode then compiles the same sources into that target's `default.metallib` for
the selected destination. The Swift condition selects this library in the
resource loader. Keep these settings confined to `BrightroomColorAdjustmentKernels`;
existing brush shaders must retain their own compilation mode. Native Xcode
package integration uses the plugin and does not need these settings.

## Verification

Run `BrightroomParametricTests` after shader edits. Its non-neutral Tone Curve
and Color Mixer rendering tests exercise the generated libraries and compare
GPU results with CPU evaluation, including alpha and extended-range values.
Brush rendering tests cover the other compilation mode. A successful Swift
build alone does not prove that Core Image can load and execute each kernel.

Apple describes the Core Image compilation modes in
[Explore Core Image kernel improvements](https://developer.apple.com/videos/play/wwdc2021/10159/).
