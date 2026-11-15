# Replaceable adjustment rendering

## Design and scope

Feature values remain the editing vocabulary. An immutable `AdjustmentRendering`
belongs to a renderer or host, never an `EditingDocument` or its history. It
travels in `FeatureEvaluationContext` through static composition and local
adjustments. There is no global selection or string-dispatch registry.

`AdjustmentImplementation` has typed entry points for `ExposureFeature` and
`HighlightsShadowsFeature`. The latter is intercepted before its `body` applies
interaction compensation, so implementations receive both original amounts.
Returning nil explicitly delegates an unsupported adjustment to its original
recipe; throwing is a failure, never permission to fall back. A context with
`usingStandardAdjustments()` permits explicit nonrecursive standard delegation.

Selection is deliberately named `overridingSupportedFeatures(with:)`: choosing
it is consent to replace the algorithms of supported feature types. Standard
selection preserves every existing algorithm and numeric interpretation.
Unhooked feature types retain their original behavior under either selection.

The implementation supplies a semantic identity including its version and all
output-affecting settings/model hashes. Equal identities promise interchangeable
output. Hosts combine this with their source, feature values, time, scale and
output options; a Feature RenderKey alone is not an output cache key. Changing
selection invalidates canvas recipes and downstream bakes without decoding the
source again or writing edits back.

This slice builds an actual external GradingKit runtime and carries the same
selection from preview to export/video. It does not move existing calibration
models, introduce missing adjustment types, or claim Lightroom equivalence.

## Host ownership and lifetime

```swift
let rendering = AdjustmentRendering.overridingSupportedFeatures(
  with: GradingImplementation(exposureShoulder: 0.75)
)

// Host imports GradingKit; Brightroom's products never do.
ImageEditor(document: $document, onDone: export)
  .adjustmentRendering(rendering)

let output = try await document.render(adjustmentRendering: rendering)
let graph = try FeatureRenderer(adjustmentRendering: rendering)
  .makeImage(from: source, feature: document.feature)
```

The host owns one immutable selection and supplies it to preview and export.
Changing it does not rebuild features, mutate the document, commit history, or
change source identity. The editor environment is an explicit view-tree input,
not process-wide or task-local configuration. Standalone UIKit/internal canvas
construction receives it through `setAdjustmentRendering`; SwiftUI applies it
when making and updating its representable. Exports do not read a SwiftUI
environment: the host must pass the same value explicitly.

`FeatureRenderer`, `ExportRenderer`, and `VideoRenderer` retain their selection.
Two renderers with different selections can run concurrently. Implementations
may share immutable kernels/tables; they must not keep mutable per-frame input,
time, scale, or selected feature in shared storage. Required-resource/kernel
failures throw. Neutral evaluation bypasses implementation/resource lookup.

The protocol's default methods return nil, so adding another typed hook later
does not require existing external conformers to support it. There is no
reflection, JSON dispatch, implementation enum, registration, or type-name
lookup. Identity strings describe output semantics only. Returning nil is a
deliberate unsupported decision, not a catch-all for an error. Implementations
must preserve extent and premultiplied alpha and return lazy `CIImage` graphs;
renderers do not materialize an image to cross this boundary.

## Evaluation and cache routes

| Route | Selection and retained semantics |
| --- | --- |
| `FeatureRenderer.makeImage` and package intermediate helper | One selection enters the evaluation context; zero-origin normalization and original chain-entry extent are unchanged. |
| `ExportRenderer`, async/synchronous `EditingDocument.render` | Construct the feature renderer with the explicit selection; export's working/output format and color-space policy are unchanged. |
| `VideoRenderer.makeImage` and output-size dry run | Both use the retained feature renderer. Exact frame `presentationTime` is forwarded; the size probe keeps its original zero time/transparent source. |
| Composite bodies, optional/array/erased effects, `LocalAdjustmentFeature` | The same context goes to each child, including masked content. No feature equality or storage changes. |
| Context copies | `withChainEntryExtent` and `withRenderScale` retain selection and time; `usingStandardAdjustments` changes only selection, preventing recursive delegation. |
| `ImageEditor` / `ImageEditorCanvas` | View environment feeds both crop and tool surfaces without recreating the preview loader. |
| Global and local preview recipes | Both factories pass selection, chain-entry extent, and actual downsample factor; errors throw to the surface. |
| Final crop / post-crop Vignette and Grain | Geometry/order are unchanged. The generic post-crop evaluator receives selection from render images and the viewport's render scale. Unhooked Vignette/Grain preserve their existing recipe and seed semantics. |

