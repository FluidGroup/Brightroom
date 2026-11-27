# Feature implementation setup

Feature values describe edits, not the implementation that renders them.
Brightroom owns composition, editing, history, crop/mask geometry, preview,
export and video. Its standard adjustments are lightweight and do not aim to
reproduce Lightroom. Optional GradingKit supplies per-Feature calculations,
their calibration models and their Metal kernels.

## Connect once, evaluate normally

```swift
import BrightroomGradingKit
import BrightroomParametric

var setup = AdjustmentRendering.Setup()
GradingImplementation().install(into: &setup)
let rendering = setup.makeRendering()

ImageEditor(document: $document, onDone: export)
  .adjustmentRendering(rendering)
let output = try await document.render(adjustmentRendering: rendering)
let video = VideoRenderer(adjustmentRendering: rendering)
```

The host owns this immutable configuration and passes the same value to every
route. Export does not implicitly read a SwiftUI environment. GradingKit does
not own an editor, document, render loop or output policy.

Installation is ordinary typed Swift code. A host can instead install just one
calculation, or replace it later in the mutable setup:

```swift
var setup = AdjustmentRendering.Setup()
let grading = GradingImplementation()
setup.replace(ExposureFeature.self, with: grading.exposure)
let rendering = setup.makeRendering()
```

Each slot holds an `AdjustmentRendering.Implementation<F>`: a semantic identity
and a `@Sendable (F, CIImage, FeatureEvaluationContext) throws -> CIImage`
operation. Registration order does not affect identity; the last replacement
of a slot wins. A snapshot is unaffected by subsequent edits to the setup.
`.standard` is the empty snapshot. There is no process-wide mutation,
reflection, type-name lookup or string-dispatch registry in evaluation.

An unregistered Feature uses its standard recipe. A registered operation must
return an image or throw; it cannot silently fall back after a failure.
`context.usingStandardAdjustments()` permits explicit, nonrecursive delegation.
Exact neutral bypass happens before calling the slot. Captured resources must
be concurrency-safe; output-affecting state is immutable after setup.

The compound `HighlightsShadowsFeature` is intercepted before decomposing its
body. Its provider receives both original authored amounts and owns any
interaction math. Without a compound replacement, the ordinary
Shadows-then-Highlights body is evaluated normally.

## Editing values and compatibility

Authored amounts, units, range validation, composition and the editing/history
model stay common. Implementation selection is not an authored quantity.

This is a deliberate source and pixel compatibility break:

- Removed `SaturationFeature.Algorithm`, `HighlightShadowAlgorithm`,
  `ColorMixerFeature.Algorithm`, their stored selectors and selecting initializers.
  There is no compatibility facade.
- Removed the earlier `AdjustmentImplementation` protocol and
  `overridingSupportedFeatures(with:)` factory in favor of typed setup.
- `ColorMixerFeature.RenderKey` describes bands, not implementation choice;
  its semantic version is 3. Persist authored values, not this render key.
- GradingKit's `lightroomAmount:` initializers on Saturation, Highlights and
  Shadows only convert units. They do **not** install a renderer.
- `.standard` now means lightweight processing, not the previous calibrated
  output. Use an explicit GradingKit configuration for the moved calculations.
  GradingKit's Exposure remains a separate experimental shoulder model, not a
  relocated old Exposure implementation.

Features remain plain values. Selecting a provider does not change their
parameters, create a new document or commit an undo step. Apps continue to own
their persistence formats; no library storage format is introduced.

## Coverage

All listed slots are typed and independently replaceable.

