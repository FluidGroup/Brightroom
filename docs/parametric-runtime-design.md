# Parametric Runtime Design

## Status

Adopted 2026-06. This document fixes the data-structure design of
`BrightroomParametric` after the removal of the JSON-backed registry model.

Amended 2026-09: the library no longer owns persistence. `ParametricDocumentCodec`,
`PersistableFeature`, and the library's `Codable` conformances were removed;
hosts store edits in their own format (see
[Saving parametric edits](parametric-persistence.md)).

## Principles

1. **The runtime document is not a text document.** The in-memory editing
   model is a Swift-native value tree: plain structs, `Equatable`, `Sendable`,
   copy-on-write through standard containers (`Array`, `Data`). No JSON, no
   string-keyed dictionaries, no type-erased byte payloads participate in
   evaluation, equality, or history snapshots.
2. **Behavior is protocol conformance.** A feature's parameters are a struct;
   its evaluation is a protocol requirement (`apply(to:context:)`). Runtime
   dispatch is Swift protocol dispatch — no registry lookup, no string keys in
   the hot path.
3. **The host owns persistence.** The library defines feature values, their
   validation, and their evaluation — not a storage format. Every authored
   parameter is reachable and reconstructible through public API; where a
   plain initializer clamps or repairs input, a validating initializer
   rejects values the editor could not have produced. The host decides which
   feature types it stores, how assets such as LUTs are referenced, and how
   its own old formats migrate.
4. **No `JSONValue`.** Nothing in the library represents features as a
   generic JSON tree or a type-erased payload. A host that stores an open set
   of features defines its own closed model — for example an enum of the
   types it supports — so unknown types and migrations are compiler-checked
   in the host.

## Runtime model

```text
EditingDocument
  └─ MainTree.features: [MainFeature]        // evaluation order
       ├─ .domain(any DomainFeatureType)     // crop, future geometry
       ├─ .effect(any ImageEffectFeatureType)
       └─ .localAdjustment(LocalAdjustmentFeature)
             ├─ effectPipeline: [any ImageEffectFeatureType]
             └─ maskTree: MaskTree (closed enum: brush/invert/feather/union/intersect/subtract)
```

- `Feature` (base protocol): `id: FeatureID`, `isEnabled`, `Equatable`,
  `Sendable`. **Not** `Codable`.
- `ImageEffectFeatureType: Feature` adds
  `apply(to: CIImage, context: FeatureEvaluationContext) throws -> CIImage`
  and `validate() throws`. Extent-preserving by contract.
- `DomainFeatureType: Feature` adds the same shape for domain-changing
  features (output may change extent; the evaluator re-normalizes to zero
  origin).
- Existing parameter structs (`BrightnessFeature`, `GaussianBlurFeature`,
  `CropFeature`, …) are unchanged as data; their CI recipes move from the
  compiler's switch into their conformances (kept in a separate file so the
  model stays pure data).
- Containers holding existentials (`MainFeature`, `PresetFeature`,
  `LocalAdjustmentFeature`, `EffectPipeline`) implement `Equatable` via
  existential opening (`SE-0352`).
- The mask tree stays a closed enum for now; opening it for generated masks
  (subject/sky) follows the same pattern later.

A custom filter is therefore:

```swift
struct Posterize: ImageEffectFeatureType {
  var id: FeatureID = .init()
  var isEnabled: Bool = true
  var levels: Double
  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
      .cropped(to: image.extent)
  }
}
```

No registration is required to render it, and nothing is required to store
it: the host that owns `Posterize` also owns its saved form.

## Persistence

The host converts the features it supports to its own `Codable` model and
rebuilds them through public initializers. The library contributes the
pieces a host cannot write itself:

- public access to every authored parameter;
- validating reconstruction where the editing API clamps or repairs values
  (`ToneCurve(validating:)`, `ColorMixerBandAdjustment(validatingHue:saturation:luminance:)`);
- stable raw values for semantic choices (`ColorMixerFeature.Algorithm`) and
  interpretation versions a host can store (`ToneCurveFeature.semanticVersion`).

Derived render state — compiled plans, sampled tables, caches, GPU resources —
is never part of an authored value. See
[Saving parametric edits](parametric-persistence.md) for the recipe and for
reading documents written by the removed `ParametricDocumentCodec`.

## Evaluation

`FeatureGraphCompiler` keeps its lazy-`CIImage` contract (no intermediate
materialization; callers own `CIContext`) and loses both dispatch tables:
effects and domain features evaluate through their protocol conformances;
the compiler retains tree-level validation (duplicate IDs, empty composites),
local-adjustment compositing, and the mask-tree renderer (GPU brush stamps
via `ParametricKernelRegistry`).