Crop and tool render-input keys include the semantic implementation identity.
A changed identity regenerates render images even if feature values are equal;
`setRenderImages` increments generation and discards prepared content/layers,
viewport textures, and pre-finish caches. Post-crop evaluation then uses the new
selection. Identical semantic identities avoid this invalidation. A failed
recipe clears its input key so returning to a previously successful selection
retries instead of showing stale success. Canvas failures show an opaque error
state; the post-crop renderer clears its output and invalidates its pre-finish
cache instead of treating failure as identity. Source decoding is not involved.

The standard identity names this baseline's calibration revision. Changes to
standard pixel semantics must advance that identity; external implementations
must likewise advance version/configuration for changed math, model bytes,
working-space policy, or other output-affecting settings. This is a contract,
not automatic hashing of arbitrary executable code.

## Feature coverage and algorithm precedence

“Standard” below means deliberately retaining the original recipe, not a new
GradingKit approximation. Only the two typed hooks in this slice are replaceable;
the remaining existing types need additional hooks before external replacement.
Their existing `algorithm` properties are never rewritten or inferred to be a
default. Today neither hooked type has an algorithm selector. Future hooks on
algorithm-bearing types must retain the explicit `overridingSupportedFeatures`
contract (or introduce a separately named policy), never silently disregard it.

| Control | Current feature / authored units, neutral | Existing algorithm / resources | Exchange point and this slice |
| --- | --- | --- | --- |
| Exposure | `ExposureFeature.ev`, EV, 0 | `CIExposureAdjust`, no table | Typed primitive hook; GradingKit gain/shoulder kernel supported. |
| Contrast | `ContrastFeature.value`, offset, 0 | `CIColorControls` contrast = 1 + value | Standard; future primitive hook. Not a Lightroom −100…100 control. |
| Highlights | `HighlightsFeature.value`, recovery, 0; XMP amount = −100 × value | `HighlightShadowAlgorithm.coreImage` / `.lightroomApproximation`; spatial model + H/S resources | Standalone feature remains standard, including algorithm choice. Future typed primitive hook. |
| Shadows | `ShadowsFeature.value`, lift, 0; XMP amount = 100 × value | Same enum/resources | Standalone feature remains standard. Future typed primitive hook. |
| Highlights + Shadows | `HighlightsShadowsFeature.highlights/shadows`, signed −100…100, (0,0) | Original coupled Shadows→Highlights approximation | Typed compound hook before compensation/decomposition; GradingKit joint neighborhood response supported. Unhandled hook evaluates the original body. |
| Whites / Blacks | `WhitesFeature.amount` / `BlacksFeature.amount`, signed −100…100, 0 | Measured tonal-point recipes; tonal-point and strong-whites resources | Standard; future independent hooks while retaining adaptive/spatial response. |
| Point curve Master/R/G/B | `PointCurveFeature.Curves`, normalized `ToneCurve`s; diagonal neutral; `refineSaturation` | PV15.4 developed-RGB curve response, semantic version 2; shared curve kernels | Standard; future whole-feature hook with all channels. |
| Existing Y/R/G/B curves | `ToneCurveFeature.Curves`, normalized curves, diagonal neutral | Scene-linear stop shaper/render plan, semantic version 4 | Standard. Not a substitute for Lightroom's Parametric Curve. |
| Parametric Curve | No corresponding feature | References exist, no authored runtime model | Future parameter type, validation, UI and hook design; not supported. |
| White balance | `WhiteBalanceFeature.temperature` (Kelvin offset), `tint` (offset), (0,0) | `CITemperatureAndTint` | Standard; future compound hook. Not absolute Lightroom Temperature/Tint. |
| Vibrance | No corresponding feature | No runtime recipe | Future parameter type and implementation; not Saturation. |
| Saturation | `SaturationFeature.value`, offset, 0; Lightroom initializer divides by 100 | `.coreImage` / `.lightroomApproximation`; saturation calibration | Standard; future hook retains explicit algorithm semantics. |
| Color Mixer | `ColorMixerFeature.Bands`, each H/S/L −100…100, 0 | `.oklch` / `.lightroomApproximation`; mixer calibration | Standard; future hook takes all bands + algorithm. |
| Color Grading | `ColorGradingFeature`, four hue 0…360°, saturation 0…100/luminance −100…100 corrections; blending/balance | Measured multi-range recipe; grading calibration | Standard; future whole-feature hook. |
| Color Calibration RGB primaries H/S + Shadow Tint | No corresponding feature | No runtime recipe; corpus probes are not authored controls | Future parameter types, validation and hook. `HighlightShadowTintFeature` is a full-image alpha overlay, not Calibration or Color Grading. |
| Texture / Clarity / Dehaze | `TextureFeature` / `ClarityFeature` / `DehazeFeature.amount`, signed −100…100, 0 | Existing measured spatial/detail recipes, shared Metal kernels | Standard; future typed hooks must retain neighborhood/scale semantics. |
| Vignette | `VignetteFeature.value`, Core Image intensity, 0 | `CIVignetteEffect`, input-extent center/radius | Standard; post-crop context carries selection but no Vignette hook yet. Not Lightroom's complete Post-Crop Vignette controls. |
| Grain | `GrainFeature` amount/roughness 0…100, `EffectRadius`, seed; `GrainFeature.CameraRaw` amount/size/roughness 0…100, seed; amount 0 neutral | Existing deterministic float kernels / measured Camera Raw mapping | Standard; no seed/time reinterpretation. Future spatial/statistical validation, not a pointwise LUT. |

