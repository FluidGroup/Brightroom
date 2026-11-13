# Color Grading

`ColorGradingFeature` and the built-in editor controls are implemented. Adobe
compatibility is incomplete: Global closely predicts the measured SDR cases;
some shadow/highlight hues and combinations still differ substantially. Do not
advertise this implementation as a Lightroom preset renderer. Full measured
results are in [the comparison report](../Tools/LightroomComparison/measurements.md).

```swift
let grading = ColorGradingFeature(
  shadows: .init(hue: 225, saturation: 20),
  midtones: .init(hue: 37, saturation: 10, luminance: 5),
  highlights: .init(hue: 52, saturation: 25),
  global: .init(hue: 52, saturation: 5),
  blending: 50,
  balance: 0
)
```

## Contract

Each range stores Hue (0...360 degrees), Saturation (0...100), and Luminance
(-100...100). Blending is 0...100, default 50; Balance is -100...100, default 0.
They influence the three tonal corrections, independently of Global. Plain
initializers and mutations clamp finite values and replace nonfinite values
with zero. Validating initializers reject invalid values. Hue is retained when
saturation is zero. A correction with zero saturation and luminance is neutral;
a wholly neutral feature returns the input CIImage itself.

The feature computes in linear ProPhoto/ROMM RGB using Bradford-adapted
extended-linear Display-P3 as the Core Image kernel interface. Alpha and extent
are preserved. The measured domain is SDR, 0...1. Outside it, channel curves
continue with unit slope; this is Brightroom's explicit finite-HDR behavior,
not a measured Adobe HDR response.

The editor evaluates grading after contrast and before spatial effects. A host
can place the standalone feature elsewhere in its own composition. This order
is a Brightroom contract, not a claim about Adobe's internal pipeline. The UI
has four range selectors, a hue/saturation wheel, H/S/L sliders, Blending and
Balance, and range/all resets. Gesture previews stay in ImageEditorSession;
completed operations flow through the existing document/history mechanism.

## Current model and limitations

For Global, let `c = HSV(hue, 1, 1)`, and `t = 0.28 * saturation/100 * (2*c-1)`.
Each linear ProPhoto channel uses `f(x,t) = x*(1+t)/(1+t*(2*x-1))`.
Luminance applies a second transform with `t = 0.24 * luminance/100`.
This formula is inferred from independent input/output observations. No Adobe
implementation or SDK source was copied.

Local ranges use 725 measured grayscale responses on a 5-point grid of Blending,
Balance, and strength. Midtone saturation interpolates rational responses;
shadow/highlight hue interpolates primary/secondary response curves. Curves
are stored as UInt16 linear values at 257 shaper positions (603,958 bytes),
interpolated over parameters and sampled in one Metal pass. The calibration
builder reproduces the bundled bytes exactly and checks retained hashes.

The assumed permutation of shadow/highlight hue responses is an unresolved
model error. The worst validation case (highlights H289/S41/L27/B72/A30) has
p95 error 0.182707 in linear Display-P3. Combined cases have p95 0.0210...0.0299.
Increasing reference density along Blending alone will not fix that hue model.
The next investigation should measure hue/strength jointly at fixed B/A, then
validate the corrected mapping on freshly withheld settings and photographs.

The common-photo Global H52/S30 result has p95 0.000223 and maximum 0.000663 over
24 million pixels. These numbers apply to that case and output color management,
not all pictures or grading settings. See the report for the neutral floor and
all parameter cases. No perceptual acceptance threshold has been assigned.

## RAW and XMP

The comparison operates on identical developed 16-bit RGB pixels. Adobe RAW
profiles are upstream and remain different from Apple RAW development. Neither
an XMP profile name nor a LookTable identifier contains the missing profile data.
Adobe documentation describes control behavior, but does not specify an exact
public raw-versus-pixel pipeline boundary for every Basic or Curve operation.

`Tools/LightroomComparison/develop-xmp.py` is a host-side experiment for the
supplied files, not a general library XMP importer. It writes the exact mappings,
unsupported effects, input hashes, rendered dimensions and output hashes.
The adapter maps the signed Light controls, point curves, Color Mixer, Texture,
Clarity, Dehaze and grain into public features. Sharpening and vignette use
approximate mappings. Regional tone curves, noise reduction, lens corrections
and Adobe RAW profiles remain outside the adapter. The supplied files have zero
grading saturation and luminance in every range. The chart and isolated grading
exports above measure this feature independently of A10.

The actual iOS 27.2 run used `SourceImage(rawContentsOf:)` and
`EditingDocument.render()`. It produced a 6000×4000 neutral image, a 6000×2553
photo-XMP image and a 6000×4000 A10 image, all 16-bit Display-P3 PNG. The subsequent
RAW precision change now materializes **16-bit floating-point extended-linear
Display-P3**, once and eagerly. A 24 MP source retains 192 MB of bitmap storage,
twice the previous 8-bit intermediate, excluding decoder and GPU buffers.
The resize/upload path was tested for retained floating-point precision.
The RAW decoder uses Apple's profile. The common calibration TIFF and its
Lightroom export supply the post-development comparison. [DNG and XMP rendering commands](../Tools/LightroomComparison/README.md#develop-a-dng-with-the-partial-xmp-adapter)

## Verification

- Color Grading and color-space/video context tests: 8 tests passed, including
  parameterized cases for all four ranges and four context configurations.
- Editor document tests: 17 passed, including grading preview, end-of-gesture
  commit, unchanged-write suppression, undo/redo, and reset preserving exposure.
- macOS ParametricMacDemo and iOS SwiftUIDemo builds passed.
- iPhone 18 Pro simulator interaction verified wheel, slider end values, independent
  range selection, Blending/Balance and resets. A stale slider-end closure was
  reproduced and corrected; document/history tests cover the commit behavior.
- 20 reference comparisons completed (neutral + 19 parameter combinations),
  plus the full-resolution photograph. Calibration and validation sets are
  distinguished; there is no automatic compatibility pass.

Sources for control meanings and color-space definitions:
[Adobe Color Grading overview](https://blog.adobe.com/en/publish/2020/10/20/introducing-color-grading),
[ICC ROMM RGB definition](https://registry.color.org/rgb-registry/rommrgb).
The formulas and error measurements above are experimental findings.
