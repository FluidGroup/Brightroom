# Parametric Runtime Design

## Status

Adopted 2026-06. This document fixes the data-structure design of
`BrightroomParametric` after the removal of the JSON-backed registry model.

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
3. **Codable is the persistence boundary only.** Serialization goes through a
   codec that owns a type registry. Registration follows the
   `UICollectionView.register(_:forCellWithReuseIdentifier:)` shape: the host
   registers `(type key → params type)` pairs; decode resolves keys to types
   once and produces typed values.
4. **No `JSONValue`.** Two consequences of the codec design make a generic
   JSON tree representation unnecessary:
   - *Unknown types are an error, not a payload.* Like an unregistered cell
     identifier, an unregistered feature key throws — at encode time as well
     as decode time, so a codec never writes a document it cannot read back.
     There is no requirement to round-trip features the host cannot
     evaluate. If that requirement ever appears, the
     escape hatch is a `Data` blob of the nested encoding — bit-perfect and
     still JSON-model-free.
   - *Migration is typed decoding, not tree surgery.* A params type decodes
     old schema versions by declaring the old shape as a private `Decodable`
     struct and converting. Migrations are compiler-checked.

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
struct Posterize: ImageEffectFeatureType, PersistableFeature {
  static let featureTypeKey: FeatureTypeKey = "myapp.posterize"  // persistence only
  var id: FeatureID = .init()
  var isEnabled: Bool = true
  var levels: Double
  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
      .cropped(to: image.extent)
  }
}
```

No registration is required to *render* it (`PersistableFeature` and
`featureTypeKey` exist for persistence; a render-only feature can conform to
`ImageEffectFeatureType` alone). Registration is required only to persist.

## Persistence

```swift
public protocol PersistableFeature: Feature, Codable {
  static var featureTypeKey: FeatureTypeKey { get }
  static var schemaVersion: Int { get }
  // Default implementations decode the current version via Codable.
  static func decodeParameters(from decoder: Decoder, version: Int) throws -> Self
}

var codec = ParametricDocumentCodec()
codec.register(Posterize.self)                  // UICollectionView-style
let data = try codec.encode(document)
let document = try codec.decode(data)           // one pass, typed values out
```

- The codec injects its type registry through `Decoder.userInfo`; feature
  envelopes (`{type, v, params}`) decode their params **directly from the
  document stream** into typed values via nested containers. There is no
  intermediate representation.
- Unregistered key on encode or decode → `unregisteredFeatureType(key)`.
  Non-persistable feature on encode → `notPersistable(type)`. Coding without
  a codec → `missingRegistry`.
- The structural spine (document, tree, local adjustments, mask vocabulary)
  carries a single `formatVersion`, separate from per-feature `v` values, as
  the migration hook for everything between the envelopes.
- Versioning: the envelope stores `v`; `decodeParameters(from:version:)`
  switches on it. Old versions are private structs + conversions.
- Large binary parameters (color-cube data) are accepted today via `Data`
  (base64 in JSON); the planned evolution is codec-level attachment
  references (manifest + blob store) so documents stay small.

## Evaluation

`FeatureGraphCompiler` keeps its lazy-`CIImage` contract (no intermediate
materialization; callers own `CIContext`) and loses both dispatch tables:
effects and domain features evaluate through their protocol conformances;
the compiler retains tree-level validation (duplicate IDs, empty composites),
local-adjustment compositing, and the mask-tree renderer (GPU brush stamps
via `ParametricKernelRegistry`).

## What this deletes

- `JSONValue`, `FeatureNode`, `FeatureDocument`, `FeatureRegistry`,
  `AnyImageEffectFeatureDefinition`-style erasure, `FeatureNodeBridge` —
  the entire JSON-backed second model.
- Per-apply JSON decode/encode and double validation.
- The closed `ImageEffectFeature`/`DomainFeature` enums (replaced by the
  protocols above).

## Known follow-ups

- Open the mask vocabulary with the same protocol + codec pattern.
- Parameter metadata (`range`/neutral descriptors) on conformances for
  slider UIs.
- Attachment store for large binary payloads.
- Engine convergence: `EditingStack.Edit`'s features adopt this vocabulary,
  replacing `Filtering`/`AnyFilter`/`Filter*`/`Edit.Filters`; an
  `EditingCrop`-backed `DomainFeatureType` brings rotation/straighten into
  the parametric domain features.