| Feature / authored units | Brightroom standard | GradingKit installer |
| --- | --- | --- |
| Exposure / EV, zero neutral | Core Image exposure | Experimental gain/shoulder |
| Vibrance / signed −100…100 | Core Image vibrance | Measured SDR RGB response |
| Saturation / normalized offset, zero neutral | Core Image saturation | Measured RGB response atlas |
| Highlights / normalized recovery; Shadows / normalized lift | Core Image highlight/shadow controls | Measured spatial responses |
| HighlightsShadows / two signed −100…100 amounts | Shadows then Highlights | Original calibrated coupling and spatial responses |
| Whites, Blacks / signed −100…100 | Analytic bright-tone gain / dark-tone lift | Tonal-point lattices and adaptive strong Whites |
| ColorMixer / eight H/S/L bands, −100…100 | Lightweight OKLCh kernel | Measured band-response atlas |
| ColorGrading / four hue, saturation, luminance corrections; blending/balance | Analytic tonal weights, gain and tint | Calibrated channel curves and global response |
| Clarity / signed −100…100 | Gaussian local contrast; chain-entry-relative radius | Measured local-contrast/color response |
| Texture / signed −100…100 | Gaussian detail; full-resolution pixel radius | Measured multiscale detail response |
| Dehaze / signed −100…100 | Contrast and saturation | Measured scene/neighborhood response |
| Grain / amount, EffectRadius, roughness, seed | Lightweight deterministic grain | Not installed; host may register its own |
| Grain.CameraRaw / amount, size, roughness, seed | Lightweight grain with pixel-scale size | Measured Camera Raw grain mapping |

All other types retain their existing standard evaluation: contrast, white
balance, curves, vignette, geometry, masks and custom Feature bodies are not
newly replaced. Lightroom Parametric Curve and Color Calibration
primaries/Shadow Tint still have no corresponding authored types here. This
boundary does not claim full Lightroom control coverage or fidelity.

## Routes and caches

| Route | Contract |
| --- | --- |
| FeatureRenderer | Configuration enters the context with original chain-entry coordinates and zero-origin normalization. |
| ExportRenderer and EditingDocument.render | Explicit configuration; unchanged working/output formats and color-space policy. |
| VideoRenderer | The same configuration for frames and size probes; exact frame time is forwarded. |
| Bodies, arrays, erased effects and LocalAdjustmentFeature | Context continues through composition and masked content. |
| Context copies | Scale/extent copies preserve configuration and time; standard delegation changes only configuration. |
| ImageEditor and ImageEditorCanvas | View-tree configuration feeds global/local recipes without replacing the preview loader. |
| Post-crop evaluation | Configuration and viewport scale reach the final pass; crop ordering and seed ownership remain unchanged. |

Operations return lazy Core Image graphs, preserving input extent and
premultiplied alpha. They do not decode the input, quantize to 8-bit or render
through UIKit. Spatial providers use chain-entry extent and renderScale, not
a downstream crop as a new coordinate system.

The snapshot identity incorporates the final installed identities in fixed
slot order and the lightweight standard version. Each provider identity must
include its math/model version and every output-affecting setting. Equal
identities promise interchangeable output; arbitrary executable code is not
automatically hashed.

Canvas recipe keys, Metal texture equality and downstream bake keys include
this identity alongside source/Feature/time/scale state. Changing configuration
regenerates pixels without re-decoding the source or changing history. Failed
evaluation is not cached as success; canvas and post-crop paths invalidate
their output rather than presenting a standard-rendering fallback.

## Ownership of data and code

The seven former Brightroom calibration files (16,984,622 bytes / 16.20 MiB)
and their loaders, specialized Swift calculations and Metal moved to
`BrightroomGradingKit/Sources/BrightroomGradingKit`. Their bytes were preserved,
not regenerated or compressed differently. Brightroom's manifest no longer
declares those resources and its kernel plugin no longer compiles their
dedicated shaders.

Brightroom retains shared geometry/masks, lightweight adjustments and their
small kernels. It does not depend on GradingKit. GradingKit depends on
BrightroomParametric; the host connects the two explicitly.

See GradingKit's `runtime.md` and `calibration-provenance.md` for the resource
hashes, reproducible pre-migration fixture, verification and accuracy limits.
Research assets, TIFF/XMP, acquisition workspaces and golden-test fixtures are
not runtime resources. SwiftPM repository download size is separate from app
bundle size; the optional repository still contains its large research corpus.
