# Parametric Runtime Design

## Status

Adopted 2026-06. This document fixes the data-structure design of
`BrightroomParametric` after the removal of the JSON-backed registry model.

Amended 2026-09: the library no longer owns persistence. `ParametricDocumentCodec`,
`PersistableFeature`, and the library's `Codable` conformances were removed;
hosts store edits in their own format (see
[Saving parametric edits](parametric-persistence.md)).

Amended 2026-09 (v6): edits are static compositions. The 5.x identified
model (the parametric `EditingDocument` with its `MainTree`, `FeatureID`,
`isEnabled`, and the `ImageEffectFeatureType` / `DomainFeatureType`
protocols) was removed. An edit is a root feature: a `Feature` value whose
`body` lists its members, the way a SwiftUI view lists its content.
BrightroomEngine's `EditingDocument` (a new type that reuses the 5.x name)
pairs a root feature with its source image and undo history; this library
knows nothing about images or history.

Amended 2026-09 (v6 naming): names follow the vocabulary in
[Vision of Editing](vision-of-editing.md#vocabulary). [Migrating to
Brightroom 6](MIGRATION_TO_V6.md) maps the 5.1.1 API to the new one.

## Principles

1. **The runtime edit is not a text document.** The in-memory editing
   model is a Swift-native value tree: plain structs, `Equatable`, `Sendable`,
   copy-on-write through standard containers (`Array`, `Data`). No JSON, no
   string-keyed dictionaries, no type-erased byte payloads participate in
   evaluation, equality, or history snapshots. `AnyImageEffect` erases the
   type of a typed value; it is not a payload.
2. **Behavior is protocol conformance.** A feature's parameters are a struct;
   its evaluation is a protocol requirement (`apply(to:context:)`) or its
   `body`. Runtime dispatch is Swift protocol dispatch — no registry lookup,
   no string keys in the hot path.
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
5. **Edits are static compositions; identity is the value.** A root
   feature's structure is its Swift type. Features have no `id` and no
   `isEnabled`: two root features built from the same values are equal, and a
   feature is switched off by leaving it out (a `nil` member, a branch not
   taken, a mask node removed). Hosts address parts of an edit by their own
   member names.
6. **`any` only where data decides content.** A preset catalog or a list of
   effects decoded by the host is `[AnyImageEffect]`. Everything the code
   decides keeps its static type.

## Runtime model