## Calibration resources: unchanged, not solved

All existing resources still ship with Brightroom: **16,984,622 bytes (16.20
MiB)** of calibration files, before compiled kernels and packaging. Selecting
GradingKit does **not** remove them. The new runtime bundles only generated
metallibs; `assets/`, `studies/`, `acquisition/`, TIFF/XMP, and run outputs are
outside its explicit target paths. SwiftPM still fetches the GradingKit Git
repository/corpus history; repository download size is not app bundle size.

| Existing data (bytes) | Paired processing | Next-stage destination / compatibility |
| --- | --- | --- |
| `ColorGradingCalibration.bin` (603,958) | `ColorGradingRecipe`, grading kernels | Optional calibrated implementation/model target; preserve four-range response and exact data bytes. |
| `ColorMixerCalibration.lzfse` (2,178,574) | `ColorMixerCalibrationRecipe`, mixer kernels | Optional calibrated model target; keep OKLCh standard path independent. |
| `SaturationCalibration.lzfse` (3,551,889) | `SaturationRecipe`, saturation kernels | Optional calibrated model target; keep Core Image standard path. |
| `TonalPointCalibration.lzfse` (5,424,365), `StrongWhitesCalibration.lzfse` (5,166,721) | `TonalPointRecipe`, `StrongWhitesRecipe`, tonal/spatial kernels | Optional calibrated model target with primitive/compound hooks and whole-image statistics unchanged. |
| `HighlightShadowCalibration.json` (50,535), `HighlightStrength.bin` (8,580) | `HighlightShadowRecipe`, current coupled feature body and spatial kernels | Optional calibrated model target after adding standalone H/S hooks; preserve original coupled behavior as a versioned implementation. |

Concrete follow-up:

1. Inventory each file's SHA-256, provenance and available generator inputs;
   retain original bytes. The new 920-condition corpus cannot be assumed to
   regenerate historical bins/LZFSE byte-identically; document missing sources.
2. Add typed hooks for the existing calibrated feature types, with neutral,
   validation, algorithm precedence and error tests before moving recipes.
3. Extract implementation-private loaders, Metal recipes and only their required
   models into optional GradingKit runtime/model targets. Share only proven
   generic color-space/geometry primitives; no dependency back from Brightroom
   products. Keep research data out of those resources.
4. Choose an explicit compatibility/release plan for legacy calibrated enums and
   types. Removing their bundled data while promising unchanged `.standard`
   output is not compatible. A legacy calibrated product/versioned migration is
   needed before a smaller core can become the default; no silent downgrade.
5. Measure fetched repository bytes, linked kernel bytes, resource bundle bytes,
   and app archive size separately. Freeze golden renders across every route,
   then consider deprecations only with an edit-preserving migration.
