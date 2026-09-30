# Saving Parametric Edits

`BrightroomParametric` defines feature values, their validation, and their
evaluation. It does not define how edits are stored. Your app decides:

- which feature types it saves,
- the storage format and its versioning,
- how large assets such as LUTs are referenced,
- how its own older formats migrate.

An `EditingDocument` (BrightroomEngine) keeps the edit together with its
source image and undo history, all as in-memory values. Your app stores what
it needs to rebuild one: a reference to the image, the root feature, and,
optionally, the history. See [Documents and History](#documents-and-history).

## Recipe

1. Compose your root feature from the features your app supports. Optional
   members are features that can be absent; a member that is present is
   enabled. Features carry no identity, so there are no ids to store.
2. Define a `Codable` model for that feature. For content decided by data,
   such as a list of `AnyImageEffect`, use an enum with one case per feature
   type. A closed model makes unsupported types and migrations explicit in
   your code.
3. To save, convert the *current* feature to that model. Save the edited
   result, not only the values you started from.
4. To restore, rebuild features through their public initializers. Use the
   validating initializers and `validate()` methods below for values that did
   not come from an editing control, and reject what they reject.

```swift
import BrightroomParametric

/// The app's edit: the features it supports, in a fixed order.
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
    var intensity: Double
  }

  var exposure: Double?
  var lut: StoredLUT?
  var extras: [StoredEffect]

  init(_ look: Look) throws {
    exposure = look.exposure?.ev
    lut = look.lut.map { StoredLUT(assetID: $0.id, intensity: $0.intensity) }
    extras = try look.extras.map(StoredEffect.init)
  }

  func makeLook(loadLUT: (String) throws -> ColorCubeFeature) throws -> Look {
    var look = Look()
    look.exposure = exposure.map { ExposureFeature(ev: $0) }
    if let lut {
      var feature = try loadLUT(lut.assetID)  // Cube data stays in your asset catalog.
      feature.intensity = lut.intensity
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

A rebuilt feature equals the one that was saved, because features compare by
value. A complete example covering Exposure, Tone Curve, Color Mixer, and LUTs,
with rejection of invalid stored values, is
[`AppOwnedPersistenceExampleTests.swift`](../Tests/BrightroomParametricTests/AppOwnedPersistenceExampleTests.swift).
It uses only the public API.

## What to Store

| Feature | Store | Rebuild with |
| --- | --- | --- |
| Enablement | whether the member is present | an optional member, `if`, or leaving the feature out |
| `CropFeature` | `rect` (the selection after straightening and before the output quarter turn; y-up, relative to the crop's input origin), `quarterTurn.rawValue`, `straightenRadians` | `QuarterTurn(rawValue:)`, `CropFeature(rect:quarterTurn:straightenRadians:)`, then call `validate()` |
| `ColorCubeFeature` | a reference to your asset, `intensity` | load the cube, set `intensity`, then call `validate()` |
| `ToneCurveFeature` | each channel's points in order (`input`, `output`), `ToneCurveFeature.semanticVersion` | `ToneCurve.Point(input:output:)`, `ToneCurve(validating:)` |
| `ColorMixerFeature` | `hue`, `saturation`, `luminance` for all eight bands, `algorithm.rawValue` | `ColorMixerFeature.BandCorrection(validatingHue:saturation:luminance:)`, `ColorMixerFeature.Algorithm(rawValue:)` |
| `FilterFeature` | `name`, `id`, and its effects | the same conversion for each effect, wrapped in `AnyImageEffect`; read each stored effect through `base` |
| `LocalAdjustmentFeature` | the mask and the content | `Mask`, `BrushMask`, `BrushMask.Stroke`, `BrushMask.Brush`, and the content's own conversion |
| `ImageEditorFeature` (BrightroomUI) | each present effect in `effects`; the blur mask (its `GaussianBlurFeature.radius`, which is `.absolute` or `.proportional`, and each stroke's `stampCenters`, which are y-up working-space points, and brush); the crop (`rect` as the selection before the output quarter turn, `quarterTurn`, `straightenRadians`) | `ImageEditorFeature(effects:localBlur:crop:)`; resume editing with `ImageEditorDocument(source:feature:history:)` |

Notes:

- `CropFeature` and `ColorCubeFeature` initializers accept any value. Their
  `validate()` methods reject a crop rectangle that is not a finite, non-empty
  extent and cube data that does not match its dimension; rendering would
  throw the same errors later.
- `CropFeature` renders straighten → crop → exact quarter turn. `rect` is
  the selection before the quarter turn, so a sideways `quarterTurn` exchanges
  only the output's width and height (`outputGeometry(in:).outputBounds`);
  changing `quarterTurn` never changes the selected pixels. Parts of the
  requested canvas outside the input are transparent.
- Masks have no `validate()`. A union or intersection with no inputs
  restores without error and throws `FeatureEvaluationError.emptyMaskComposite`
  when it renders. Reject empty composites while converting if your storage
  can hold them.
- Tone Curve points are plain coordinates with no identity. Store them in
  order: `ToneCurve(validating:)` makes the first and last points the
  endpoints, wherever they were moved. It returns `nil` instead of repairing
  or reordering invalid points.
- `ColorMixerFeature.BandCorrection(hue:saturation:luminance:)` clamps and is meant for
  editing controls; clamping does not reject NaN. Restore stored values with
  the validating initializer, which returns `nil` for non-finite or
  out-of-range values.
- Compare `ToneCurveFeature.semanticVersion` with the stored value and decide
  what to do with curves authored under a different interpretation.
  Color Mixer has no public interpretation version to store: a stored Color
  Mixer renders with the library's current interpretation of its algorithm.
- Reject a Color Mixer algorithm identifier you do not recognize instead of
  substituting another algorithm.
- Feature equality compares every stored, authored parameter, including Tone
  Curve diagonal points and Color Mixer values exactly as Doubles. A
  conversion that loses any of them produces a document that is not equal to
  the saved one. To ask whether two values render the same, compare
  `ToneCurveFeature.RenderKey` or `ColorMixerFeature.RenderKey` instead.
- An `ImageEditorFeature` is authored for one image: its domain is the oriented
  image size (`SourceImage.pixelSize`). Store a reference to the source image
  with it, and resume it only over that image.

## Documents and History

An `EditingDocument` is the source image, the root feature, and the root
feature's undo history. `SourceImage` is not storable: store how your app
finds the image again (a file name, a Photos local identifier), and create a
new `SourceImage` when you restore. The history is optional. Its steps are
root features, so store them with the same conversion as the current one,
and restore them with `EditingDocument.History(undoStack:redoStack:limit:)`.

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import Foundation

/// The app's saved form of an ImageEditor document.
struct SavedEdit: Codable {
  struct Step: Codable {
    var exposure: Double?
    var cropRect: CGRect
    var quarterTurn: Int
    var straightenRadians: Double
  }

  var imageFileName: String
  var current: Step
  /// Committed steps before `current`, oldest first. Empty when the app does
  /// not keep history.
  var undo: [Step]

  init(document: ImageEditorDocument, imageFileName: String, keepsHistory: Bool) {
    // ImageEditor commits a tool visit when the next one starts, so the last
    // visit may be uncommitted. Commit a copy so it becomes a step too.
    var document = document
    document.commit()
    self.imageFileName = imageFileName
    self.current = Step(document.feature)
    self.undo = keepsHistory ? document.history.undoStack.map(Step.init) : []
  }

  func makeDocument(imageDirectory: URL) throws -> ImageEditorDocument {
    let source = try SourceImage(
      contentsOf: imageDirectory.appendingPathComponent(imageFileName)
    )
    return ImageEditorDocument(
      source: source,
      feature: try current.makeFeature(),
      history: .init(undoStack: try undo.map { try $0.makeFeature() }, redoStack: [])
    )
  }
}

extension SavedEdit.Step {
  init(_ feature: ImageEditorFeature) {
    exposure = feature.effects.exposure?.ev
    cropRect = feature.crop.rect
    quarterTurn = feature.crop.quarterTurn.rawValue
    straightenRadians = feature.crop.straightenRadians
  }

  func makeFeature() throws -> ImageEditorFeature {
    guard let turn = QuarterTurn(rawValue: quarterTurn) else {
      throw CocoaError(.coderReadCorrupt)
    }
    let crop = CropFeature(rect: cropRect, quarterTurn: turn, straightenRadians: straightenRadians)
    try crop.validate()
    return ImageEditorFeature(
      effects: .init(exposure: exposure.map { ExposureFeature(ev: $0) }),
      crop: crop
    )
  }
}
```

The example stores only the exposure and the crop to stay short; store every
member your app edits, as listed in [What to Store](#what-to-store). A
restored document has no uncommitted changes, and its first undo returns to
the last saved step. Resume a document only over the image its feature was
authored for.

## Migrating from `ParametricDocumentCodec`

Brightroom 5.0 and 5.1 shipped `ParametricDocumentCodec`, `PersistableFeature`,
`FeatureTypeKey`, and `Codable` conformances on the feature types. They have
been removed. If your app stored documents with the codec, read them with your
own decoder and convert them to features, or to your new storage model, once.

The codec wrote JSON with sorted keys. Its authoritative definition is
[`ParametricDocumentCodec.swift` at 5.1.0](https://github.com/FluidGroup/Brightroom/blob/5.1.0/Sources/BrightroomParametric/ParametricDocumentCodec.swift).

Brightroom 5.x after 5.1.0 (#330) changed the crop rectangle convention and
raised the crop schema to `3`; that codec writes `3` and rejects crop schemas
`1` and `2`. 5.1.0 writes `2` and reads `1` and `2`. A store can therefore
contain all three; see [Crop rectangles](#crop-rectangles).

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
| `brightroom.domain.crop` | 3 | `id`, `isEnabled`, `cropRect`, `rotation`, `straightenRadians`; `cropRect` is the selection before the quarter turn (Brightroom 6's convention) |
| | 2 | same keys; `cropRect` is the frame in the **output** orientation (5.0 and 5.1.0) |
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
  (for example `loadedState.currentEdit.document`, which
  `SwiftUIPhotosCropView` and `SwiftUICropView` authored) are y-down: top-left
  origin in the oriented image. `ImageEditorFeature.localBlur` and every
  Brightroom 6 mask are y-up, so flip each stamp to `y = height - y`, where
  `height` is the oriented image height (`SourceImage.pixelSize.height`),
  while converting, or the blur mask comes back mirrored vertically. A document from
  `Edit.makeEditingDocument(orientedImageSize:)` was already y-up. Crop
  rectangles were stored in the y-up form in both and need no flip, but see
  [Crop rectangles](#crop-rectangles) for schema 2.

### Crop rectangles

Brightroom 5.x after 5.1.0 (#330) rejects crop schemas `1` and `2` in its
codec and ships no migration adapter, so that an old quarter-turn crop cannot
silently select different pixels. Brightroom 6 has no codec; the conversion
below is an optional host-side recipe for apps that still hold such data and
want to reproduce what 5.1.0 rendered. Apps that do not need that can treat
schema `1` and `2` crops as unsupported and have users re-author them.

All three schemas are y-up and relative to the input image's origin.
`rotation` holds `0`, `-90`, `-180`, or `-270` (`.counterclockwise90` is
`-90`, `.counterclockwise270` is `-270`).

- **Schema 1**: `cropRect` only. Convert to `CropFeature(rect:)`.
- **Schema 2 (5.0 and 5.1.0)**: `cropRect` is the output frame. 5.1.0 turned
  the whole input by `-(rotation + straightenRadians)` about the rectangle's
  center and cut `cropRect` (w × h) out of it, so the output was w × h at
  every rotation.
- **Schema 3 (5.x after 5.1.0) and Brightroom 6**: `cropRect` is the selection
  before the quarter turn. Rendering straightens about the rectangle's
  center, cuts `cropRect`, and then turns the w × h canvas by an exact quarter
  turn, so a sideways turn outputs h × w. Convert with
  `CropFeature(rect:quarterTurn:straightenRadians:)` unchanged.

Turns about the same center commute, so a schema 2 crop equals the Brightroom 6
crop with the same center and angles and, for a sideways turn, the size
exchanged:

- `rotation` `0` or `-180`: keep `cropRect`.
- `rotation` `-90` or `-270`, with a stored `cropRect` of `(x, y, w, h)`: use
  `(x + (w − h) / 2, y + (h − w) / 2, h, w)`. The center stays at
  `(x + w/2, y + h/2)`, and the output is still w × h, as in 5.1.0.
- Example: on a 300 × 200 image, a schema 2 frame `(50, −50, 200, 300)` with
  `rotation` `-90` becomes `(0, 0, 300, 200)` with `.counterclockwise90`: the
  whole image, rendered 200 × 300.
- When `w − h` is odd, the converted origin lies on a half pixel. That
  reproduces 5.1.0's geometry, which resampled such crops by the same half
  pixel. ImageEditor keeps an untouched crop exactly, so reopening it and
  pressing Done leaves the half pixel in place. A host that wants integer
  edges must canonicalize while converting, with
  `CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)` (y-down
  input). Without straightening it snaps the edges inward, which drops the
  half-pixel row and column, so the output becomes (w − 1) × (h − 1) instead
  of 5.1.0's w × h. With straightening it keeps a fractional origin, and the
  crop is resampled anyway.
- The crop editor in 5.1.0 fitted a turned frame to the unturned image before
  storing it, so a whole 300 × 200 image turned by `-90` could be stored as
  the square `(50, 0, 200, 200)`. Converting keeps that square, which is what
  5.1.0 rendered; the rest of the image is not in the stored data.
- A disabled crop: leave it out. `ImageEditorFeature` requires a crop, so use
  one that covers the whole image instead.

```swift
import BrightroomParametric
import CoreGraphics

/// The `params` of a 5.x `brightroom.domain.crop` envelope.
struct Stored5xCrop: Decodable {
  var isEnabled: Bool
  var cropRect: CGRect  // [[x, y], [width, height]]
  var rotation: Int?  // absent in schema 1
  var straightenRadians: Double?
}

enum CropConversionError: Error {
  case unsupportedSchema(Int)
  case unknownRotation(Int)
}

/// Converts a stored 5.x crop; `nil` means the crop was disabled.
func makeCrop(schema: Int, stored: Stored5xCrop) throws -> CropFeature? {
  guard stored.isEnabled else { return nil }
  let rotation: QuarterTurn
  if let raw = stored.rotation {
    guard let turn = QuarterTurn(rawValue: raw) else { throw CropConversionError.unknownRotation(raw) }
    rotation = turn
  } else {
    rotation = .zero
  }
  let r = stored.cropRect
  let selection: CGRect
  switch schema {
  case 1, 3:
    selection = r
  case 2 where rotation.isSideways:
    // Schema 2 stored the output frame. Keep its center and exchange its size.
    selection = CGRect(x: r.midX - r.height / 2, y: r.midY - r.width / 2, width: r.height, height: r.width)
  case 2:
    selection = r
  default:
    throw CropConversionError.unsupportedSchema(schema)
  }
  let crop = CropFeature(
    rect: selection,
    quarterTurn: rotation,
    straightenRadians: stored.straightenRadians ?? 0
  )
  try crop.validate()
  return crop
}
```

[`StoredCropConversionExampleTests.swift`](../Tests/BrightroomParametricTests/StoredCropConversionExampleTests.swift)
runs this function and compares converted schema 2 crops with a reimplementation of
5.1.0's rendering.