- `Feature` is the base protocol: `Sendable`, with an associated `Body`, a
  `@FeatureBuilder var body`, and `apply(to:context:)`.
  - A *primitive* implements `apply(to: CIImage, context: FeatureEvaluationContext) throws -> CIImage`
    and leaves `Body` as `Never` (`ExposureFeature`, `CropFeature`, …).
  - A *composite* declares `body`; the default `apply` evaluates it
    (`FilterFeature`, `ImageEditorFeature`, a host's root feature).
- `ImageEffect: Feature` marks features that preserve the extent and
  coordinate domain of their input. A composite is an `ImageEffect` only when
  its body is one. Features that are not image effects, such as `CropFeature`,
  may change the domain; they return a zero-origin image of the new domain,
  and later members work in it.
- `FeatureBuilder` builds bodies. Members evaluate in order, and each receives
  the previous member's output. `if`/`else`, `switch`, `for`, optional
  members, and `if #available` produce the structural types `TupleFeature`,
  `EitherFeature`, `Optional`, `Array`, and `EmptyFeature`, which are
  features themselves. An `if #available` branch of equatable image effects is
  erased to `AnyImageEffect`, so a body's type never names an unavailable
  type.
- `LocalAdjustmentFeature<Content: ImageEffect>` applies its content where
  its `Mask` allows. The content cannot contain a domain feature; the compiler
  rejects it.
- `AnyImageEffect` wraps an `ImageEffect & Equatable` value whose type is
  decided at run time. `[AnyImageEffect]` is itself an image effect that
  evaluates in order.
- `Mask` stays a closed indirect enum (brush, inverted, feathered, union,
  intersection, subtraction); opening it for generated masks (subject/sky) follows
  the same protocol pattern later.
- Every built-in value is `Equatable`, so root features compare with `==`
  and owners (undo history, canvas caches) can drop updates that change
  nothing.
  Equality compares a value's stored, authored members; derived state such as
  a compiled render plan never takes part. "Renders the same" is a separate
  question, answered by the render identity types where a cache needs it.

A root feature's structure is visible in its type. `ImageEditorFeature` declares

```swift
var body: some Feature {
  effects
  localBlur
  crop
}
```

and its body's type is

```text
TupleFeature<
  ImageEditorFeature.Effects,                    // composite ImageEffect: preset + 12 optional effects
  Optional<LocalAdjustmentFeature<GaussianBlurFeature>>,
  CropFeature                                    // domain feature: the final crop
>
```

A custom effect is therefore:

```swift
import BrightroomParametric
import CoreImage

struct Posterize: ImageEffect, Equatable {
  var levels: Double

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
      .cropped(to: image.extent)
  }
}
```

A custom domain feature conforms to `Feature` and returns its output in the
new domain, with a zero origin:

```swift
import BrightroomParametric
import CoreImage

struct Inset: Feature, Equatable {
  var amount: CGFloat

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let extent = image.extent.insetBy(dx: amount, dy: amount)
    return image
      .cropped(to: extent)
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
  }
}
```

A composite groups other features, and a host's root feature is a
composite. This example uses `Posterize` and `Inset` from the two examples
above:

```swift
struct FilmLook: ImageEffect, Equatable {
  var strength: Double
  var grain: Posterize?

  var body: some ImageEffect {
    SaturationFeature(value: -0.2 * strength)
    FadeFeature(intensity: 0.1 * strength)
    grain
  }
}

struct EditFeature: Feature, Equatable {
  var look: FilmLook?
  var inset: Inset?
  var crop: CropFeature

  var body: some Feature {
    look
    inset
    crop
  }
}
```

No registration is required to render these, and nothing is required to store
them: the host that owns `Posterize` also owns its saved form.

## Persistence

The host converts the features it supports to its own `Codable` model and
rebuilds them through public initializers. There are no feature ids to store;
enablement is whether a member is present. The library contributes the pieces
a host cannot write itself:

- public access to every authored parameter;
- validating reconstruction where the editing API clamps or repairs values
  (`ToneCurve(validating:)`, `ColorMixerFeature.BandCorrection(validatingHue:saturation:luminance:)`),
  and `validate()` on `CropFeature` and `ColorCubeFeature`, whose initializers
  accept any value;
- stable raw values for semantic choices (`ColorMixerFeature.Algorithm`) and
  interpretation versions a host can store (`ToneCurveFeature.semanticVersion`).

Derived render state — compiled plans, sampled tables, caches, GPU resources —
is never part of an authored value. See
[Saving parametric edits](parametric-persistence.md) for the recipe and for
reading documents written by the removed `ParametricDocumentCodec`.

## Evaluation

Evaluation keeps its lazy-`CIImage` contract: no intermediate
materialization, and callers own the `CIContext`.

- `FeatureRenderer().makeImage(from:feature:)` prepares the chain
  entry once: it translates the source to zero origin, fixes the chain-entry extent
  (value-form radii resolve against the entry extent, or against
  `chainEntryExtent` for a viewport slice), and sets the presentation
  time. The `FeatureEvaluationContext` then flows down through every `body`.
  `ExportRenderer` and `VideoRenderer` evaluate through
  the same path.
- `LocalAdjustmentFeature` renders its mask over its input extent (GPU brush
  stamps and mask combinators through internal Metal kernels), evaluates its
  content, and composites the result through the mask alpha. An empty
  union or intersection throws before the content is evaluated. Content that
  returns its input unchanged makes the whole adjustment return its input.
  `FeatureRenderer().makeMaskImage(for:extent:)` renders the same
  alpha for inspection.
- Validation happens where a value is applied: `CropFeature` and
  `ColorCubeFeature` call their public `validate()` from `apply`.
- Evaluation errors are `FeatureEvaluationError` (a `LocalizedError`):
  `invalidCropRect(CGRect)`,
  `invalidColorCubeData(id:expectedByteCount:actualByteCount:)`,
  `emptyMaskComposite`, `kernelUnavailable(name:reason:)`, and
  `imageCreationFailed(String)`. Built-in features and the renderers throw no
  other error type while evaluating.
- The renderers take `some Feature`. A `nil` optional feature leaves its
  input unchanged, as an absent member does, so rendering `nil` renders the
  unedited image. `EmptyFeature()` says the same explicitly.
- `EditingDocument.render(options:)` (BrightroomEngine) renders a document's
  root feature over its full-resolution source image through
  `ExportRenderer`.
- `FeatureTreeView(feature:)` and `FeatureTreeOutline(feature:)` show a
  feature's body structure for debugging, in evaluation order. Node ids are
  type paths (`FilterFeature#0/WhiteBalanceFeature#0`), so an absent member
  does not re-key the nodes after it.

## Tone Curve and Color Mixer

`ToneCurveFeature` and `ColorMixerFeature` are built-in, extent-preserving
effects in `BrightroomParametric`. Their editable value types and hashable
render identities are public; sampled plans, reference processors, caches,
and Metal evaluation are implementation details. Editors can bind the values
without owning a renderer or adopting BrightroomUI.

```swift
import BrightroomParametric

struct ColorGrade: ImageEffect, Equatable {
  var curves: ToneCurveFeature?
  var mixer: ColorMixerFeature?

  var body: some ImageEffect {
    curves
    mixer
  }
}

func makeGrade() -> ColorGrade {
  var curves = ToneCurveFeature.Curves.neutral
  curves.y.insertPoint(input: 0.5, output: 0.6)

  var mixer = ColorMixerFeature.Bands.neutral
  mixer.red.hue = 23
  mixer.red.saturation = -24

  return ColorGrade(
    curves: ToneCurveFeature(curves: curves),
    mixer: ColorMixerFeature(bands: mixer, algorithm: .oklch)
  )
}
```

The host chooses feature order and interprets the source encoding. Both effects
expect extended-linear Display-P3 numbers, preserve premultiplied alpha and
extended-range values, and return the input image exactly when neutral. Tone
Curve uses the existing scene-linear stop shaper, with normalized 0.5 at 18%
gray, and independent RGB curves followed by the authored Y luminance result.
Color Mixer applies eight adjacent hue bands in OKLCh without gamut clipping.
Changing their order or feeding unmanaged camera values is an explicit host
policy, not an automatic input conversion performed by the features.

Neither effect has an `isEnabled` flag. To leave one out, make its member
`nil`. To ask whether a value renders as identity, use the same condition as
the neutral bypass: `ToneCurveFeature.RenderKey(activeCurves:) == nil` for a
curve, and `ColorMixerFeature.Bands.isIdentity` for a mixer.
`ToneCurveFeature.Curves.isDefault` is not that condition: a curve with
interior points on the diagonal is not the default, but it still renders as
identity.

`ColorMixerFeature.Algorithm` names the rendering semantics of the feature.
Its only current case is `.oklch`; the `algorithm` parameter of
`ColorMixerFeature(bands:algorithm:)` defaults to `.oklch`, so existing
`ColorMixerFeature(bands:)` calls keep the same result. The algorithm is
part of the feature, its compiled plan, feature equality, and render identity.
`ColorMixerFeature.RenderKey(activeBands:algorithm:)` has the same default;
hosts choosing an algorithm must use that choice for both rendering and cache
identity. This API does not add a second algorithm, change editor controls, or
claim compatibility with Adobe Lightroom's Color Mixer.

Tone Curve points are plain `(input, output)` coordinates with no identity of
their own: the first and last points are the endpoints, and editing addresses
a point by its index, which a move never changes. Curve render identities
drop channels that render as identity, such as a channel whose only interior
points lie on the diagonal. Mixer render identities include the selected
algorithm and the same normalized Float32 parameters as the kernel.

Equality of both features compares their stored, authored members like
every other feature: `curves` for a curve, `bands` and `algorithm` for a
mixer. The compiled plan is derived state and does not take part. Two curves
that differ only in diagonal interior points are therefore not equal, and
neither are mixers whose values differ as Doubles but round to the same
Float32 parameters. An owner that drops equal updates (such as an undo
history) keeps such an edit. Code that needs "renders the same", such as a
preview cache, compares `ToneCurveFeature.RenderKey` or `ColorMixerFeature.RenderKey`
explicitly.

The curve's one-entry plan and table caches use `OSAllocatedUnfairLock`, keeping
iOS 17 / macOS 14 compatibility. Compiled kernels are loaded from the package
resource bundle, independently of the host application's Metal library. The
build system compiles the sources in `BrightroomColorAdjustmentKernels`; its
separate target keeps the general Core Image compiler flags away from the
existing brush shaders. See [Building the color adjustment kernels](color-adjustment-kernels.md)
for SwiftPM and Tuist integration.

A host restores both effects from authored values alone: Tone Curve points
through `ToneCurve.Point(input:output:)` and `ToneCurve(validating:)`, which
keeps endpoint moves and rejects points that are out of range, out of order,
or too close together, and Mixer bands through
`ColorMixerFeature.BandCorrection(validatingHue:saturation:luminance:)`, which rejects
non-finite and out-of-range values instead of clamping them. Constructing the
feature rebuilds its plan; sampled tables and GPU resources are never stored.

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
- The closed `ImageEffectFeature`/`DomainFeature` enums.
- (v6) The identified model: `FeatureID`, `IdentifiedFeature` (an unreleased
  transitional name), the parametric `EditingDocument` (5.x), `MainTree`,
  `MainFeature`, `EffectPipeline`, `EffectPipelineFeature`, the 5.x
  `LocalAdjustmentFeature(maskTree:effectPipeline:blendMode:)`, the
  `ImageEffectFeatureType` and `DomainFeatureType` protocols with their
  `childFeatures` and `validate()` requirements, duplicate-id validation, the
  existential equality helpers, `FeatureGraphCompiler` with
  `FeatureGraphOutput`, the public `ParametricKernelRegistry` with its error
  type, and every `id` and `isEnabled` property.

## Known follow-ups

- Open the mask vocabulary with the same protocol pattern.
- Parameter metadata (`range`/neutral descriptors) on conformances for
  slider UIs.
