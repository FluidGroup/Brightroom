# Saving Parametric Edits

`BrightroomParametric` defines feature values, their validation, and their
evaluation. It does not define how edits are stored. Your app decides:

- which feature types it saves,
- the storage format and its versioning,
- how large assets such as LUTs are referenced,
- how its own older formats migrate.

Undo and redo belong to the document's owner, such as
`PhotosCropEditingModel`, which keeps in-memory document values and needs no
storage format.

## Recipe

1. Compose your document from the features your app supports. Optional
   members are features that can be absent; a member that is present is
   enabled. Features carry no identity, so there are no ids to store.
2. Define a `Codable` model for that document. For content decided by data,
   such as a list of `AnyImageEffect`, use an enum with one case per feature
   type. A closed model makes unsupported types and migrations explicit in
   your code.
3. To save, convert the *current* document to that model. Save the edited
   result, not only the values you started from.
4. To restore, rebuild features through their public initializers. Use the
   validating initializers and `validate()` methods below for values that did
   not come from an editing control, and reject what they reject.

```swift
import BrightroomParametric

/// The app's document: the features it supports, in a fixed order.
struct Look: ImageEffect, Equatable {
  var exposure: ExposureFeature?
  var lut: ColorCubeFeature?
  var extras: [AnyImageEffect] = []

  var body: some ImageEffect {
    exposure
    lut
    extras
  }
}

/// The app's saved form of a look. A present field is a present member.
struct StoredLook: Codable {
  struct StoredLUT: Codable {
    var assetID: String
    var amount: Double
  }

  var exposure: Double?
  var lut: StoredLUT?
  var extras: [StoredEffect]

  init(_ look: Look) throws {
    exposure = look.exposure?.value
    lut = look.lut.map { StoredLUT(assetID: $0.identifier, amount: $0.amount) }
    extras = try look.extras.map(StoredEffect.init)
  }

  func makeLook(loadLUT: (String) throws -> ColorCubeFeature) throws -> Look {
    var look = Look()
    look.exposure = exposure.map { ExposureFeature(value: $0) }
    if let lut {
      var feature = try loadLUT(lut.assetID)  // Cube data stays in your asset catalog.
      feature.amount = lut.amount
      try feature.validate()
      look.lut = feature
    }
    look.extras = extras.map { $0.makeEffect() }
    return look
  }
}

/// An effect in the look's data-driven list.
enum StoredEffect: Codable {
  case fade(intensity: Double)
  case vignette(value: Double)

  init(_ effect: AnyImageEffect) throws {
    switch effect.base {
    case let fade as FadeFeature:
      self = .fade(intensity: fade.intensity)
    case let vignette as VignetteFeature:
      self = .vignette(value: vignette.value)
    default:
      throw StorageError.unsupportedFeature(String(describing: type(of: effect.base)))
    }
  }

  func makeEffect() -> AnyImageEffect {
    switch self {
    case .fade(let intensity):
      AnyImageEffect(FadeFeature(intensity: intensity))
    case .vignette(let value):
      AnyImageEffect(VignetteFeature(value: value))
    }
  }
}

enum StorageError: Error {
  case unsupportedFeature(String)
}
```

A rebuilt document equals the one that was saved, because features compare by
value. A complete example covering Exposure, Tone Curve, Color Mixer, and LUTs,
with rejection of invalid stored values, is
[`AppOwnedPersistenceExampleTests.swift`](../Tests/BrightroomParametricTests/AppOwnedPersistenceExampleTests.swift).
It uses only the public API.

## What to Store

