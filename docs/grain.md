# Grain

`GrainFeature` adds a seeded texture independently of color adjustments.
Hosts choose its place in their feature stack, including inside a local
adjustment. The built-in editor has no grain controls.

## Camera Raw sliders

```swift
let filmGrain = GrainFeature.CameraRaw(amount: 20, size: 42, roughness: 70, seed: 0)
let image = try FeatureRenderer().makeImage(from: developedBitmap, feature: filmGrain)
```

Pass `GrainAmount`, `GrainSize` and `GrainFrequency` in their authored 0...100
units. The research adapters apply grain after crop and vignette and use
`GrainSeed` when present. The missing-seed default is zero. A seed reproduces
Brightroom's pattern across renders. Amount zero bypasses the graph exactly.
Use `init(validatingAmount:size:roughness:seed:)` to restore stored values.

The measured setting is Amount 20, Size 42 and Roughness 70. Gray ramps and
RGB edges identify a shared noise sample in ProPhoto primaries with the sRGB
transfer function. Its strength is nearly flat across middle tones and tapers
near each channel's black and white endpoints. Larger particles also soften
detail in that encoded space. The source's alpha and extent survive the blur.
Adobe describes the roles of the three sliders and the possible blurring at
Size 25 or higher. [Camera Raw grain controls](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/tone-and-color/vignette-grain-effects-camera-raw.html)

Two source sizes supplied the spatial measurements, a 1024×256 chart and a
6000×4000 photograph. One region of sky supplied the full-resolution fit.
The model scales the particle width with the square root of the uncropped
pixel area, with a subpixel lower bound. The full-resolution random field is
filtered before sampling a smaller preview. Amount scales the noise amplitude,
Size affects both particle width and input softening, and Roughness varies the
tails of the strength distribution at fixed variance. These slider laws and
intermediate source sizes are estimates. Independent one-slider sweeps are
still needed, including the photo sidecar's 25/73/65 combination.

| Amount 20, Size 42, Roughness 70 | Lightroom | Brightroom |
|---|---:|---:|
| Gray ramp, encoded grain standard deviation | 0.02769 | 0.02735 |
| Gray ramp, adjacent-pixel correlation | 0.0395 | 0.0424 |
| Photo, encoded grain standard deviation | 0.01212 | 0.01207 |
| Photo, adjacent-pixel correlation | 0.8370 | 0.8346 |

The photo measurements pool 16 disjoint 256×256 regions outside the fitting
region. With A10's other effects active, the same grid gave standard deviations
of 0.01212 and 0.01207. This validation uses one scene. Pixel comparisons
include differences in the random sample at each location. On the supplied
24 MP TIFF with the current Highlights response, enabling grain changed
full-resolution linear Display-P3 p95 from 0.043393 to 0.048452. Comparing
means over 32×32 pixel blocks gave 0.035667 and 0.035775, respectively.

The A10 runner's `--scope grain --modes adaptive adaptive-no-grain` exports
both candidates. Decode exports with `Light/decode.swift`, then use the paired
grain-off and grain-on files with `Grain/measure.py photo` or
`Grain/measure.py chart`. Use `Grain/measure.py blocks` with a reference and
a candidate for errors between block means. Each command also takes an
output JSON path and checks the source exports against their decode manifests.

To reproduce the spatial fit, run `Grain/fit.py` with the decoded chart
off/on pair, photo off/on pair, and a new output JSON path, in that order.
The fit gave a subpixel noise width of 0.212, an area-dependent width of
1.125 pixels at 24 MP, and an input blur sigma of 0.498 pixels at 24 MP.
For new slider measurements, `Grain/prepare.py` takes a neutral XMP, a
gray/color patch chart, an equal-area chart with a different aspect ratio,
a separate photograph, and a new output directory. It writes 18 cases for
the existing A10 embed, export and registration loop. Use the `patches`
metric for these charts and `photo` for the photograph.

## Procedural radius

```swift
let grain = GrainFeature(
  amount: 20,
  radius: .absolute(1),
  roughness: 70,
  seed: 3372469435
)
let image = try FeatureRenderer().makeImage(from: developedBitmap, feature: grain)
```

Amount and roughness range from 0 through 100. Amount zero returns the input
image itself. `radius` smooths the random field, in full-resolution pixels or
the existing proportional `EffectRadius` units. Roughness varies the local
strength of the grain. The seed keeps the same pattern across redraws and
video frames; this feature does not animate grain automatically.

The recipe generates normal noise in full-resolution coordinates, smooths it
with Core Image's Gaussian blur, and filters it down for a smaller preview.
The image is matched into extended-linear Display-P3 and grain is added to its
encoded RGB values, with a midtone-weighted strength. Alpha and extent are
preserved without clipping extended RGB. Preview/export texture is correlated,
not pixel-identical: image resampling and nonlinear blending occur in a
different order.

The radius-based effect smooths its random field and keeps the photograph's
edges. The original standalone demonstration in
`.tmp/xmp-research/grain-preview-001` used amount 20, radius 1 px and roughness 70.

For a standalone render, use the same built package objects as the comparison
loop. Run from the repository root with Xcode's toolchain selected:

```sh
xcodebuild -project Dev/Brightroom.xcodeproj -scheme ParametricMacDemo \
  -destination platform=macOS -derivedDataPath .tmp/xmp-derived-data \
  -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
xcrun swiftc -O -module-cache-path .tmp/swift-module-cache \
  -I .tmp/xmp-derived-data/Build/Products/Debug \
  Tools/LightroomComparison/Grain/render.swift \
  .tmp/xmp-derived-data/Build/Products/Debug/BrightroomParametric.o \
  .tmp/xmp-derived-data/Build/Products/Debug/BrightroomColorAdjustmentKernels.o \
  -o .tmp/xmp-derived-data/Build/Products/Debug/render-grain
.tmp/xmp-derived-data/Build/Products/Debug/render-grain \
  /path/to/input.tiff .tmp/grain-output 20 1 70 3372469435
```

The four numeric arguments are amount, radius in pixels, roughness, and seed.
The output directory must be new. `render.json` retains the input/output hashes
and parameters. The input's embedded color profile is used for the output.