## Tone Curve and Color Mixer

`ToneCurveFeature` and `ColorMixerFeature` are built-in, extent-preserving
effects in `BrightroomParametric`. Their editable value types and hashable
render identities are public; sampled plans, reference processors, caches,
and Metal evaluation are implementation details. Editors can bind the values
without owning a renderer or adopting BrightroomUI.

```swift
var curves = ToneCurveEditorValue.neutral
curves.y.insertPoint(input: 0.5, output: 0.6)

var mixer = ColorMixerAdjustment.neutral
mixer.red.hue = 23
mixer.red.saturation = -24

let document = EditingDocument(mainTree: MainTree(features: [
  .effect(ToneCurveFeature(value: curves)),
  .effect(ColorMixerFeature(adjustment: mixer, algorithm: .oklch)),
]))
```

The host chooses feature order and interprets the source encoding. Both effects
expect extended-linear Display-P3 numbers, preserve premultiplied alpha and
extended-range values, and return the input image exactly when neutral. Tone
Curve uses the existing scene-linear stop shaper, with normalized 0.5 at 18%
gray, and independent RGB curves followed by the authored Y luminance result.
Color Mixer applies eight adjacent hue bands in OKLCh without gamut clipping.
Changing their order or feeding unmanaged camera values is an explicit host
policy, not an automatic input conversion performed by the features.

`ColorMixerFeature.Algorithm` names the rendering semantics of the feature.
Its only current case is `.oklch`; the `algorithm` parameter of
`ColorMixerFeature(id:adjustment:algorithm:)` defaults to `.oklch`, so existing
`ColorMixerFeature(adjustment:)` calls keep the same result. The algorithm is
part of the feature, its compiled plan, feature equality, and render identity.
`ColorMixerRenderIdentity(activeAdjustment:algorithm:)` has the same default;
hosts choosing an algorithm must use that choice for both rendering and cache
identity. This API does not add a second algorithm, change editor controls, or
claim compatibility with Adobe Lightroom's Color Mixer.

Curve render identities ignore point UUIDs and diagonal-only structure. Mixer
render identities include the selected algorithm and the same normalized
Float32 parameters as the kernel.
The curve's one-entry plan and table caches use `OSAllocatedUnfairLock`, keeping
iOS 17 / macOS 14 compatibility. Compiled kernels are loaded from the package
resource bundle, independently of the host application's Metal library. The
build system compiles the sources in `BrightroomColorAdjustmentKernels`; its
separate target keeps the general Core Image compiler flags away from the
existing brush shaders. See [Building the color adjustment kernels](color-adjustment-kernels.md)
for SwiftPM and Tuist integration.

A host restores both effects from authored values alone: Tone Curve points
through `ToneCurve.Point(id:input:output:)` and `ToneCurve(validating:)`, which
keep endpoint moves and interior point identities, and Mixer bands through
`ColorMixerBandAdjustment(validatingHue:saturation:luminance:)`, which rejects
non-finite and out-of-range values instead of clamping them. Constructing the
feature rebuilds its plan; sampled tables and GPU resources are never stored.
Default feature IDs are deterministic; a host placing multiple instances of
the same effect in one tree must supply distinct IDs.

`ColorMixerFeature.Algorithm` raw values (`"oklch"`) are stable identifiers a
host can store. A host should reject an identifier it does not recognize
instead of silently changing the edit's rendering semantics.
`ToneCurveFeature.semanticVersion` is part of the curve's render identity; a
host that stores it can detect a future change in interpretation.

## What this deletes

- `JSONValue`, `FeatureNode`, `FeatureDocument`, `FeatureRegistry`,
  `AnyImageEffectFeatureDefinition`-style erasure, `FeatureNodeBridge` —
  the entire JSON-backed second model.
- Per-apply JSON decode/encode and double validation.
- The closed `ImageEffectFeature`/`DomainFeature` enums (replaced by the
  protocols above).

## Known follow-ups

- Open the mask vocabulary with the same protocol pattern.
- Parameter metadata (`range`/neutral descriptors) on conformances for
  slider UIs.
- Engine convergence: `EditingStack.Edit`'s features adopt this vocabulary,
  replacing `Filtering`/`AnyFilter`/`Filter*`/`Edit.Filters`; an
  `EditingCrop`-backed `DomainFeatureType` brings rotation/straighten into
  the parametric domain features.
