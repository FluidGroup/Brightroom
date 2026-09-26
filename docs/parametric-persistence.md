# Saving Parametric Edits

`BrightroomParametric` defines feature values, their validation, and their
evaluation. It does not define how edits are stored. Your app decides:

- which feature types it saves,
- the storage format and its versioning,
- how large assets such as LUTs are referenced,
- how its own older formats migrate.

Undo and redo in `EditingStack` use in-memory value snapshots and do not need a
storage format.

## Recipe

1. Define a `Codable` model for the features your app supports — typically an
   enum with one case per feature type. A closed model makes unsupported types
   and migrations explicit in your code.
2. To save, convert the *current* features to that model. Save the edited
   result, not only the values you started from.
3. To restore, rebuild features through their public initializers. Use the
   validating initializers below for values that did not come from an editing
   control, and reject what they reject.

```swift
enum StoredEffect: Codable {
  case exposure(id: String, value: Double)
  case lut(id: String, assetID: String, amount: Double)

  init(_ effect: any ImageEffectFeatureType) throws {
    switch effect {
    case let exposure as ExposureFeature:
      self = .exposure(id: exposure.id.rawValue, value: exposure.value)
    case let lut as ColorCubeFeature:
      self = .lut(id: lut.id.rawValue, assetID: lut.identifier, amount: lut.amount)
    default:
      throw StorageError.unsupportedFeature
    }
  }

  func makeFeature(loadLUT: (String) throws -> ColorCubeFeature) throws -> any ImageEffectFeatureType {
    switch self {
    case .exposure(let id, let value):
      return ExposureFeature(id: FeatureID(rawValue: id), value: value)
    case .lut(let id, let assetID, let amount):
      var lut = try loadLUT(assetID)  // Cube data stays in your asset catalog.
      lut.id = FeatureID(rawValue: id)
      lut.amount = amount
      return lut
    }
  }
}
```

A complete example covering Exposure, Tone Curve, Color Mixer, and LUTs, with
rejection of invalid stored values, is
[`AppOwnedPersistenceExampleTests.swift`](../Tests/BrightroomParametricTests/AppOwnedPersistenceExampleTests.swift).
It uses only the public API.

## What to Store

| Feature | Store | Rebuild with |
| --- | --- | --- |
| Any feature | `id.rawValue`, `isEnabled` | `FeatureID(rawValue:)` |
| `CropFeature` | `cropRect`, `rotation.rawValue`, `straightenRadians` | `QuarterTurn(rawValue:)` |
| `ColorCubeFeature` | a reference to your asset, `amount` | load the cube, then set `id`, `isEnabled`, `amount` |
| `ToneCurveFeature` | each channel's points (`id`, `input`, `output`), `ToneCurveFeature.semanticVersion` | `ToneCurve.Point(id:input:output:)`, `ToneCurve(validating:)` |
| `ColorMixerFeature` | `hue`, `saturation`, `luminance` for all eight bands, `algorithm.rawValue` | `ColorMixerBandAdjustment(validatingHue:saturation:luminance:)`, `ColorMixerFeature.Algorithm(rawValue:)` |
| `PresetFeature`, `EffectPipelineFeature` | their nested effects, recursively | the same conversion for each effect |
| `LocalAdjustmentFeature` | the mask tree and effect pipeline | `MaskTree`, `MaskNode`, `BrushMask`, … |

Notes:

- `ToneCurve(validating:)` keeps moved endpoints and interior point identities,
  including an identity shared by several channels. It returns `nil` instead of
  repairing invalid points.
- `ColorMixerBandAdjustment(hue:saturation:luminance:)` clamps and is meant for
  editing controls; clamping does not reject NaN. Restore stored values with
  the validating initializer, which returns `nil` for non-finite or
  out-of-range values.
- Compare `ToneCurveFeature.semanticVersion` with the stored value and decide
  what to do with curves authored under a different interpretation.
- Reject a Color Mixer algorithm identifier you do not recognize instead of
  substituting another algorithm.
- Feature equality compares rendered values. Check editing state such as curve
  point identities directly when testing your conversion.

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

Tone Curve and Color Mixer payloads have no `isEnabled`; it is derived from the values. The 5.1 codec rejected Tone Curve
points and Mixer axes that the validating initializers now reject, so running
restored values through those initializers preserves the old behavior.
