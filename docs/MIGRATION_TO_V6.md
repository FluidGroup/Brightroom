# Migrating to Brightroom 6

This guide is for applications using Brightroom 5.1 (or 5.0) and moving to
Brightroom 6.

Brightroom 6 is a major release with three themes:

1. **Your app owns storage.** The library no longer defines a file format for
   edits.
2. **Documents are static compositions.** An edit is a Swift value whose
   `body` lists its features, the way a SwiftUI view lists its content.
   Features have no ids and no `isEnabled` flags.
3. **The UI owns the edit.** `EditingStack` loads and renders an image; the
   document and its undo history belong to the editor
   (`PhotosCropEditingModel`) or to your app.

Samples marked `// Brightroom 5.x` show the old API and do not compile against
Brightroom 6. Every other sample in this guide compiles against Brightroom 6.

## Overview

The most common migration path is:

1. Update the package requirement to 6.0.0.
2. Replace `ParametricDocumentCodec` with your own `Codable` model.
3. Replace `EditingDocument` and `MainTree` with a document struct that
   conforms to `Feature`.
4. Remove every `id:`, `isEnabled:`, and `FeatureID`, and express enablement
   with optional members.
5. Keep the edit in `PhotosCropEditingModel` (or in your own state), and
   render the document that `SwiftUIPhotosCropView` passes to `onDone`.
6. Give `SwiftUICropView` a document binding, and replace `featureFocus(_:)`
   with `editingTarget(_:)`.
7. Move `CropModifier` from `EditingStack` to `PhotosCropEditingModel`.
8. Re-run image loading, crop, filter, adjustment, blur mask, undo, and final
   rendering flows.

## Package and Platform Changes

```swift
dependencies: [
  .package(url: "https://github.com/FluidGroup/Brightroom.git", from: "6.0.0")
]
```

The requirements do not change: iOS 17 (BrightroomUI and BrightroomEngine),
iOS 17 and macOS 14 (BrightroomParametric), Swift 6.3 or later in Swift 6
language mode. The products are the same.

## Persistence Moved to Your App

`ParametricDocumentCodec`, `ParametricDocumentCodecError`,
`PersistableFeature`, `FeatureTypeKey`, `ParametricFeatureTypeRegistry`,
`CodingUserInfoKey.parametricFeatureTypes`, the `featureTypeKey` and
`schemaVersion` properties, and every `Codable` conformance on feature,
mask, and parameter types (including `QuarterTurn`, `GaussianBlurRadius`,
`LocalAdjustmentBlendMode`, and `ParametricRGBAColor`) were removed. Your app converts documents to its own `Codable`
model and rebuilds them through the public initializers.

- [Saving parametric edits](parametric-persistence.md) describes the recipe,
  what to store for each feature, and the validating initializers.