| Feature | Store | Rebuild with |
| --- | --- | --- |
| Enablement | whether the member is present | an optional member, `if`, or leaving the feature out |
| `CropFeature` | `cropRect`, `rotation.rawValue`, `straightenRadians` | `QuarterTurn(rawValue:)`, `CropFeature(cropRect:rotation:straightenRadians:)`, then call `validate()` |
| `ColorCubeFeature` | a reference to your asset, `amount` | load the cube, set `amount`, then call `validate()` |
| `ToneCurveFeature` | each channel's points in order (`input`, `output`), `ToneCurveFeature.semanticVersion` | `ToneCurve.Point(input:output:)`, `ToneCurve(validating:)` |
| `ColorMixerFeature` | `hue`, `saturation`, `luminance` for all eight bands, `algorithm.rawValue` | `ColorMixerBandAdjustment(validatingHue:saturation:luminance:)`, `ColorMixerFeature.Algorithm(rawValue:)` |
| `PresetFeature` | `name`, `identifier`, and its effects | the same conversion for each effect, wrapped in `AnyImageEffect`; read each stored effect through `base` |
| `LocalAdjustment` | the mask tree and the content | `MaskTree`, `MaskNode`, `BrushMask`, `BrushMaskStroke`, `BrushMaskBrush`, and the content's own conversion |
| `PhotosCropDocument` (BrightroomUI) | each present effect in `effects`; the blur mask (its `GaussianBlurFeature.radius`, which is `.absolute` or `.proportional`, and each stroke's stamps, which are y-up working-space points, and brush); the crop (`cropRect`, `rotation`, `straightenRadians`) | `PhotosCropDocument(effects:blurMask:crop:)`; resume editing with `PhotosCropEditingModel(editingStack:resuming:)` |

Notes:

- `CropFeature` and `ColorCubeFeature` initializers accept any value. Their
  `validate()` methods reject a crop rectangle that is not a finite, non-empty
  extent and cube data that does not match its dimension; rendering would
  throw the same errors later.
- Mask trees have no `validate()`. A union or intersection with no inputs
  restores without error and throws `FeatureEvaluationError.emptyMaskComposite`
  when it renders. Reject empty composites while converting if your storage
  can hold them.
- Tone Curve points are plain coordinates with no identity. Store them in
  order: `ToneCurve(validating:)` makes the first and last points the
  endpoints, wherever they were moved. It returns `nil` instead of repairing
  or reordering invalid points.
- `ColorMixerBandAdjustment(hue:saturation:luminance:)` clamps and is meant for
  editing controls; clamping does not reject NaN. Restore stored values with
  the validating initializer, which returns `nil` for non-finite or
  out-of-range values.
- Compare `ToneCurveFeature.semanticVersion` with the stored value and decide
  what to do with curves authored under a different interpretation.
- Reject a Color Mixer algorithm identifier you do not recognize instead of
  substituting another algorithm.
- Feature equality compares every stored, authored parameter, including Tone
  Curve diagonal points and Color Mixer values exactly as Doubles. A
  conversion that loses any of them produces a document that is not equal to
  the saved one. To ask whether two values render the same, compare
  `ToneCurveRenderIdentity` or `ColorMixerRenderIdentity` instead.
- A `PhotosCropDocument` is authored for one image: its domain is the oriented
  image size (`EditingStack.Loaded.imageSize`). Store a reference to the
  source image with it, and resume it only over that image.

## Migrating from `ParametricDocumentCodec`

Brightroom 5.0 and 5.1 shipped `ParametricDocumentCodec`, `PersistableFeature`,
`FeatureTypeKey`, and `Codable` conformances on the feature types. They have
been removed. If your app stored documents with the codec, read them with your
own decoder and convert them to features, or to your new storage model, once.

The codec wrote JSON with sorted keys. Its authoritative definition is
[`ParametricDocumentCodec.swift` at 5.1.0](https://github.com/FluidGroup/Brightroom/blob/5.1.0/Sources/BrightroomParametric/ParametricDocumentCodec.swift).

### Document

```json
{
  "formatVersion": 1,
  "mainTree": {
    "features": [
      { "kind": "domain", "feature": { "type": "brightroom.domain.crop", "v": 2, "params": { } } },
      { "kind": "effect", "feature": { "type": "brightroom.effect.exposure", "v": 1, "params": { } } },
      { "kind": "localAdjustment", "feature": { "id": { }, "isEnabled": true, "blendMode": "alpha", "maskTree": { }, "effectPipeline": { } } }
    ]
  }
}
```

- `formatVersion` is always `1`.
- Domain features and effects are wrapped in an envelope: `type` (the feature
  type key), `v` (the parameter schema version), and `params`.
- Local adjustments are not wrapped. Their `effectPipeline` is
  `{ "effects": [envelope, …] }`.
- Features defined by your app appear under the `featureTypeKey` and
  `schemaVersion` your app declared.

### Value encodings

| Value | JSON |
| --- | --- |
| `FeatureID` | `{ "rawValue": "…" }` |
| `CGRect` | `[[x, y], [width, height]]` |
| `CGPoint` | `[x, y]` |
| `QuarterTurn` | its raw value: `0`, `-90`, `-180`, or `-270` |
| `Data` (`cubeData`) | Base64 string |
| `GaussianBlurRadius` | `{ "absolute": { "_0": 3 } }` or `{ "editingStackFilterValue": { "_0": 40 } }` |
| `MaskNode` | `{ "brush": { "_0": BrushMask } }`, `{ "invert": { "_0": MaskNode } }`, `{ "feather": { "_0": MaskFeather } }`, `{ "union": { "_0": [MaskNode] } }`, `{ "intersect": { "_0": [MaskNode] } }`, `{ "subtract": { "_0": MaskSubtract } }` |
| Tone Curve point `id` | `{ "blackEndpoint": {} }`, `{ "whiteEndpoint": {} }`, or `{ "interior": { "_0": "UUID" } }` |

Other structs use their property names as keys, for example
`BrushMaskStroke` is `{ "stamps": [[x, y], …], "brush": { "diameter", "hardness", "opacity" } }`
and `MaskFeather` is `{ "id", "isEnabled", "input", "radius" }`.

### Feature types

| `type` | `v` | `params` |
| --- | --- | --- |
| `brightroom.domain.crop` | 2 | `id`, `isEnabled`, `cropRect`, `rotation`, `straightenRadians` |
| | 1 | `id`, `isEnabled`, `cropRect`; no rotation and no straightening |
| `brightroom.effect.preset` | 1 | `id`, `isEnabled`, `name`, `identifier`, `effects` (envelopes) |
| `brightroom.effect.pipeline` | 1 | `id`, `isEnabled`, `pipeline` (`{ "effects": [envelope, …] }`) |
| `brightroom.effect.color-cube` | 1 | `id`, `isEnabled`, `name`, `identifier`, `amount`, `dimension`, `cubeData` |
| `brightroom.effect.brightness`, `brightroom.effect.contrast`, `brightroom.effect.saturation`, `brightroom.effect.exposure`, `brightroom.effect.highlights`, `brightroom.effect.shadows`, `brightroom.effect.vignette` | 1 | `id`, `isEnabled`, `value` |
| `brightroom.effect.temperature` | 2 | `id`, `isEnabled`, `value`, `tint` |
| | 1 | `id`, `isEnabled`, `value`; tint is `0` |
| `brightroom.effect.highlight-shadow-tint` | 1 | `id`, `isEnabled`, `highlightColor`, `shadowColor` (`{ "red", "green", "blue", "alpha" }`) |
| `brightroom.effect.sharpen` | 1 | `id`, `isEnabled`, `sharpness`, `radius` |
| `brightroom.effect.unsharp-mask` | 1 | `id`, `isEnabled`, `intensity`, `radius` |
| `brightroom.effect.gaussian-blur` | 1 | `id`, `isEnabled`, `radius` |
| `brightroom.effect.fade` | 1 | `id`, `isEnabled`, `intensity` |
| `brightroom.effect.tone-curve` | 1 | `id`, `semanticVersion` (`4`), `value`: `{ "y", "red", "green", "blue" }`, each `{ "points": [{ "id", "input", "output" }, …] }` |
| `brightroom.effect.color-mixer` | 2 | `id`, `algorithm` (`"oklch"`), `adjustment`: eight bands `red` … `magenta`, each `{ "hue", "saturation", "luminance" }` |
| | 1 | `id`, `adjustment`; the algorithm is `.oklch` |

Tone Curve and Color Mixer payloads have no `isEnabled`; it is derived from
the values. The validating initializers apply the range, finiteness, count, and
spacing checks the 5.1 codec applied to Tone Curve points and Mixer axes. The
5.1 codec also checked point ids (endpoint and duplicate ids); Brightroom 6
points have no ids, so drop them when converting.

### Converting 5.x documents

Features in Brightroom 6 have no `id` and no `isEnabled`. When converting a
decoded 5.x document:

- Drop every `id`. Duplicate ids no longer matter.
- A disabled domain feature, effect, or local adjustment: leave it out.
- A disabled `BrushMask`: `BrushMask(strokes: [])`, because it covered
  nothing. A disabled `MaskFeather`: its `input`. A disabled `MaskSubtract`:
  its `base`.
- A disabled child of a preset or pipeline: leave it out of the list.
- `brightroom.effect.pipeline` (`EffectPipelineFeature`): its enabled
  effects, in place in your document or as `[AnyImageEffect]`.
- A local adjustment with no enabled effect: 5.x threw
  `emptyLocalAdjustmentEffectPipeline` when it was enabled. Brightroom 6
  renders an empty adjustment as its input, so leave it out.
- Tone Curve and Color Mixer payloads never had `isEnabled`. Drop their `id`.
- Drop each Tone Curve point's `id` as well, and keep the points in their
  stored order. The 5.1 codec required the first point to be
  `blackEndpoint` and the last `whiteEndpoint`; in Brightroom 6 their position
  alone makes them the endpoints. Points that shared an interior id across
  channels become independent points in each channel.
- Brush stamps in a document taken from 5.x `EditingStack.Edit.document`
  (for example `loadedState.currentEdit.document`, which PhotosCrop and
  `SwiftUICropView` authored) are y-down: top-left origin in the oriented
  image. `PhotosCropDocument.blurMask` and every Brightroom 6 mask are y-up, so
  flip each stamp to `y = orientedImageSize.height - y` while converting, or
  the blur mask comes back mirrored vertically. A document from
  `Edit.makeEditingDocument(orientedImageSize:)` was already y-up. Crop
  rectangles were stored in the y-up form in both and need no flip.