- Its [5.x format section](parametric-persistence.md#migrating-from-parametricdocumentcodec)
  documents the JSON that `ParametricDocumentCodec` wrote, so you can read
  documents your app already saved and convert them once.

## Documents Are Static Compositions

A document is a type that conforms to `Feature` and declares a `body`. Members
of the body evaluate in order, and each receives the previous member's output.

- `Feature` is the base protocol. A *primitive* implements
  `apply(to:context:)`; a *composite* declares `body`.
- `ImageEffect` marks features that keep the extent and domain of their
  input. `LocalAdjustment` content and `PresetFeature` effects must be image
  effects, so a crop cannot appear inside them.
- `FeatureBuilder` builds bodies. It supports `if`/`else`, `switch`, `for`,
  optional members, and `if #available`.
- `LocalAdjustment<Content>` replaces `LocalAdjustmentFeature`, and its
  content is a builder instead of an `EffectPipeline`.
- `AnyImageEffect` erases an `Equatable` image effect for content decided by
  data, such as a preset catalog. `[AnyImageEffect]` is itself an image
  effect.
- `EmptyFeature` is a feature that does nothing.

Before:

```swift
// Brightroom 5.x
let document = EditingDocument(mainTree: MainTree(features: [
  .domain(CropFeature(cropRect: rect)),
  .effect(ExposureFeature(value: 0.5)),
  .localAdjustment(LocalAdjustmentFeature(
    maskTree: MaskTree(root: .brush(BrushMask(strokes: strokes))),
    effectPipeline: EffectPipeline(effects: [GaussianBlurFeature(value: 40)])
  )),
]))
let image = try ParametricImageRenderer().makeImage(from: source, document: document)
```

After:

```swift
import BrightroomParametric
import CoreImage

struct RetouchDocument: Feature, Equatable {
  var crop: CropFeature
  var exposure: ExposureFeature? = ExposureFeature(value: 0.5)
  var blur: LocalAdjustment<GaussianBlurFeature>?

  var body: some Feature {
    crop
    exposure
    blur
  }
}

func makeRetouchedImage(
  from source: CIImage,
  rect: CGRect,
  strokes: [BrushMaskStroke]
) throws -> CIImage {
  let document = RetouchDocument(
    crop: CropFeature(cropRect: rect),
    blur: LocalAdjustment(maskTree: MaskTree(root: .brush(BrushMask(strokes: strokes)))) {
      GaussianBlurFeature(value: 40)
    }
  )
  return try ParametricImageRenderer().makeImage(from: source, document: document)
}
```

The renderers take any `some Feature`: `ParametricImageRenderer().makeImage(from:document:)`,
`ParametricExportRenderer().render(source:document:)`, and the
`ParametricVideoRenderer()` methods. Like `EditingStack.makeRenderer(document:)`,
they throw `FeatureEvaluationError.documentUnavailable` for a `nil` optional
document instead of rendering the unedited image; pass `EmptyFeature()` for
that.

Control flow in a body replaces the flags and pipelines you assembled by hand:

```swift
import BrightroomParametric

struct Look: ImageEffect, Equatable {
  enum Tone: Equatable, Sendable {
    case warm
    case cool
    case neutral
  }

  var tone: Tone
  var isFaded: Bool
  var sharpenPasses: Int

  var body: some ImageEffect {
    switch tone {
    case .warm:
      TemperatureFeature(value: 800)
    case .cool:
      TemperatureFeature(value: -800)
    case .neutral:
      EmptyFeature()
    }
    if isFaded {
      FadeFeature(intensity: 0.2)
    }
    for _ in 0..<sharpenPasses {
      SharpenFeature(sharpness: 0.4, radius: 1)
    }
  }
}
```

Documents compare with `==`. Two documents built from the same values are
equal, however they were built, so an undo history or a cache can drop an
update that changes nothing.

## Removed Identity and Flags

Features no longer have an identity. Every `id` property, every `id:` and
`isEnabled:` initializer parameter, and `FeatureID` were removed. This covers
every built-in value: `BrightnessFeature`, `ContrastFeature`,
`SaturationFeature`, `ExposureFeature`, `HighlightsFeature`,
`ShadowsFeature`, `HighlightShadowTintFeature`, `TemperatureFeature`,
`SharpenFeature`, `GaussianBlurFeature`, `UnsharpMaskFeature`,
`VignetteFeature`, `FadeFeature`, `CropFeature`, `PresetFeature`,
`ColorCubeFeature`, `ToneCurveFeature`, `ColorMixerFeature`, `BrushMask`,
`MaskFeather`, and `MaskSubtract`. Their initializers take the same
parameters without `id:` and `isEnabled:`, for example
`ExposureFeature(value:)` and `CropFeature(cropRect:rotation:straightenRadians:)`.

| Removed | Replacement |
| --- | --- |
| `FeatureID`, `id` properties, `id:` parameters | None. Address features by your document's member names or your own keys. |
| `isEnabled` properties and `isEnabled:` parameters | An optional member, `if`, or leaving the feature out. See [Enablement](#enablement). |
| `Feature` as the base protocol with `id`, `isEnabled`, and `Equatable` | `Feature` is now the composition protocol (`body`, `apply(to:context:)`). Built-in features are `Equatable` themselves. |
| `EditingDocument`, `MainTree`, `MainFeature` | A struct (or enum) that conforms to `Feature` |
| `EffectPipeline`, `EffectPipelineFeature` | Effects listed in a body, or `[AnyImageEffect]` |
| `LocalAdjustmentFeature(maskTree:effectPipeline:blendMode:)` | `LocalAdjustment(maskTree:blendMode:content:)` |
| `ImageEffectFeatureType` | `ImageEffect` (and `Equatable`) |
| `DomainFeatureType` | `Feature` |
| `childFeatures` | `body` |
| `validate()` as a protocol requirement | Removed as a requirement. `CropFeature.validate()` and `ColorCubeFeature.validate()` stay public; `apply` calls them. |
| `PresetFeature.validate()` | Removed. Call `validate()` on each `ColorCubeFeature` you rebuild; rendering validates anyway. |
| `Feature.isEqualFeature(to:)`, `parametricFeatureIsEqual(_:_:)`, `parametricFeaturesAreEqual(_:_:)` | `==` on documents; `AnyImageEffect` compares the wrapped values |
| `FeatureGraphCompiler`, `FeatureGraphCompiler.Options`, `makeOutput(from:document:…)` | `ParametricImageRenderer().makeImage(from:document:)`. To skip origin normalization, call `document.apply(to:context:)` |
| `FeatureGraphCompiler.renderMask(_:extent:)`, `FeatureGraphOutput`, `localAdjustmentMasks` | `ParametricImageRenderer().makeMaskImage(for:extent:)` |
| `FeatureGraphCompilerError` | `FeatureEvaluationError`. See [Errors](#errors). |
| `ParametricImageRenderer(compiler:)`, `ParametricImageRenderer.compiler`, `ParametricImageRenderer.makeOutput` | `ParametricImageRenderer()` |
| `ParametricVideoRenderer(compiler:)`, `ParametricVideoRenderer(imageRenderer:)`, `ParametricVideoRenderer.imageRenderer` | `ParametricVideoRenderer()` |
| `ParametricExportRenderer(imageRenderer:)`, `ParametricExportRenderer.imageRenderer` | `ParametricExportRenderer()` |
| `ToneCurveFeature(id:value:)`, `ColorMixerFeature(id:adjustment:algorithm:)`, and their `id` and `isEnabled` | `ToneCurveFeature(value:)`, `ColorMixerFeature(adjustment:algorithm:)`. See [Tone Curve and Color Mixer](#tone-curve-and-color-mixer). |
| `BrushMask`, `MaskFeather`, `MaskSubtract` `id` and `isEnabled`; `BrushMask`'s conformance to `Feature` | `BrushMask(strokes:)`, `MaskFeather(input:radius:)`, `MaskSubtract(base:removing:)` |
| `PresetFeature(id:isEnabled:name:identifier:effects:)` with `[any ImageEffectFeatureType]` | `PresetFeature(name:identifier:effects:)` with `[AnyImageEffect]` |
| `ColorCubeFeature` loaders' `id:` parameter | The same loaders without `id:`. They take an optional `identifier:` instead, which defaults to the file name as before. |
| `GaussianBlurRadius.editingStackFilterValue(_:)` | `GaussianBlurRadius.proportional(_:)`; `GaussianBlurFeature(value:)` is unchanged |
| `ParametricKernelRegistry`, `ParametricKernelRegistryError`, `FeatureEvaluationContext.kernelRegistry`, and the `kernelRegistry:` parameter of `FeatureEvaluationContext.init` | None; the kernels are internal. `FeatureEvaluationContext(radiusReferenceExtent:presentationTime:)` |
| `FeatureTreeNode.isEnabled`; `FeatureTreeView(document:)`, `FeatureTreeOutline(document:)`, and `FeatureTreeDescriptor.nodes(for:)` taking `EditingDocument` | The same APIs taking `some Feature` |

### Enablement

A feature that is off is not part of the document:

- An optional member that is `nil` contributes nothing.
- A branch that is not taken (`if`, `switch`) contributes nothing.
- A mask node you do not want is left out of the tree: instead of a disabled
  `BrushMask`, use `BrushMask(strokes: [])`; instead of a disabled
  `MaskFeather`, use its `input`; instead of a disabled `MaskSubtract`, use
  its `base`.

Every mask node is rendered now, because no disabled node skips a subtree. A
union or intersection with no inputs throws wherever it is in the tree.

### Addressing Features

5.x code found features by id (`updateFeature(id:mutate:)`,
`EffectPipeline.first(of:)`, `localAdjustmentMasks[id]`). In Brightroom 6 a
feature is a member of your document, so you read and write it by name:

```swift
import BrightroomParametric

struct PortraitDocument: Feature, Equatable {
  var exposure: ExposureFeature?
  var crop: CropFeature

  var body: some Feature {
    exposure
    crop
  }
}

func brighten(_ document: inout PortraitDocument, by amount: Double) {
  let current = document.exposure?.value ?? 0
  document.exposure = ExposureFeature(value: current + amount)
}
```

The debug views (`FeatureTreeView(document:)`) identify nodes by their type
path in the body, such as `PresetFeature#0/TemperatureFeature#0`.

### Tone Curve and Color Mixer

`ToneCurveFeature` and `ColorMixerFeature` lost `id`, the `id:` initializer
parameter, and `isEnabled`. They still return their input image exactly when
their value is neutral. To ask whether a value renders as identity, use the
condition the bypass uses:

```swift
import BrightroomParametric

func isIdentity(_ curve: ToneCurveFeature) -> Bool {
  ToneCurveRenderIdentity(activeValue: curve.value) == nil
}

func isIdentity(_ mixer: ColorMixerFeature) -> Bool {
  mixer.adjustment.isNeutral
}
```

`ToneCurveEditorValue.isNeutral` is not the same condition: a curve with
interior points on the diagonal is not `isNeutral`, but it renders as
identity.

Equality of both features now compares their authored members: `value` for
a curve, `adjustment` and `algorithm` for a mixer. In 5.x it compared the
feature `id` and the rendered result, so two curves with the same id that
differed only in diagonal interior points or point ids were equal, and so were
mixers whose values rounded to the same Float32 parameters. They are no longer
equal, so an owner that drops equal updates keeps such an edit, for example
the first point a curve drag adds on the diagonal.

A curve rebuilt with fresh point ids is now a different value. If you build
curves on each access, for example a preset catalog in a computed property
that calls `insertPoint(input:output:)`, build them once or pass stable ids
through `insertPoint(id:input:output:)`.

Where you need "renders the same", such as a cache key, compare the render
identities explicitly:

```swift
import BrightroomParametric

func rendersTheSame(_ a: ToneCurveFeature, _ b: ToneCurveFeature) -> Bool {
  ToneCurveRenderIdentity(value: a.value) == ToneCurveRenderIdentity(value: b.value)
}

func rendersTheSame(_ a: ColorMixerFeature, _ b: ColorMixerFeature) -> Bool {
  ColorMixerRenderIdentity(activeAdjustment: a.adjustment, algorithm: a.algorithm)
    == ColorMixerRenderIdentity(activeAdjustment: b.adjustment, algorithm: b.algorithm)
}
```

### Errors

`FeatureGraphCompilerError` is replaced by `FeatureEvaluationError`, which
carries values instead of ids. It is the one error type that evaluation
throws, including failures of Brightroom's own kernels, and it conforms to
`LocalizedError`.

| 5.x case | Brightroom 6 |
| --- | --- |
| `duplicateID(FeatureID)` | Removed; there are no ids. |
| `emptyLocalAdjustmentEffectPipeline(FeatureID)` | Removed. A `LocalAdjustment` whose content applies nothing (`EmptyFeature`, `[]`, a `nil` member, a neutral tone curve) returns its input. Check `content` yourself if you relied on the error. |
| `emptyMaskComposite(FeatureID?)` | `emptyMaskComposite` |
| `invalidCropRect(FeatureID, CGRect)` | `invalidCropRect(CGRect)` |
| `invalidColorCubeData(FeatureID, expectedByteCount:actualByteCount:)` | `invalidColorCubeData(identifier:expectedByteCount:actualByteCount:)`, where `identifier` is the cube's `identifier` |
| `failedToCreateImage(String)` | `failedToCreateImage(String)` |
| `ParametricKernelRegistryError.failedToApplyKernel(String)` | `failedToCreateImage(String)` |
| `ParametricKernelRegistryError.missingKernel`, `failedToLoadKernel`, `missingKernelLibraryResource` | `kernelUnavailable(name:reason:)` |
| (new) | `documentUnavailable`: a renderer received a `nil` optional document |

A mask error is now thrown before the adjustment's content is evaluated (5.x
evaluated the effects first), so an invalid mask wins over an error from the
content.

### Mask Inspection

`FeatureGraphOutput.localAdjustmentMasks` returned masks keyed by id. Render
a mask tree directly instead, over the extent of the domain it is authored
in:

```swift
import BrightroomParametric
import CoreImage

func blurMaskImage(
  of adjustment: LocalAdjustment<GaussianBlurFeature>,
  over extent: CGRect
) throws -> CIImage {
  try ParametricImageRenderer().makeMaskImage(for: adjustment.maskTree, extent: extent)
}
```

### Custom Effects and Domain Features

Before:

```swift
// Brightroom 5.x
struct Posterize: ImageEffectFeatureType {
  var id: FeatureID = .init()
  var isEnabled: Bool = true
  var levels: Double

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
      .cropped(to: image.extent)
  }
}

struct Inset: DomainFeatureType {
  var id: FeatureID = .init()
  var isEnabled: Bool = true
  var amount: CGFloat

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let extent = image.extent.insetBy(dx: amount, dy: amount)
    return image
      .cropped(to: extent)
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
  }
}
```

After:

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

- An effect conforms to `ImageEffect` and `Equatable`. `AnyImageEffect` and
  `PresetFeature` accept only `Equatable` effects, so documents stay
  comparable.
- A domain feature conforms to `Feature`. Only the source is translated to
  zero origin, so return your output with a zero origin, as `CropFeature`
  does.
- An effect with nothing to do can return its input image itself; a
  `LocalAdjustment` then returns its input unchanged.

### Reorderable Steps

A list whose order the user decides, and which mixes domain features and
effects, becomes an enum of your own that conforms to `Feature`:

```swift
import BrightroomParametric

enum Step: Feature, Equatable {
  case crop(CropFeature)
  case effect(AnyImageEffect)
  case localAdjustment(LocalAdjustment<[AnyImageEffect]>)

  var body: some Feature {
    switch self {
    case .crop(let crop):
      crop
    case .effect(let effect):
      effect
    case .localAdjustment(let adjustment):
      adjustment
    }
  }
}

struct StepDocument: Feature, Equatable {
  var steps: [Step]

  var body: some Feature {
    steps
  }
}
```

### PresetFeature

`PresetFeature.effects` is `[AnyImageEffect]`, and the initializer has no
`id:` or `isEnabled:`. A nested preset is `AnyImageEffect(innerPreset)`.
Selection UIs compare `identifier`.

```swift
import BrightroomParametric

let film = PresetFeature(
  name: "Film",
  identifier: "film",
  effects: [
    AnyImageEffect(SaturationFeature(value: -0.2)),
    AnyImageEffect(FadeFeature(intensity: 0.1)),
  ]
)
```

### ColorCubeFeature Loaders

`ColorCubeFeature(contentsOfCubeFile:name:amount:)`,
`ColorCubeFeature(cubeImageAt:name:amount:dimension:)`, and
`ColorCubeFeature(cubeImage:name:identifier:amount:dimension:)` no longer take
`id:`. `PresetStorage.loadLUTs(fromBundle:)` builds presets whose `effects`
hold the cube as `AnyImageEffect`.

```swift
import BrightroomParametric
import Foundation

func loadLUT(at url: URL) throws -> ColorCubeFeature {
  try ColorCubeFeature(contentsOfCubeFile: url, amount: 0.8)
}
```

### Debug Feature Tree

`FeatureTreeView(document:)` and `FeatureTreeOutline(document:)` accept any
`some Feature` and show its body structure in evaluation order. `nil` members
are left out, composites and presets show their members as children, and
nodes have positional ids. `FeatureTreeNode` lost `isEnabled`.

```swift
import BrightroomParametric
import SwiftUI

struct DocumentInspector<Document: Feature>: View {
  var document: Document

  var body: some View {
    FeatureTreeView(document: document)
  }
}
```

## EditingStack Loads and Renders Only

`EditingStack` keeps its name. It loads and prepares an image (metadata,
orientation, thumbnail, downsampled editing source) and renders documents
over it. It no longer holds an edit or a history.

| Removed | Replacement |
| --- | --- |
| `EditingStack.Edit`, `Loaded.currentEdit`, `featureTree`, `EditingFeatureTree`, `FeatureTreePoint`, `updateFeature(id:mutate:)` | Your own document value, or the read-only `PhotosCropEditingModel.document`. See [Editing in Code](#editing-in-code). |
| `undo()`, `redo()`, `revertCurrentEdit()` | The document owner's history: `PhotosCropEditingModel.undo()`, `redo()`, `discardUncommittedChanges()` |
| `commitCurrentEditIfNeeded()`, `revert(to:)`, `removeAllHistory()`, `currentRevision`, `Revision` | None. PhotosCrop commits on Done and on tool changes; a new model starts a new history. |
| `Loaded.canUndo`, `canRedo`, `isDirty` | `PhotosCropEditingModel.canUndo`, `canRedo`, `isDirty` |
| `Loaded.hasUncommittedChanges` | None |
| `cropModifier` and `init(imageProvider:options:cropModifier:)` | `init(imageProvider:options:)`; pass the modifier to `PhotosCropEditingModel`. See [CropModifier](#cropmodifier-moved-to-brightroomui). |
| `makeRenderer()` | `makeRenderer(document:)` |
| The public setter of `loadedState` | None; `loadedState` is read-only |
| `EffectPipeline.applyIgnoringFailure(to:radiusReferenceExtent:)`, `EffectPipeline.hasEnabledEffects` | Render the effects with `ParametricImageRenderer` |
| `BrightRoomImageRenderer(source:orientation:)`, `BrightRoomImageRenderer.edit`, `BrightRoomImageRenderer.Edit` | `BrightRoomImageRenderer(source:orientation:document:)`, `BrightRoomImageRenderer.document` |
| `CropFeature(id:isEnabled:displayCropRect:imageSize:rotation:straighten:)` | `CropFeature(displayCropRect:imageSize:rotation:straighten:)` |

`makeRenderer(document:)` has an overload for an optional document, which
throws the new `EditingStackError.documentUnavailable` when the document is
`nil` (for example while an editor prepares it). To render the unedited
image, pass `EmptyFeature()`.

```swift
import BrightroomEngine
import BrightroomParametric
import UIKit

func renderOriginal(of stack: EditingStack) async throws -> UIImage {
  let rendered = try await stack.makeRenderer(document: EmptyFeature()).render()
  return try rendered.uiImage
}
```

A document passed to `makeRenderer(document:)` is authored in the oriented
source domain, whose size is `EditingStack.Loaded.imageSize`.

## PhotosCrop

### PhotosCropDocument

`PhotosCropDocument` (BrightroomUI) is the document PhotosCrop and
`SwiftUICropView` edit. It is a `Feature` and `Equatable`:

- `effects: PhotosCropDocument.Effects` — the filter preset and twelve
  adjustments, each an optional member, evaluated in declaration order;
- `blurMask: LocalAdjustment<GaussianBlurFeature>?` — the painted blur;
- `crop: CropFeature` — the final crop.

It is authored in the oriented, pre-crop source domain at full resolution
(`EditingStack.Loaded.imageSize`). Brush stamps are Core Image working-space
points (bottom-left origin, y-up). A 5.x `EditingStack.Edit.document` stored
them y-down, so flip them when you convert a saved 5.x edit (see
[Converting 5.x documents](parametric-persistence.md#converting-5x-documents)).
Create one with
`PhotosCropDocument(orientedImageSize:)`,
`PhotosCropDocument(effects:blurMask:crop:)`, or
`PhotosCropDocument.makeInitial(for:cropModifier:)`, and set the crop from a
`CropEditingState` with `setCrop(_:)`.

### PhotosCropEditingModel

`PhotosCropEditingModel` owns the document and its commit-style undo history.

- `init(editingStack:cropModifier:)` starts a new document; `cropModifier`
  defaults to `.identity`, so `PhotosCropEditingModel(editingStack:)` still
  compiles.
- `init(editingStack:resuming:)` resumes a document you saved.
- `document` is `nil` until the image loads and the initial document is ready.
- `canUndo`, `canRedo`, `isDirty`, `undo()`, `redo()`, and
  `discardUncommittedChanges()` replace the history API of `EditingStack`.
- `editingStack` is the stack the model was created with.

Keep the model (for example in `@State`) for as long as the editing session
lasts. You no longer need to keep the stack separately.

#### Editing in Code

`PhotosCropEditingModel.document` is read-only to your app; only the editor
changes it. In 5.x you could change the stack's edit with
`updateFeature(id:mutate:)` and `commitCurrentEditIfNeeded()`. In Brightroom
6:

- To open PhotosCrop on an edit built in code, build a `PhotosCropDocument`
  (with `PhotosCropDocument(orientedImageSize:)` or `makeInitial(for:cropModifier:)`,
  then set `effects`, `blurMask`, and `crop`) and create the model with
  `init(editingStack:resuming:)`. See [Reopening an Edit](#reopening-an-edit).
- To edit a document freely in code, own it yourself, for example as
  `@State var document: PhotosCropDocument?`, show it with `SwiftUICropView`
  through a binding, and keep your own history if you need one.

`commitCurrentEditIfNeeded()`, `hasUncommittedChanges`, `revert(to:)`,
`removeAllHistory()`, and `currentRevision` have no replacement: Done
commits, and a new model starts a new history.

### SwiftUIPhotosCropView

`onDone` now receives the edited `PhotosCropDocument`. Render it with the
model's stack:

Before:

```swift
// Brightroom 5.x
SwiftUIPhotosCropView(
  editingModel: editingModel,
  onDone: {
    Task {
      let rendered = try await editingStack.makeRenderer().render()
      // …
    }
  },
  onCancel: {}
)
```

After:

```swift
import BrightroomEngine
import BrightroomUI
import SwiftUI
import UIKit

struct Editor: View {
  @State var editingModel: PhotosCropEditingModel
  var onExport: @MainActor (Result<UIImage, Error>) -> Void

  var body: some View {
    SwiftUIPhotosCropView(
      editingModel: editingModel,
      onDone: { document in
        Task {
          do {
            let rendered = try await editingModel.editingStack
              .makeRenderer(document: document)
              .render()
            onExport(.success(try rendered.uiImage))
          } catch {
            onExport(.failure(error))
          }
        }
      },
      onCancel: {}
    )
  }
}
```

`SwiftUIPhotosCropView.Options.filterPresets` defaults to an empty list, and
`PhotosCropDefaultFilterPresets` was removed. Supply your own presets; the
former samples live in the demo app
([`PhotosCropDemoFilterPresets.swift`](../Dev/Sources/SwiftUIDemo/PhotosCropDemoFilterPresets.swift)).

### Reopening an Edit

In 5.x the `EditingStack` held the edit and its history, so keeping the stack
reopened the editor where the user left it. In Brightroom 6 there are two
ways to reopen:

- **Keep the session.** Keep the same `PhotosCropEditingModel` and pass it to
  a new `SwiftUIPhotosCropView`. The document and its undo history are kept.
- **Resume a document.** Store the document's values in your own format (see
  [Saving parametric edits](parametric-persistence.md)), rebuild the document,
  and create a model with `init(editingStack:resuming:)`. The undo history
  starts empty, and `isDirty` is measured against the resumed document.

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import UIKit

@MainActor
func resumeEdit(
  of image: UIImage,
  exposure: Double?,
  cropRect: CGRect,
  rotation: QuarterTurn,
  straightenRadians: Double
) -> PhotosCropEditingModel {
  let document = PhotosCropDocument(
    effects: .init(exposure: exposure.map { ExposureFeature(value: $0) }),
    crop: CropFeature(
      cropRect: cropRect,
      rotation: rotation,
      straightenRadians: straightenRadians
    )
  )
  return PhotosCropEditingModel(
    editingStack: EditingStack(imageProvider: .init(image: image)),
    resuming: document
  )
}
```

A rebuilt document equals the one you saved. The model does not check that
the document was authored for the loaded image; resume it only over the same
image.

## SwiftUICropView

`SwiftUICropView` edits a `PhotosCropDocument` through a binding instead of
the stack's edit:

- `init(editingStack:document:isGuideInteractionEnabled:areAnimationsEnabled:contentInset:stateHandler:)`
  and the variant with `cropInsideOverlay`/`cropOutsideOverlay` take
  `document: Binding<PhotosCropDocument?>`. When the binding is `nil` once the
  image has loaded, the view writes a full-image document into it.
- `editingTarget(_:)` with `CropViewEditingTarget` (`.crop`, `.blurMask`, or
  `nil` to only view) replaces `featureFocus(_:)` and `CropViewFeatureFocus`.
  The seed effect of `CropViewFeatureFocus.masking(_:id:)` is gone: the
  first stroke creates `blurMask` with the default blur. To use another blur,
  set `document.blurMask` yourself.
- Your app keeps the document's history, if it needs one.
- To start from a `CropModifier`, create the document with
  `PhotosCropDocument.makeInitial(for:cropModifier:)` and show the view once
  it exists.

Before:

```swift
// Brightroom 5.x
SwiftUICropView(editingStack: editingStack)
  .featureFocus(.masking())
```

After:

```swift
import BrightroomEngine
import BrightroomUI
import SwiftUI

struct BlurEditor: View {
  let editingStack: EditingStack
  @State private var document: PhotosCropDocument?
  @State private var target: CropViewEditingTarget? = .blurMask

  var body: some View {
    SwiftUICropView(editingStack: editingStack, document: $document)
      .editingTarget(target)
  }
}

func makeFramedDocument(for loadedState: EditingStack.Loaded) async -> PhotosCropDocument {
  await PhotosCropDocument.makeInitial(
    for: loadedState,
    cropModifier: .faceDetection(aspectRatio: .square)
  )
}
```

## CropModifier Moved to BrightroomUI

`EditingStack.CropModifier` is now `CropModifier` in BrightroomUI, and
`CropModifier.Closure` is now `CropModifier.Modify`. The closure is `async`,
works on a `CropEditingState`, and is `@Sendable`:
`@Sendable (CIImage, CropEditingState) async -> CropEditingState`. It runs off
the main actor, so the state it captures must be `Sendable`; move blocking work
to your own queue, as `faceDetection` does. `.identity` and
`.faceDetection(paddingBias:aspectRatio:)` are provided. Pass it to
`PhotosCropEditingModel(editingStack:cropModifier:)` or to
`PhotosCropDocument.makeInitial(for:cropModifier:)`. It runs only for a new
document, never for a resumed one.

Before:

```swift
// Brightroom 5.x
let stack = EditingStack(
  imageProvider: provider,
  cropModifier: .faceDetection(aspectRatio: .square)
)
let model = PhotosCropEditingModel(editingStack: stack)
```

After:

```swift
import BrightroomEngine
import BrightroomUI

@MainActor
func makeModel(provider: ImageProvider) -> PhotosCropEditingModel {
  PhotosCropEditingModel(
    editingStack: EditingStack(imageProvider: provider),
    cropModifier: .faceDetection(aspectRatio: .square)
  )
}

let squareCrop = CropModifier { _, crop in
  var crop = crop
  crop.updateCropExtent(toFitAspectRatio: .square)
  return crop
}
```

## CropEditingState

`CropEditingState.id` was removed, and `makeCropFeature()` is internal. Write
a crop state into a document with `PhotosCropDocument.setCrop(_:)`, which
snaps the rectangle the same way `CropView` does:

```swift
import BrightroomUI
import CoreGraphics

func squareDocument(orientedImageSize: CGSize) -> PhotosCropDocument {
  var document = PhotosCropDocument(orientedImageSize: orientedImageSize)
  var crop = CropEditingState(cropFeature: document.crop, imageSize: orientedImageSize)
  crop.updateCropExtent(toFitAspectRatio: .square)
  document.setCrop(crop)
  return document
}
```

## Migration Checklist

- [ ] The package requirement is `from: "6.0.0"`.
- [ ] Saved edits use your own `Codable` model; documents written by
      `ParametricDocumentCodec` are converted once
      ([5.x conversion list](parametric-persistence.md#converting-5x-documents)).
- [ ] `EditingDocument`, `MainTree`, `EffectPipeline`, and
      `LocalAdjustmentFeature` are replaced by document types that conform to
      `Feature`.
- [ ] No `FeatureID`, `id:`, or `isEnabled:` remains; enablement is optional
      members, `if`, or nodes left out of mask trees.
- [ ] Custom effects conform to `ImageEffect` and `Equatable`; custom domain
      features conform to `Feature` and return a zero-origin image.
- [ ] Code that caught `FeatureGraphCompilerError` catches
      `FeatureEvaluationError`, and code that relied on
      `emptyLocalAdjustmentEffectPipeline` checks the content itself.
- [ ] Presets pass `[AnyImageEffect]`; color-cube loaders drop `id:`.
- [ ] The edit and its history live in `PhotosCropEditingModel` or your own
      state; `EditingStack` is only asked for `loadedState` and
      `makeRenderer(document:)`.
- [ ] `SwiftUIPhotosCropView`'s `onDone` renders the document it receives.
- [ ] `SwiftUICropView` has a document binding and uses `editingTarget(_:)`.
- [ ] `CropModifier` is passed to `PhotosCropEditingModel` or
      `PhotosCropDocument.makeInitial(for:cropModifier:)`.
- [ ] Filter presets are supplied through `options.filterPresets`.
- [ ] Loading, crop, filters, adjustments, blur mask, undo, reopening, and
      final rendering are tested again.
