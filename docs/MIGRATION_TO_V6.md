# Migrating to Brightroom 6

This guide is for applications using Brightroom 5.1 (or 5.0) and moving to
Brightroom 6. Names in the left-hand columns of the tables are the 5.1.1
names.

Brightroom 6 is a major release with four themes:

1. **Your app owns storage.** The library no longer defines a file format for
   edits.
2. **Edits are static compositions.** An edit is a Swift value, a *root
   feature*, whose `body` lists its features, the way a SwiftUI view lists
   its content. Features have no `FeatureID` identity and no `isEnabled`
   flags.
3. **Your app owns the document.** An `EditingDocument` (BrightroomEngine) is
   a value that holds the source image, the root feature, and its undo
   history. `ImageEditor` and `ImageEditorCanvas` edit it through a binding.
   `ImageProvider`, `PhotosCropEditingModel`, and the public `EditingStack`
   are gone.
4. **One word per concept.** Types were renamed to the vocabulary in
   [Vision of Editing](vision-of-editing.md#vocabulary):
   `SwiftUIPhotosCropView` is `ImageEditor`, `SwiftUICropView` is
   `ImageEditorCanvas`, the `Parametric` prefix is gone, and so on. See
   [Name Changes at a Glance](#name-changes-at-a-glance).

The name `EditingDocument` changed meaning. In 5.x it was the parametric edit
itself, with a `MainTree`; that role is now your root feature. In Brightroom
6 it is BrightroomEngine's value that pairs a root feature with its image and
history.

Samples marked `// Brightroom 5.x` show the old API and do not compile against
Brightroom 6. Every other sample in this guide compiles against Brightroom 6.

## Overview

The most common migration path is:

1. Update the package requirement to 6.0.0.
2. Replace `ParametricDocumentCodec` with your own `Codable` model.
3. Replace the 5.x `EditingDocument` and `MainTree` with a root feature: a
   struct that conforms to `Feature`.
4. Remove every `id:`, `isEnabled:`, and `FeatureID`, and express enablement
   with optional members.
5. Replace `ImageProvider` with `SourceImage`, and `EditingStack` plus
   `PhotosCropEditingModel` with an `ImageEditorDocument` that your app keeps
   in its state.
6. Replace `SwiftUIPhotosCropView(editingModel:)` with
   `ImageEditor(document:)`, and render the document with
   `render(options:)` when the editor is done.
7. Replace `SwiftUICropView` with `ImageEditorCanvas(document:)`, and
   `featureFocus(_:)` with `editingTarget(_:)`.
8. Pass a `CropModifier` to `await ImageEditorDocument(source:cropModifier:)`
   instead of to `EditingStack`.
9. Apply the renames in [Name Changes at a Glance](#name-changes-at-a-glance).
10. Author crop rectangles as the selection before the quarter turn, and
    convert rectangles saved by 5.1.0
    ([Crop Rectangles and Output Rotation](#crop-rectangles-and-output-rotation)).
11. Re-run image loading, crop, filter, adjustment, blur mask, undo, and final
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

### Removed Unused API

These public symbols had no use inside Brightroom and were removed without a
replacement:

| Module | Removed |
| --- | --- |
| BrightroomUI | `TODOL10n`, `NonL10n`, `String(raw:)`, `String(raw:_:)`, `BrightroomUIBundle`, and the `Media.xcassets` icons |
| BrightroomEngine | `PlatformImage`, `ParameterRange`, `CoreImageInspector`, `EngineSanitizer`, `EngineRuntimeError`, `RequireError` |
| BrightroomEngine | `ImageTool.loadOriginalCGImage(from:fixesOrientation:)`, `ImageTool.writeImageToTmpDirectory(image:)`, `ImageTool.makeImageForPNGOptimizedSharing(image:)` |
| BrightroomEngine | The ignored `fixesOrientation:` parameter of `ImageTool.makeResizedCGImage(from:maxPixelSizeHint:)` and `ImageTool.makeResizedCGImage(from:maxPixelSize:)` taking a `CGImageSource` |
| BrightroomEngine | `PixelAspectRatio.width(forHeight:)`, `size(byHeight:)`, `asCGSize()`, `sizeThatFill(in:)`, `rectThatFill(in:)`, `localizedText` |
| BrightroomParametric | `CropFeature.aggregatedRotationRadians`, `LocalAdjustmentBlendMode`, `LocalAdjustmentFeature.blendMode`, and the `blendMode:` parameter |

## Name Changes at a Glance

Top-level public types, 5.1.1 to 6.0. Member-level renames are in the linked
sections.

### BrightroomUI

| 5.1.1 | 6.0 | See |
| --- | --- | --- |
| `SwiftUIPhotosCropView` | `ImageEditor` | [ImageEditor](#imageeditor) |
| `SwiftUIPhotosCropView.Options`, `.LocalizedStrings` | `ImageEditor.Options`, `ImageEditor.LocalizedStrings` | [ImageEditor](#imageeditor) |
| `PhotosCropEditingModel` | Removed. Keep an `ImageEditorDocument` in your state. | [ImageEditor](#imageeditor) |
| (none) | `ImageEditorFeature`, the editor's root feature, and `ImageEditorDocument` (`EditingDocument<ImageEditorFeature>`) | [ImageEditorFeature](#imageeditorfeature) |
| `PhotosCropDefaultFilterPresets` | Removed. Supply `ImageEditor.Options.filters`. | [ImageEditor](#imageeditor) |
| `SwiftUICropView` | `ImageEditorCanvas` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `SwiftUICropView.AdjustmentKind` | `CropInteraction` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `CropViewFeatureFocus` | `ImageEditorCanvas.Target`, set with `editingTarget(_:)` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `CropViewMaskingBrush` | `ImageEditorCanvas.Brush` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `EditingCanvasStrokeSmoothingConfiguration`, `EditingCanvasStrokeSmoothingAlgorithm` | `ImageEditorCanvas.Brush.Smoothing` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `CropRotation` | `QuarterTurn` | [QuarterTurn Case Names](#quarterturn-case-names) |
| `EditingStack.CropModifier` (BrightroomEngine) | `CropModifier` (BrightroomUI) | [CropModifier](#cropmodifier-moved-to-brightroomui) |

### BrightroomEngine

| 5.1.1 | 6.0 | See |
| --- | --- | --- |
| `ImageProvider`, `ImageSource`, `ImageProviderError` | `SourceImage`, `SourceImageError` | [SourceImage](#sourceimage-replaces-imageprovider) |
| `EditingStack` (with `Edit`, `Loaded`, `Options`, `Revision`), `EditingStackError` | Package access only. Its edit and history are `EditingDocument`; its loading is `SourceImage`. | [EditingStack](#editingstack-is-no-longer-public) |
| `BrightRoomImageRenderer`, `ImageRenderer` | `EditingDocument.render(options:)` | [EditingStack](#editingstack-is-no-longer-public) |
| `EditingFeatureTree`, `FeatureTreePoint` | Removed. Address features by member name. | [Addressing Features](#addressing-features) |
| `PixelAspectRatio` | `AspectRatio` (BrightroomParametric) | [Aspect Ratio](#aspect-ratio) |
| `CropGeometry` | `CropGeometry` (BrightroomParametric) | [Crop Conversions](#crop-conversions) |
| `ImageTool` | Internal | [Image Decoding](#image-decoding) |

### BrightroomParametric

| 5.1.1 | 6.0 | See |
| --- | --- | --- |
| `EditingDocument`, `MainTree`, `MainFeature` | Your root feature, a type that conforms to `Feature` | [Edits Are Static Compositions](#edits-are-static-compositions) |
| `ImageEffectFeatureType`, `DomainFeatureType` | `ImageEffect`, `Feature` | [Removed Identity and Flags](#removed-identity-and-flags) |
| `EffectPipeline`, `EffectPipelineFeature` | Effects in a body, or `[AnyImageEffect]` | [Removed Identity and Flags](#removed-identity-and-flags) |
| `FeatureGraphCompiler`, `FeatureGraphOutput`, `FeatureGraphCompilerError` | `FeatureRenderer`, `FeatureEvaluationError` | [Removed Identity and Flags](#removed-identity-and-flags) |
| `ParametricImageRenderer`, `ParametricExportRenderer`, `ParametricVideoRenderer` | `FeatureRenderer`, `ExportRenderer`, `VideoRenderer` | [Renderers](#renderers) |
| `ParametricExportRenderer.Rendered` | `RenderedImage` | [Renderers](#renderers) |
| `LocalAdjustmentFeature(maskTree:effectPipeline:blendMode:)` | `LocalAdjustmentFeature(mask:content:)` | [Masks and Local Adjustments](#masks-and-local-adjustments) |
| `MaskTree`, `MaskNode`, `MaskFeather`, `MaskSubtract` | `Mask` | [Masks and Local Adjustments](#masks-and-local-adjustments) |
| `BrushMaskStroke`, `BrushMaskBrush` | `BrushMask.Stroke`, `BrushMask.Brush` | [Masks and Local Adjustments](#masks-and-local-adjustments) |
| `TemperatureFeature` | `WhiteBalanceFeature` | [Feature Members](#feature-members) |
| `GaussianBlurRadius` | `GaussianBlurFeature.Radius` | [Feature Members](#feature-members) |
| `ParametricRGBAColor` | `HighlightShadowTintFeature.Color` | [Feature Members](#feature-members) |
| `PresetFeature` | `FilterFeature` | [Filters and Color Cubes](#filters-and-color-cubes) |
| `ColorCubeFeatureLoadingError` | `ColorCubeLoadingError` | [Filters and Color Cubes](#filters-and-color-cubes) |
| `ToneCurveEditorValue`, `ToneCurveChannel` | `ToneCurveFeature.Curves`, `ToneCurveFeature.Channel` | [Tone Curve and Color Mixer Values](#tone-curve-and-color-mixer-values) |
| `ColorMixerAdjustment`, `ColorMixerBandAdjustment`, `ColorMixerBand` | `ColorMixerFeature.Bands`, `.BandCorrection`, `.Band` | [Tone Curve and Color Mixer Values](#tone-curve-and-color-mixer-values) |
| `ToneCurveRenderIdentity`, `ColorMixerRenderIdentity` | `ToneCurveFeature.RenderKey`, `ColorMixerFeature.RenderKey` | [Tone Curve and Color Mixer Values](#tone-curve-and-color-mixer-values) |
| `BrushStampMetalLibrary` | `BrightroomMetalLibrary` | [Metal Library](#metal-library) |
| `ParametricDocumentCodec`, `PersistableFeature`, `FeatureTypeKey`, `ParametricFeatureTypeRegistry` | Removed; your app owns storage | [Persistence Moved to Your App](#persistence-moved-to-your-app) |
| `FeatureID`, `ParametricKernelRegistry` | Removed | [Removed Identity and Flags](#removed-identity-and-flags) |

Top-level library types that conform to `Feature` keep the `Feature` suffix
(`ExposureFeature`, `ImageEditorFeature`), a part nested inside one may omit
it (`ImageEditorFeature.Effects`), and values that are not features have
none (`Mask`, `QuarterTurn`, `AspectRatio`). Some of these names are common
words. If your app declares its own `ImageEditor`, `AspectRatio`, or `Mask`,
your type wins inside your module; qualify Brightroom's with its module name,
such as `BrightroomUI.ImageEditor` or `BrightroomParametric.Mask`.

## Persistence Moved to Your App

`ParametricDocumentCodec`, `ParametricDocumentCodecError`,
`PersistableFeature`, `FeatureTypeKey`, `ParametricFeatureTypeRegistry`,
`CodingUserInfoKey.parametricFeatureTypes`, the `featureTypeKey` and
`schemaVersion` properties, and every `Codable` conformance on feature,
mask, and parameter types (including `QuarterTurn`, `GaussianBlurRadius`,
and `ParametricRGBAColor`) were removed. Your app converts edits to its own
`Codable` model and rebuilds them through the public initializers.
`LocalAdjustmentBlendMode` was removed with its only case, `alpha`, which is
how every local adjustment composites; ignore a stored `blendMode`.

- [Saving parametric edits](parametric-persistence.md) describes the recipe,
  what to store for each feature, and the validating initializers.
- Its [5.x format section](parametric-persistence.md#migrating-from-parametricdocumentcodec)
  documents the JSON that `ParametricDocumentCodec` wrote, so you can read
  documents your app already saved and convert them once.

## Edits Are Static Compositions

An edit is a root feature: a type that conforms to `Feature` and declares a
`body`. Members of the body evaluate in order, and each receives the previous
member's output. It replaces the 5.x `EditingDocument` and its `MainTree`.

- `Feature` is the base protocol. A *primitive* implements
  `apply(to:context:)`; a *composite* declares `body`.
- `ImageEffect` marks features that keep the extent and domain of their
  input. `LocalAdjustmentFeature` content and `FilterFeature` effects must be
  image effects, so a crop cannot appear inside them.
- `FeatureBuilder` builds bodies. It supports `if`/`else`, `switch`, `for`,
  optional members, and `if #available`.
- `LocalAdjustmentFeature<Content>` is generic over its content, and its
  content is a builder instead of an `EffectPipeline`.
- `AnyImageEffect` erases an `Equatable` image effect for content decided by
  data, such as a filter catalog. `[AnyImageEffect]` is itself an image
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

struct RetouchFeature: Feature, Equatable {
  var crop: CropFeature
  var exposure: ExposureFeature? = ExposureFeature(ev: 0.5)
  var blur: LocalAdjustmentFeature<GaussianBlurFeature>?

  var body: some Feature {
    crop
    exposure
    blur
  }
}

func makeRetouchedImage(
  from source: CIImage,
  rect: CGRect,
  strokes: [BrushMask.Stroke]
) throws -> CIImage {
  let feature = RetouchFeature(
    crop: CropFeature(rect: rect),
    blur: LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: strokes))) {
      GaussianBlurFeature(radius: .proportional(40))
    }
  )
  return try FeatureRenderer().makeImage(from: source, feature: feature)
}
```

The renderers take any `some Feature`: `FeatureRenderer().makeImage(from:feature:)`,
`ExportRenderer().render(from:feature:)`, and the
`VideoRenderer()` methods. The 5.x `document:` label is `feature:`. A `nil`
optional feature leaves the image unchanged, so it renders the unedited
image; `EmptyFeature()` says the same explicitly.

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
      WhiteBalanceFeature(temperature: 800)
    case .cool:
      WhiteBalanceFeature(temperature: -800)
    case .neutral:
      EmptyFeature()
    }
    if isFaded {
      FadeFeature(intensity: 0.2)
    }
    for _ in 0..<sharpenPasses {
      SharpenFeature(intensity: 0.4, radius: 1)
    }
  }
}
```

Features compare with `==`. Two root features built from the same values are
equal, however they were built, so an undo history or a cache can drop an
update that changes nothing.

## Removed Identity and Flags

Features no longer have an identity. `FeatureID`, every `FeatureID`-typed
`id` property and `id:` parameter, and every `isEnabled` property and
`isEnabled:` parameter were removed. This covers every built-in value:
`BrightnessFeature`, `ContrastFeature`, `SaturationFeature`,
`ExposureFeature`, `HighlightsFeature`, `ShadowsFeature`,
`HighlightShadowTintFeature`, `TemperatureFeature`, `SharpenFeature`,
`GaussianBlurFeature`, `UnsharpMaskFeature`, `VignetteFeature`,
`FadeFeature`, `CropFeature`, `PresetFeature`, `ColorCubeFeature`,
`ToneCurveFeature`, `ColorMixerFeature`, `BrushMask`, `MaskFeather`, and
`MaskSubtract` (the last two are now `Mask` cases). `FilterFeature` (5.x
`PresetFeature`) and `ColorCubeFeature` keep a string `id`, 5.x's
`identifier`: it is a lookup key for a filter or a LUT, not feature
identity, and features never compare by it.
Their initializers take the same parameters without `id:` and `isEnabled:`,
for example
`ExposureFeature(ev:)` and `CropFeature(rect:quarterTurn:straightenRadians:)`
(both renamed in 6.0; see [Renamed Parametric API](#renamed-parametric-api)).

| Removed | Replacement |
| --- | --- |
| `FeatureID`, `FeatureID`-typed `id` properties and `id:` parameters | None. Address features by your root feature's member names or your own keys. (`FilterFeature.id` and `ColorCubeFeature.id` are 5.x's string `identifier`, renamed.) |
| `isEnabled` properties and `isEnabled:` parameters | An optional member, `if`, or leaving the feature out. See [Enablement](#enablement). |
| `Feature` as the base protocol with `id`, `isEnabled`, and `Equatable` | `Feature` is now the composition protocol (`body`, `apply(to:context:)`). Built-in features are `Equatable` themselves. |
| `EditingDocument` (BrightroomParametric), `MainTree`, `MainFeature` | A struct (or enum) that conforms to `Feature`. `EditingDocument` now names BrightroomEngine's document. |
| `EffectPipeline`, `EffectPipelineFeature` | Effects listed in a body, or `[AnyImageEffect]` |
| `LocalAdjustmentFeature(maskTree:effectPipeline:blendMode:)` | `LocalAdjustmentFeature(mask:content:)` |
| `ImageEffectFeatureType` | `ImageEffect` (and `Equatable`) |
| `DomainFeatureType` | `Feature` |
| `childFeatures` | `body` |
| `validate()` as a protocol requirement | Removed as a requirement. `CropFeature.validate()` and `ColorCubeFeature.validate()` stay public; `apply` calls them. |
| `PresetFeature.validate()` | Removed. Call `validate()` on each `ColorCubeFeature` you rebuild; rendering validates anyway. |
| `Feature.isEqualFeature(to:)`, `parametricFeatureIsEqual(_:_:)`, `parametricFeaturesAreEqual(_:_:)` | `==` on features; `AnyImageEffect` compares the wrapped values |
| `FeatureGraphCompiler`, `FeatureGraphCompiler.Options`, `makeOutput(from:document:…)` | `FeatureRenderer().makeImage(from:feature:)`. To skip origin normalization, call `feature.apply(to:context:)` |
| `FeatureGraphCompiler.renderMask(_:extent:)`, `FeatureGraphOutput`, `localAdjustmentMasks` | `FeatureRenderer().makeMaskImage(for:extent:)` |
| `FeatureGraphCompilerError` | `FeatureEvaluationError`. See [Errors](#errors). |
| `ParametricImageRenderer(compiler:)`, `ParametricImageRenderer.compiler`, `ParametricImageRenderer.makeOutput` | `FeatureRenderer()` |
| `ParametricVideoRenderer(compiler:)`, `ParametricVideoRenderer(imageRenderer:)`, `ParametricVideoRenderer.imageRenderer` | `VideoRenderer()` |
| `ParametricExportRenderer(imageRenderer:)`, `ParametricExportRenderer.imageRenderer` | `ExportRenderer()` |
| `ToneCurveFeature(id:value:)`, `ColorMixerFeature(id:adjustment:algorithm:)`, and their `id` and `isEnabled` | `ToneCurveFeature(curves:)`, `ColorMixerFeature(bands:algorithm:)`. See [Tone Curve and Color Mixer](#tone-curve-and-color-mixer). |
| `ToneCurve.Point.ID`, `ToneCurve.Point.id`, `ToneCurve.Point.isEndpoint`, and the point editing methods taking `id:` | Points are plain coordinates addressed by index. See [Tone Curve points](#tone-curve-points). |
| `BrushMask`, `MaskFeather`, `MaskSubtract` `id` and `isEnabled`; `BrushMask`'s conformance to `Feature` | `BrushMask(strokes:)`, `Mask.feathered(_:radius:)`, `Mask.subtraction(_:removing:)` |
| `PresetFeature(id:isEnabled:name:identifier:effects:)` with `[any ImageEffectFeatureType]` | `FilterFeature(name:id:effects:)` with `[AnyImageEffect]` |
| `ColorCubeFeature` loaders' `id:` parameter taking a `FeatureID` | The same loaders taking `id: String`: optional in the two file loaders, where it defaults to the file name as before, and required in `init(cubeImage:name:id:intensity:dimension:)`. |
| `GaussianBlurRadius.editingStackFilterValue(_:)` | `GaussianBlurFeature.Radius.proportional(_:)`, as in `GaussianBlurFeature(radius: .proportional(40))` |
| `ParametricKernelRegistry`, `ParametricKernelRegistryError`, `FeatureEvaluationContext.kernelRegistry`, and the `kernelRegistry:` parameter of `FeatureEvaluationContext.init` | None; the kernels are internal. `FeatureEvaluationContext(chainEntryExtent:presentationTime:)` |
| `FeatureTreeNode.isEnabled`; `FeatureTreeView(document:)`, `FeatureTreeOutline(document:)`, and `FeatureTreeDescriptor.nodes(for:)` taking `EditingDocument` | `FeatureTreeView(feature:)`, `FeatureTreeOutline(feature:)`, and `FeatureTreeDescriptor.nodes(for:)` taking `some Feature` |

### Enablement

A feature that is off is not part of the document:

- An optional member that is `nil` contributes nothing.
- A branch that is not taken (`if`, `switch`) contributes nothing.
- A mask node you do not want is left out of the mask: instead of a disabled
  `BrushMask`, use `BrushMask(strokes: [])`; instead of a disabled
  `MaskFeather`, use its input mask; instead of a disabled `MaskSubtract`, use
  its base mask.

Every mask node is rendered now, because no disabled node skips a subtree. A
union or intersection with no inputs throws wherever it is in the tree.

### Addressing Features

5.x code found features by id (`updateFeature(id:mutate:)`,
`EffectPipeline.first(of:)`, `localAdjustmentMasks[id]`) or through
`EditingFeatureTree`. In Brightroom 6 a feature is a member of your root
feature, so you read and write it by name:

```swift
import BrightroomParametric

struct PortraitFeature: Feature, Equatable {
  var exposure: ExposureFeature?
  var crop: CropFeature

  var body: some Feature {
    exposure
    crop
  }
}

func brighten(_ portrait: inout PortraitFeature, by amount: Double) {
  let current = portrait.exposure?.ev ?? 0
  portrait.exposure = ExposureFeature(ev: current + amount)
}
```

The debug views (`FeatureTreeView(feature:)`) identify nodes by their type
path in the body, such as `FilterFeature#0/WhiteBalanceFeature#0`.

### Tone Curve and Color Mixer

`ToneCurveFeature` and `ColorMixerFeature` lost `id`, the `id:` initializer
parameter, and `isEnabled`. They still return their input image exactly when
their value is neutral. To ask whether a value renders as identity, use the
condition the bypass uses:

```swift
import BrightroomParametric

func isIdentity(_ curve: ToneCurveFeature) -> Bool {
  ToneCurveFeature.RenderKey(activeCurves: curve.curves) == nil
}

func isIdentity(_ mixer: ColorMixerFeature) -> Bool {
  mixer.bands.isIdentity
}
```

`ToneCurveFeature.Curves.isDefault` (5.x `ToneCurveEditorValue.isNeutral`) is
not the same condition: a curve with interior points on the diagonal is not
the default, but it renders as identity.

Equality of both features now compares their authored members: `curves` for
a curve, `bands` and `algorithm` for a mixer. In 5.x it compared the
feature `id` and the rendered result, so two curves with the same id that
differed only in diagonal interior points were equal, and so were mixers whose
values rounded to the same Float32 parameters. They are no longer equal, so an
owner that drops equal updates keeps such an edit, for example the first point
a curve drag adds on the diagonal. Curve points no longer have ids, so two 5.x
curves that differed only in point ids convert to the same value.

Where you need "renders the same", such as a cache key, compare the render
identities explicitly:

```swift
import BrightroomParametric

func rendersTheSame(_ a: ToneCurveFeature, _ b: ToneCurveFeature) -> Bool {
  ToneCurveFeature.RenderKey(curves: a.curves) == ToneCurveFeature.RenderKey(curves: b.curves)
}

func rendersTheSame(_ a: ColorMixerFeature, _ b: ColorMixerFeature) -> Bool {
  ColorMixerFeature.RenderKey(activeBands: a.bands, algorithm: a.algorithm)
    == ColorMixerFeature.RenderKey(activeBands: b.bands, algorithm: b.algorithm)
}
```

### Tone Curve points

A `ToneCurve` is plain data: its points are coordinate pairs with no identity.
`ToneCurve.Point.ID` (`.blackEndpoint`, `.whiteEndpoint`, `.interior(UUID)`),
`Point.id`, the `Identifiable` conformance, and `Point.isEndpoint` were
removed. The endpoints are the first and last points, and the editing methods
take the point's index in `points`.

| Brightroom 5.1 | Brightroom 6 |
| --- | --- |
| `insertPoint(input:output:) -> Point.ID?` | `insertPoint(input:output:) -> Int?`, the index of the new point |
| `insertPointInLargestGap() -> Point.ID?` | `insertPointInLargestGap() -> Int?` |
| `insertPoint(id:input:output:)` | `insertPoint(input:output:)` on each curve. Points in different channels are not linked. |
| `point(id:)` | `points[index]` |
| `movePoint(id:input:output:)` | `movePoint(at:input:output:)` |
| `offsetPoint(id:inputDelta:outputDelta:)` | `offsetPoint(at:inputDelta:outputDelta:)` |
| `removePoint(id:)` | `removePoint(at:)`. It returns `false` for the first and last point, as before for the endpoints. |
| `.blackEndpoint`, `.whiteEndpoint` | Index `0` and `points.count - 1` |
| `point.isEndpoint` | `index == 0 \|\| index == curve.points.count - 1` |

```swift
import BrightroomParametric

var curve = ToneCurve()
if let index = curve.insertPoint(input: 0.25, output: 0.2) {
  // A move never passes a neighbor, so `index` addresses the same point
  // for the whole drag.
  curve.movePoint(at: index, input: 0.3, output: 0.22)
}
// Lift the black endpoint.
curve.movePoint(at: 0, input: 0, output: 0.05)
```

Only a move keeps every index valid. Insertion and removal shift the
indices after them, so update a stored selection with the index
`insertPoint` returns, or after `removePoint(at:)`. Resetting a curve or a
channel, and replacing the curve (undo, redo, or opening another document),
replace the points altogether, so clear or re-derive the selection then too.
An index that is still inside `points` after such a change addresses
whichever point now sits there, possibly an endpoint, without any error. An
index outside `points` is a programming error and traps, like an array
subscript; 5.1 ignored an unknown id.

Two curves with the same coordinates are now equal however they were built,
so a preset catalog that builds its curves on each access produces equal
values. If your editor needs to tell points apart by more than their position,
for example to keep one point linked across channels, keep that in the
editor's own state, or compose your own `Feature` that carries it next to the
curve.

When you convert curves saved by 5.x, keep the points in their stored order
and drop their ids. See the
[5.x conversion notes](parametric-persistence.md#converting-5x-documents).

### Errors

`FeatureGraphCompilerError` is replaced by `FeatureEvaluationError`, which
carries values instead of ids. It is the one error type that evaluation
throws, including failures of Brightroom's own kernels, and it conforms to
`LocalizedError`.

| 5.x case | Brightroom 6 |
| --- | --- |
| `duplicateID(FeatureID)` | Removed; there are no ids. |
| `emptyLocalAdjustmentEffectPipeline(FeatureID)` | Removed. A `LocalAdjustmentFeature` whose content applies nothing (`EmptyFeature`, `[]`, a `nil` member, a neutral tone curve) returns its input. Check `content` yourself if you relied on the error. |
| `emptyMaskComposite(FeatureID?)` | `emptyMaskComposite` |
| `invalidCropRect(FeatureID, CGRect)` | `invalidCropRect(CGRect)` |
| `invalidColorCubeData(FeatureID, expectedByteCount:actualByteCount:)` | `invalidColorCubeData(id:expectedByteCount:actualByteCount:)`, where `id` is the cube's `id` |
| `failedToCreateImage(String)` | `imageCreationFailed(String)` |
| `ParametricKernelRegistryError.failedToApplyKernel(String)` | `imageCreationFailed(String)` |
| `ParametricKernelRegistryError.missingKernel`, `failedToLoadKernel`, `missingKernelLibraryResource` | `kernelUnavailable(name:reason:)` |

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
  of adjustment: LocalAdjustmentFeature<GaussianBlurFeature>,
  over extent: CGRect
) throws -> CIImage {
  try FeatureRenderer().makeMaskImage(for: adjustment.mask, extent: extent)
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
  `FilterFeature` accept only `Equatable` effects, so documents stay
  comparable.
- A domain feature conforms to `Feature`. Only the source is translated to
  zero origin, so return your output with a zero origin, as `CropFeature`
  does.
- An effect with nothing to do can return its input image itself; a
  `LocalAdjustmentFeature` then returns its input unchanged.

### Reorderable Steps

A list whose order the user decides, and which mixes domain features and
effects, becomes an enum of your own that conforms to `Feature`:

```swift
import BrightroomParametric

enum Step: Feature, Equatable {
  case crop(CropFeature)
  case effect(AnyImageEffect)
  case localAdjustment(LocalAdjustmentFeature<[AnyImageEffect]>)

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

struct StepsFeature: Feature, Equatable {
  var steps: [Step]

  var body: some Feature {
    steps
  }
}
```

### PresetFeature Is FilterFeature

`PresetFeature` is `FilterFeature`, and it is `Identifiable`: its
`identifier` is `id`, a `String` (5.x's `id: FeatureID` is gone).
`FilterFeature.effects` is `[AnyImageEffect]`, and the initializer has no
`isEnabled:`. A nested filter is `AnyImageEffect(innerFilter)`. Selection UIs
compare `id`; `==` still compares the name and the effects too.

```swift
import BrightroomParametric

let film = FilterFeature(
  name: "Film",
  id: "film",
  effects: [
    AnyImageEffect(SaturationFeature(value: -0.2)),
    AnyImageEffect(FadeFeature(intensity: 0.1)),
  ]
)
```

### ColorCubeFeature Loaders

`ColorCubeFeature(contentsOfCubeFile:name:id:intensity:)`,
`ColorCubeFeature(contentsOfCubeImage:name:id:intensity:dimension:)`, and
`ColorCubeFeature(cubeImage:name:id:intensity:dimension:)` take the
lookup-table identifier as `id: String` instead of a `FeatureID`
(optional in the two file loaders, where it defaults to the file name;
required in `init(cubeImage:…)`), and the opacity as `intensity` (5.x
`amount`).
`PresetStorage.loadLUTs(fromBundle:)` builds filters whose `effects` hold the
cube as `AnyImageEffect`.

```swift
import BrightroomParametric
import Foundation

func loadLUT(at url: URL) throws -> ColorCubeFeature {
  try ColorCubeFeature(contentsOfCubeFile: url, intensity: 0.8)
}
```

### Debug Feature Tree

`FeatureTreeView(feature:)` and `FeatureTreeOutline(feature:)` accept any
`some Feature` and show its body structure in evaluation order. `nil` members
are left out, composites and presets show their members as children, and
nodes have positional ids. `FeatureTreeNode` lost `isEnabled`.

```swift
import BrightroomParametric
import SwiftUI

struct FeatureInspector<Inspected: Feature>: View {
  var feature: Inspected

  var body: some View {
    FeatureTreeView(feature: feature)
  }
}
```

## Images and Documents

### SourceImage Replaces ImageProvider

`SourceImage` is the image an edit is authored over. It reads the image's
orientation and oriented pixel size when you create it, so it throws (or
suspends, for a Photos asset) up front instead of reporting failures from a
loading stack later. Encoded data and files are decoded only when something
renders or prepares the image.

| 5.1.1 | 6.0 |
| --- | --- |
| `ImageProvider(image:)` | `SourceImage(image:)` |
| `ImageProvider(data:)` | `SourceImage(data:)` |
| `ImageProvider(fileURL:)` | `SourceImage(contentsOf:)` |
| `ImageProvider(rawData:)`, `ImageProvider(rawDataURL:)` | `SourceImage(rawData:)`, `SourceImage(rawContentsOf:)`. They develop the RAW image when called, so call them off the main actor. |
| `ImageProvider(asset:)` | `try await SourceImage(asset:)` |
| `ImageProvider(editableRemoteURL:)`, `ImageProvider(editableRemoteURLRequest:)` | Download the data yourself, then `SourceImage(data:)` |
| `ImageProvider(contentEditingInput:)` | `SourceImage(contentsOf:)` with the input's `fullSizeImageURL` |
| `ImageProvider(imageSize:orientation:editableImage:pendingAction:)` | Load the image yourself, then create a `SourceImage` |
| `ImageSource`, `ImageProvider.LoadedImage` | `SourceImage` |
| `ImageProvider.ImageMetadata`, `EditingStack.Loaded.imageSize` | `SourceImage.pixelSize` (orientation applied) |
| `ImageProviderError` | `SourceImageError` |
| (new) | `SourceImage(cgImage:orientation:)`, `SourceImage.makeCIImage(maxPixelSize:)` |

Two source images are equal when they are the same load: copies are equal,
and loading the same file twice gives two different images. Keep the value
you loaded, for example in its document.

### EditingDocument

`EditingDocument<Content>` (BrightroomEngine) is a value that holds:

- `source`, the `SourceImage`, fixed for the document's lifetime;
- `feature`, the root feature, authored in the source image's oriented pixel
  coordinates;
- `history`, its commit-style undo history.

Changing `feature` records nothing. `commit()` records the current feature as
one undo step, and `undo()`, `redo()`, `canUndo`, `canRedo`,
`hasUncommittedChanges`, and `discardUncommittedChanges()` work on the value.
The UI that edits a document decides when to commit. `history.limit` caps the
undo steps (100 by default), and `history.removeAll()` drops them.
`render(options:)` renders the feature over the full-resolution source image.

`ImageEditorDocument` is `EditingDocument<ImageEditorFeature>`, the document
`ImageEditor` and `ImageEditorCanvas` edit. Your own editor can use
`EditingDocument` with its own root feature.

If you built against an unreleased Brightroom 6 snapshot, the document's
image was named `image`. It is `source` now, matching the vocabulary word
"source image":

| Earlier 6.0 snapshot | 6.0 |
| --- | --- |
| `EditingDocument.image`, `init(image:feature:history:)`, `ImageEditorDocument(image:)`, `ImageEditorDocument(image:cropModifier:)` | `EditingDocument.source`, `init(source:feature:history:)`, `ImageEditorDocument(source:)`, `ImageEditorDocument(source:cropModifier:)` |

### EditingStack Is No Longer Public

`EditingStack` is now a package-internal detail of BrightroomUI's editors,
which prepare their preview themselves. Apps never create one.

| 5.1.1 | 6.0 |
| --- | --- |
| `EditingStack(imageProvider:options:cropModifier:)` | A `SourceImage`, then `ImageEditorDocument(source:)`, or `await ImageEditorDocument(source:cropModifier:)` for a policy-decided crop |
| `start()`, `isLoading`, `loadedState` | None. The editor prepares its preview. To show the image yourself, use `SourceImage.makeCIImage(maxPixelSize:)`. |
| `Loaded.makeOriginalCIImage()` | `SourceImage.makeCIImage()` |
| `Loaded.thumbnailImage`, `editingSourceImage`, `editingSourceCGImage` | `SourceImage.makeCIImage(maxPixelSize:)` |
| `Loaded.currentEdit`, `EditingStack.Edit`, `featureTree`, `updateFeature(id:mutate:)`, `Edit.makeEditingDocument(orientedImageSize:)` | `document.feature`, read and written by member name |
| `undo()`, `redo()`, `Loaded.canUndo`, `Loaded.canRedo` | `document.undo()`, `redo()`, `canUndo`, `canRedo` |
| `commitCurrentEditIfNeeded()`, `Loaded.hasUncommittedChanges` | `document.commit()`, `hasUncommittedChanges` |
| `revertCurrentEdit()` | `document.discardUncommittedChanges()` |
| `removeAllHistory()` | `document.history.removeAll()` |
| `revert(to:)`, `currentRevision`, `Revision` | None. Keep a copy of the document to return to. |
| `Loaded.isDirty` | Compare `document.feature` with the feature you started from |
| `cropModifier` | `await ImageEditorDocument(source:cropModifier:)`. See [CropModifier](#cropmodifier-moved-to-brightroomui). |
| `makeRenderer().render(options:)`, `BrightRoomImageRenderer`, `ImageRenderer` | `document.render(options:)` |
| `EditingStackError` | None. `SourceImageError` covers loading. |

Before:

```swift
// Brightroom 5.x
let stack = EditingStack(imageProvider: .init(image: image))
stack.start()
// …
let rendered = try await stack.makeRenderer().render()
```

After:

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import UIKit

func renderEdit(of image: UIImage) async throws -> UIImage {
  let document = ImageEditorDocument(source: SourceImage(image: image))
  // … edit the document …
  let rendered = try await document.render()
  return try rendered.uiImage
}
```

A new `ImageEditorDocument` has no effects and a crop that covers the whole
image, so it renders the unedited image. Without BrightroomUI, pass
`EmptyFeature()` to `ExportRenderer` for the same result.

## ImageEditor

`SwiftUIPhotosCropView` is `ImageEditor`, and it edits an
`ImageEditorDocument` your app owns instead of a `PhotosCropEditingModel`
over an `EditingStack`.

| 5.1.1 | 6.0 |
| --- | --- |
| `SwiftUIPhotosCropView(editingModel:options:localizedStrings:onDone:onCancel:)` | `ImageEditor(document:options:localizedStrings:onDone:onCancel:)`, with a `Binding<ImageEditorDocument>` |
| `PhotosCropEditingModel(editingStack:)` | `ImageEditorDocument(source:)`, kept in your state (for example `@State`) |
| `onCancel` (required) | Optional. The editor writes back the document it opened with, then calls `onCancel`. `nil` hides the Cancel button. |
| `SwiftUIPhotosCropView.Options` | `ImageEditor.Options` |
| `SwiftUIPhotosCropView.LocalizedStrings` | `ImageEditor.LocalizedStrings` |
| `button_done_title`, `button_cancel_title`, `button_reset_title` | `done`, `cancel`, `reset` |
| `button_aspectratio_original`, `button_aspectratio_freeform`, `button_aspectratio_square` | `originalAspectRatio`, `freeformAspectRatio`, `squareAspectRatio` |
| `button_filter_original` | `originalFilter` |
| `Options.filterPresets` (default `PhotosCropDefaultFilterPresets.make()`) | `ImageEditor.Options.filters`, empty by default |

The aspect ratio option is one choice, so it is a policy, and the freeform
lock has its own case instead of `.fixed(nil)`:

| 5.1.1 | 6.0 |
| --- | --- |
| `Options.aspectRatioOptions: AspectRatioOptions` | `ImageEditor.Options.aspectRatioPolicy: AspectRatioPolicy` |
| `.selectable` | `.selectable` |
| `.fixed(ratio)` with a non-nil ratio | `.fixed(ratio)`, taking an `AspectRatio` |
| `.fixed(nil)` | `.freeform` |

`PhotosCropDefaultFilterPresets` was removed. Supply your own filters; the
former samples live in the demo app
([`DemoFilters.swift`](../Dev/Sources/SwiftUIDemo/DemoFilters.swift)).

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
  onCancel: { dismiss() }
)
```

After:

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import SwiftUI
import UIKit

struct Editor: View {
  @State var document: ImageEditorDocument
  var onExport: @MainActor (Result<UIImage, Error>) -> Void
  var onClose: @MainActor () -> Void

  var body: some View {
    ImageEditor(
      document: $document,
      onDone: {
        let document = document
        Task {
          do {
            let rendered = try await document.render()
            onExport(.success(try rendered.uiImage))
          } catch {
            onExport(.failure(error))
          }
        }
      },
      onCancel: onClose
    )
  }
}
```

How the editor writes to the binding:

- Each completed operation (a filter tap, a slider drag, a brush stroke, an
  applied crop) is written once. Values in progress are not.
- The work of one tool visit is one undo step. The commit happens with the
  next visit's first write, so after Done the last visit may still be
  uncommitted; `undo()` treats it as a step. Commit a copy before you save the
  history.
- The editor never registers anything with an `UndoManager`. Drive
  `document.undo()` and `redo()` from your own controls if you want them.
- `onDone` is called after the binding received the last change, so the
  document you read there is final.

### ImageEditorFeature

`ImageEditorFeature` (BrightroomUI) is the root feature `ImageEditor` and
`ImageEditorCanvas` edit. It is a `Feature` and `Equatable`:

- `effects: ImageEditorFeature.Effects` — the filter (`preset`) and twelve
  adjustments, each an optional member, evaluated in declaration order;
- `localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?` — the painted blur;
- `crop: CropFeature` — the final crop.

It is authored in the oriented, pre-crop source domain at full resolution
(`SourceImage.pixelSize`). Brush stamps are Core Image working-space points
(bottom-left origin, y-up). A 5.x `EditingStack.Edit.document` stored them
y-down, so flip them when you convert a saved 5.x edit (see
[Converting 5.x documents](parametric-persistence.md#converting-5x-documents)).
A new document from `ImageEditorDocument(source:)` has no effects and a crop
that covers the whole image. To rebuild a saved edit, use
`ImageEditorFeature(effects:localBlur:crop:)`.

### Editing in Code

`document.feature` is a plain value. Change it and commit when the change
should become an undo step:

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI

func brighten(_ document: inout ImageEditorDocument) {
  let current = document.feature.effects.exposure?.ev ?? 0
  document.feature.effects.exposure = ExposureFeature(ev: current + 0.3)
  document.commit()
}
```

### Reopening an Edit

In 5.x the `EditingStack` held the edit and its history, so keeping the stack
reopened the editor where the user left it. In Brightroom 6:

- **Keep the document.** Pass the same document to a new `ImageEditor`. The
  feature and its undo history are kept.
- **Resume a saved edit.** Store the image reference and the feature's values
  in your own format (see
  [Saving parametric edits](parametric-persistence.md)), and rebuild the
  document with `ImageEditorDocument(source:feature:history:)`.

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import Foundation

func resumeEdit(
  of imageURL: URL,
  exposure: Double?,
  cropRect: CGRect,
  quarterTurn: QuarterTurn,
  straightenRadians: Double
) throws -> ImageEditorDocument {
  let feature = ImageEditorFeature(
    effects: .init(exposure: exposure.map { ExposureFeature(ev: $0) }),
    crop: CropFeature(
      rect: cropRect,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
  )
  return ImageEditorDocument(
    source: try SourceImage(contentsOf: imageURL),
    feature: feature
  )
}
```

A rebuilt feature equals the one you saved. The document does not check that
the feature was authored for the image; resume it only over the same image.
`rect` is the selection before the quarter turn. Convert rectangles saved by
5.1.0 first ([Crop rectangles](parametric-persistence.md#crop-rectangles)).

## QuarterTurn Case Names

`QuarterTurn`'s cases now say how far the picture turns counterclockwise on
screen, in the order the built-in rotate button steps through. The number is
the magnitude of the raw value. The raw values, which your app may store, are
unchanged:

| 5.x | 6 | Raw value |
| --- | --- | --- |
| `.zero` | `.zero` | `0` |
| `.quarterCW` | `.counterclockwise90` | `-90` |
| `.half` | `.counterclockwise180` | `-180` |
| `.quarterCCW` | `.counterclockwise270` | `-270` |

The 5.x names read the raw value's sign as y-up math, but the raw value is a
y-down (UIKit) angle: `-90` has always turned the output counterclockwise on
screen, like the built-in rotate button, and `-270` (270° counterclockwise)
looks the same as 90° clockwise. Rendering is unchanged.

`CropRotation` (`.angle_0`, `.angle_90`, `.angle_180`, `.angle_270`) was a
second name for the same four values and is removed. Use `QuarterTurn`:
`CropEditingState.rotation` is a `QuarterTurn`, `.angle_90` is
`.counterclockwise90`, and `ImageEditorCanvas`'s `rotation(_:)` is
`quarterTurn(_:)`.

## SwiftUICropView → ImageEditorCanvas

`SwiftUICropView` is now `ImageEditorCanvas`. It edits an
`ImageEditorDocument` through a binding instead of the stack's edit:

- `init(editingStack:isGuideInteractionEnabled:areAnimationsEnabled:contentInset:stateHandler:)`
  and the variant with `cropInsideOverlay`/`cropOutsideOverlay` take
  `document: Binding<ImageEditorDocument>` instead of `editingStack:`. The
  canvas prepares the document's image itself, and a document of another
  image rebuilds it.
- Changes made on the canvas (applied crops and brush strokes) are written
  to the document's `feature`. The canvas never commits; call
  `document.commit()` when a change should become an undo step.
- `editingTarget(_:)` with `ImageEditorCanvas.Target` (`.crop`, `.localBlur`,
  or `nil` to only view) replaces `featureFocus(_:)` and
  `CropViewFeatureFocus`. The target is the adjustment point: the feature the
  canvas edits while it shows the evaluated result. The seed effect of
  `CropViewFeatureFocus.masking(_:id:)` is gone: the first stroke creates
  `localBlur` with the default blur. To use another blur, set
  `document.feature.localBlur` yourself.
- Renamed members: `rotation(_:)` is `quarterTurn(_:)` (taking a
  `QuarterTurn`), `adjustmentAngle(_:)` is `straightenAngle(_:)`,
  `croppingAspectRatio(_:)` is `lockedAspectRatio(_:)` (taking an
  `AspectRatio`), `SwiftUICropView.AdjustmentKind` is `CropInteraction`
  (`.scrollView` is `.movingImage`, `.guide` is `.resizingGuide`), and
  `StateSnapshot.adjustmentKind` is `StateSnapshot.interaction`.
- `maskingBrush(_:)` and `strokeSmoothing(_:)` are one `brush(_:)`.
  `CropViewMaskingBrush` is `ImageEditorCanvas.Brush`, and the smoothing
  configuration is its `smoothing` member: `.off`, `.bezier(strength:)`,
  `.catmullRom(strength:)`, or `.movingAverage(strength:)` (the default is
  `.bezier(strength: 0.85)`).
- `CropEditingState.updateCropExtent(toFitBoundingBox:respectingApectRatio:)`
  is spelled `respectingAspectRatio:`.
- The initializers' `contentInset: UIEdgeInsets?` is
  `contentInsets: EdgeInsets?`. Leading and trailing follow the layout
  direction, so in a right-to-left layout `leading` insets the right edge.

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
  @Binding var document: ImageEditorDocument
  @State private var target: ImageEditorCanvas.Target? = .localBlur

  var body: some View {
    ImageEditorCanvas(document: $document)
      .editingTarget(target)
      .onDisappear { document.commit() }
  }
}
```

## CropModifier Moved to BrightroomUI

`EditingStack.CropModifier` is now `CropModifier` in BrightroomUI, and
`CropModifier.Closure` is now `CropModifier.Modify`. The closure is `async`,
works on a `CropEditingState`, and is `@Sendable`:
`@Sendable (CIImage, CropEditingState) async -> CropEditingState`. It runs off
the main actor, so the state it captures must be `Sendable`; move blocking work
to your own queue, as `faceDetection` does. `.identity` and
`.faceDetection(paddingBias:aspectRatio:)` are provided. It runs once, when
you create a document with `await ImageEditorDocument(source:cropModifier:)`,
and never for a document you rebuild from saved values. Its crop is the
document's committed state, so undo does not return to the full-image crop.
The `aspectRatio` of `.faceDetection` describes the final output, after the
crop's quarter turn.

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
import BrightroomParametric
import BrightroomUI

func makeFramedDocument(for source: SourceImage) async -> ImageEditorDocument {
  await ImageEditorDocument(
    source: source,
    cropModifier: .faceDetection(aspectRatio: .square)
  )
}

let squareCrop = CropModifier { _, crop in
  var crop = crop
  crop.updateCropExtent(toFitAspectRatio: .square)
  return crop
}
```

## Crop Rectangles and Output Rotation

`CropFeature` evaluates straighten → crop → exact quarter turn. `rect`
(5.x `cropRect`), `topLeftRect(imageSize:)`,
`CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)`, and
`CropEditingState.cropExtent` describe the selection after straightening and
before the quarter turn. In 5.1.0 they described the frame in the output
orientation, turned about its center.

Changing `quarterTurn` (5.x `rotation`) changes only the output orientation; a sideways turn
exchanges the output's width and height. Code that turned a rectangle about
its center when it set a sideways rotation must stop doing so.

Before:

```swift
// Brightroom 5.x: the frame of a 300 × 200 image turned by -90.
let crop = CropFeature(
  cropRect: CGRect(x: 50, y: -50, width: 200, height: 300),
  rotation: .quarterCW
)
```

After:

```swift
import BrightroomParametric
import CoreGraphics

// The whole 300 × 200 image; it renders 200 × 300.
let crop = CropFeature(
  rect: CGRect(x: 0, y: 0, width: 300, height: 200),
  quarterTurn: .counterclockwise90
)
```

Unlike most 5.x samples, the Before code still compiles against Brightroom 6
once `cropRect:` is renamed `rect:`, `rotation:` is renamed `quarterTurn:`,
and `.quarterCW` is renamed `.counterclockwise90`
([QuarterTurn Case Names](#quarterturn-case-names)). There it selects a
200 × 300 area that extends past the 200-pixel-high image and renders
300 × 200 with transparent bands, so convert such rectangles rather than
relying on the compiler to find them.

- Aspect ratios describe the final output:
  `CropEditingState.updateCropExtent(toFitAspectRatio:)`, the crop view's
  aspect lock, and `CropModifier.faceDetection(aspectRatio:)`. A locked ratio
  turns with the output without refitting the selection.
- Crops keep the requested canvas at every rotation; parts outside the input
  are transparent. Quarter turns no longer trim a row or column to even out
  the dimensions, so odd sizes keep every pixel.
- New API: `CropFeature.outputGeometry(in:)`, which returns
  `CropFeature.OutputGeometry` (`outputBounds`, `inputToOutputTransform`);
  `QuarterTurn.isSideways`; `CropGeometry.rect(_:turnedBy:)`;
  `CropGeometry.fittingRect(rect:in:straightenRadians:respectingAspectRatio:)`;
  and a `straightenRadians:` parameter on
  `CropGeometry.cropRect(toFitAspectRatio:in:)` and
  `CropGeometry.cropRect(toFitBoundingBox:within:in:respectingAspectRatio:)`.
- `CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)` with a
  non-zero `straighten` now fits the selection so its straightened footprint
  lies inside the input, shrinking it uniformly and moving it only if needed,
  and then snaps its dimensions inward; the origin can stay fractional. 5.1.0
  snapped every selection inward to the unrotated bounds and left uncovered
  corners transparent. Without straightening, edges still snap inward.
- ImageEditor's Done commits the proposed crop directly, so reopening and
  confirming an untouched crop keeps it exactly.
- Rectangles saved by 5.1.0: see
  [Crop rectangles](parametric-persistence.md#crop-rectangles).

## CropEditingState

`CropEditingState.id` was removed, and `makeCropFeature()` is internal. Write
a crop state into a root feature with `ImageEditorFeature.setCrop(_:)`, which
snaps the rectangle the same way the canvas does:

```swift
import BrightroomEngine
import BrightroomUI

func squareDocument(for source: SourceImage) -> ImageEditorDocument {
  var document = ImageEditorDocument(source: source)
  var crop = CropEditingState(cropFeature: document.feature.crop, imageSize: source.pixelSize)
  crop.updateCropExtent(toFitAspectRatio: .square)
  document.feature.setCrop(crop)
  return document
}
```

## Renamed Parametric API

BrightroomParametric uses one word per concept. A renderer is named after
what it renders, `makeImage` returns a lazy `CIImage` recipe and `render`
produces pixels, and the extent that proportional radii resolve against is
the chain-entry extent everywhere.

### Renderers

| 5.1.1 | 6.0 |
| --- | --- |
| `ParametricImageRenderer` | `FeatureRenderer` |
| `ParametricImageRenderer.makeImage(from:feature:radiusReferenceExtent:presentationTime:)` | `FeatureRenderer.makeImage(from:feature:chainEntryExtent:presentationTime:)` |
| `ParametricExportRenderer` | `ExportRenderer` |
| `ParametricExportRenderer.render(source:feature:options:device:)` | `ExportRenderer.render(from:feature:options:device:)` |
| `ParametricExportRenderer.Options(workingFormat:workingColorSpace:)`, `.workingFormat`, `.workingColorSpace` | `ExportRenderer.Options(outputFormat:outputColorSpace:)`, `.outputFormat`, `.outputColorSpace`. They were always the output format and the output color-space tag; processing runs in a half-float working space either way. |
| `ParametricExportRenderer.ExportFileType` | `ExportRenderer.FileType` |
| `ParametricExportRenderer.RenderingDevice` | `ExportRenderer.Device` |
| `ParametricExportRenderer.RenderingError` | `ExportRendererError` |
| `ParametricExportRenderer.Rendered` | `RenderedImage` |
| `ParametricVideoRenderer` | `VideoRenderer` |
| `ParametricVideoRenderer.makeFrameImage(from:feature:renderExtent:presentationTime:)` | `VideoRenderer.makeImage(from:feature:renderExtent:presentationTime:)` |
| `ParametricVideoRendererError` | `VideoRendererError` |
| `FeatureEvaluationContext(radiusReferenceExtent:presentationTime:)`, `.radiusReferenceExtent`, `radiusBasis(for:)`, `withRadiusReferenceExtent(_:)` | `FeatureEvaluationContext(chainEntryExtent:presentationTime:)`, `.chainEntryExtent`, `chainEntryExtent(for:)`, `withChainEntryExtent(_:)` |
| `FeatureEvaluationError.failedToCreateImage(_:)` | `FeatureEvaluationError.imageCreationFailed(_:)` |

`EditingDocument.render(options:)` takes `ExportRenderer.Options` and returns
a `RenderedImage`.

Two export behaviors changed with the rename:

- `Rendered.makeOptimizedForSharingData(dataType:)` and `Rendered.DataType`
  are `RenderedImage.sharingData(as:)`, which takes the same
  `ExportRenderer.FileType` as `Output.file`, so HEIF is available for
  sharing too. It now throws `ExportRendererError.sharingDataEncodingFailed`
  when Image I/O cannot encode the image; it used to return empty data.
- Every export failure is an `ExportRendererError`, which is `Equatable` and a
  `LocalizedError`. A failed `Output.file` write, which used to throw an
  internal writer error, throws `.fileWriteFailed(url, step:)`.

### Masks and Local Adjustments

| 5.1.1 | 6.0 |
| --- | --- |
| `LocalAdjustmentFeature(maskTree:effectPipeline:blendMode:)`, `.maskTree` | `LocalAdjustmentFeature(mask:content:)`, `.mask` |
| `MaskTree(root:)` and `MaskTree.root` | The `Mask` value itself; a local adjustment holds a `Mask` directly |
| `MaskNode` | `Mask` (an indirect enum) |
| `MaskNode.invert(_:)` | `Mask.inverted(_:)` |
| `MaskNode.feather(MaskFeather(input:radius:))` | `Mask.feathered(_:radius:)` |
| `MaskNode.union(_:)` | `Mask.union(_:)` |
| `MaskNode.intersect(_:)` | `Mask.intersection(_:)` |
| `MaskNode.subtract(MaskSubtract(base:removing:))` | `Mask.subtraction(_:removing:)` |
| `BrushMaskStroke(stamps:brush:)`, `.stamps` | `BrushMask.Stroke(stampCenters:brush:)`, `.stampCenters` |
| `BrushMaskBrush` | `BrushMask.Brush` |
| `FeatureRenderer.makeMaskImage(for: MaskTree, extent:)` | `FeatureRenderer.makeMaskImage(for: Mask, extent:)` |

### Feature Members

| 5.1.1 | 6.0 |
| --- | --- |
| `CropFeature(cropRect:rotation:straightenRadians:)`, `.cropRect`, `.rotation` | `CropFeature(rect:quarterTurn:straightenRadians:)`, `.rect`, `.quarterTurn` |
| `CropFeature.OutputGeometry.sourceToOutputTransform` | `CropFeature.OutputGeometry.inputToOutputTransform` |
| `GaussianBlurRadius` | `GaussianBlurFeature.Radius` |
| `GaussianBlurFeature(radius: Double)`, `GaussianBlurFeature(value:)` | `GaussianBlurFeature(radius: .absolute(_:))`, `GaussianBlurFeature(radius: .proportional(_:))` |
| `TemperatureFeature(value:tint:)`, `.value` | `WhiteBalanceFeature(temperature:tint:)`, `.temperature` |
| `ExposureFeature(value:)`, `.value` | `ExposureFeature(ev:)`, `.ev` |
| `SharpenFeature(sharpness:radius:)`, `.sharpness` | `SharpenFeature(intensity:radius:)`, `.intensity` |
| `ParametricRGBAColor` | `HighlightShadowTintFeature.Color` |

Library types that conform to `Feature` end in `Feature`. Values that are not
features (`Mask`, `BrushMask`, `QuarterTurn`) have no suffix, and a value type
used by only one feature is nested in it (`GaussianBlurFeature.Radius`,
`BrushMask.Stroke`).

### Filters and Color Cubes

| 5.1.1 | 6.0 |
| --- | --- |
| `PresetFeature(name:identifier:effects:)`, `.identifier` | `FilterFeature(name:id:effects:)`, `.id` (`Identifiable`) |
| `ColorCubeFeature.identifier`, `.amount` | `ColorCubeFeature.id`, `.intensity` |
| `ColorCubeFeature(cubeImageAt:…)` | `ColorCubeFeature(contentsOfCubeImage:…)` |
| `ColorCubeFeatureLoadingError` | `ColorCubeLoadingError` |
| `.failedToCreateImage(_:)`, `.missingLUT3DSize`, `.invalidLUT3DSize(_:line:)` | `.unreadableImage(_:)`, `.missingCubeSize`, `.invalidCubeSize(_:line:)` |
| `FeatureEvaluationError.invalidColorCubeData(identifier:…)` | `FeatureEvaluationError.invalidColorCubeData(id:…)` |
| `SwiftUIPhotosCropView.Options.filterPresets` | `ImageEditor.Options.filters` |

### Tone Curve and Color Mixer Values

| 5.1.1 | 6.0 |
| --- | --- |
| `ToneCurveEditorValue` | `ToneCurveFeature.Curves` |
| `ToneCurveChannel` | `ToneCurveFeature.Channel` |
| `ToneCurveFeature(value:)`, `.value` | `ToneCurveFeature(curves:)`, `.curves` |
| `ToneCurveRenderIdentity(value:)`, `ToneCurveRenderIdentity(activeValue:)` | `ToneCurveFeature.RenderKey(curves:)`, `ToneCurveFeature.RenderKey(activeCurves:)` |
| `ToneCurve.isNeutral`, `ToneCurveEditorValue.isNeutral` | `ToneCurve.isDefault`, `ToneCurveFeature.Curves.isDefault` |
| `ToneCurve.isIdentityMapping` | `ToneCurve.isIdentity` |
| `ColorMixerAdjustment` | `ColorMixerFeature.Bands` |
| `ColorMixerBandAdjustment` | `ColorMixerFeature.BandCorrection` |
| `ColorMixerBand` | `ColorMixerFeature.Band` |
| `ColorMixerFeature(adjustment:algorithm:)`, `.adjustment` | `ColorMixerFeature(bands:algorithm:)`, `.bands` |
| `ColorMixerAdjustment.isNeutral`, `ColorMixerBandAdjustment.isNeutral` | `ColorMixerFeature.Bands.isIdentity`, `ColorMixerFeature.BandCorrection.isIdentity` |
| `ColorMixerRenderIdentity(activeAdjustment:algorithm:)` | `ColorMixerFeature.RenderKey(activeBands:algorithm:)` |

### Metal Library

| 5.1.1 | 6.0 |
| --- | --- |
| `BrushStampMetalLibrary`, `BrushStampMetalLibraryError` | `BrightroomMetalLibrary`, `BrightroomMetalLibraryError`. The library holds more than the brush stamp. |

## Renamed Engine API

BrightroomEngine keeps the document and its image. Crop value types moved
next to `CropFeature` in BrightroomParametric, so add
`import BrightroomParametric` where you name them.

### Aspect Ratio

"Pixel aspect ratio" names the shape of one pixel
(`AVVideoPixelAspectRatioKey`), not the proportion of an image or a crop.

| 5.1.1 | 6.0 |
| --- | --- |
| `PixelAspectRatio` (BrightroomEngine) | `AspectRatio` (BrightroomParametric) |
| `PixelAspectRatio._minimized()` | `AspectRatio.reduced()` |

### Crop Conversions

The y-down conversions and the pixel-grid comparison were extensions that
BrightroomEngine added to `CropFeature`. They are now part of `CropFeature`
in BrightroomParametric, together with `CropGeometry`. "Display" is kept for
the viewport, and the comparison checks the pixels a crop selects, not how
it renders.

| 5.1.1 | 6.0 |
| --- | --- |
| `CropFeature(id:isEnabled:displayCropRect:imageSize:rotation:straighten:)` | `CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)` |
| `CropFeature.displayCropRect(imageSize:)` | `CropFeature.topLeftRect(imageSize:)` |
| `CropFeature.isRenderingEquivalent(to:orientedImageSize:)` | `CropFeature.isPixelEquivalent(to:imageSize:)` |
| `CropEditingState.isRenderingEquivalent(to:)` | `CropEditingState.isPixelEquivalent(to:)` |
| `CropGeometry` (BrightroomEngine) | `CropGeometry` (BrightroomParametric), with the same members |

### Image Decoding

`ImageTool` is now the internal `ImageDecoding`. "Tool" names an editor mode,
and the type only serves `SourceImage` and the editing preview. Its
`maxPixelSizeHint:` was a short-side length, not the longest-side cap that
`maxPixelSize` means in Image I/O; internally it is `shortSideLength:`.

| 5.1.1 | 6.0 |
| --- | --- |
| `ImageTool.readImageSize(from:)`, `ImageTool.readOrientation(from:)` | `SourceImage(contentsOf:)` or `SourceImage(data:)`, then `pixelSize` (orientation applied). For the stored size or orientation, read `CGImageSourceCopyPropertiesAtIndex` yourself. |
| `ImageTool.makeResizedCGImage(from:maxPixelSizeHint:)`, `ImageTool.makeResizedCGImage(from:maxPixelSize:)` | `SourceImage.makeCIImage(maxPixelSize:)`, which caps the longer side |
| `ImageTool.makeImageForJPEGOptimizedSharing(image:quality:)` | `RenderedImage.sharingData(as: .jpeg(quality:))` |

### Logging

Console filters that match BrightroomEngine's log names need updating:

| 5.1.1 | 6.0 |
| --- | --- |
| OSLog subsystem `PixelEngine` | `BrightroomEngine` |
| OSLog category `🥞 Stack` | `Preview` |
| Dispatch queue labels `app.muukii.Brightroom.EditingStack`, `…EditingStack.central` | `app.muukii.Brightroom.PreviewSource`, `…PreviewSource.central` |

## Still Open Before 6.0

Brightroom 6 is not released yet. These parts of the public API may still
change before 6.0.0; the rest of this guide describes them as they are now.

- `CropModifier` and `ImageEditorDocument(source:cropModifier:)` may become an
  initial-crop policy that works on `CropFeature`. `CropEditingState` and
  `ImageEditorFeature.setCrop(_:)` may leave the public API, so that
  `CropFeature` is the one public crop value.
- `ImageEditorCanvas.StateSnapshot` with `stateHandler`, and the
  `ResetAction`, `RotateAction`, `ApplyAction`, and
  `AdjustmentAngleCommitAction` classes, may be replaced by a crop-guide
  change callback and a reader/proxy pair. The `Binding` forms of
  `quarterTurn(_:)`, `straightenAngle(_:)`, and `lockedAspectRatio(_:)` may
  become value-only.
- `FeatureTreeView` and `FeatureTreeOutline` may move out of
  BrightroomParametric, and `RenderedImage.swiftUIImage` may be removed.
- `SwiftUIMetalImageView` may move to the demo app.
- BrightroomEngine's `ColorCubeLoader`, `ColorCubeHelper`,
  `ColorCubeTextParser`, and `PresetStorage` may be removed in favor of the
  `ColorCubeFeature` loaders.
- Public helpers meant for Brightroom's own modules may become package
  access: `FeatureEvaluationContext.init`, `CropGeometry`,
  `AspectRatio.reduced()`, `Geometry`, `CIImage.removingExtentOffset()`,
  `ExportRenderer.Device`, `VideoRenderer.resolveRenderSize`,
  `ToneCurveEvaluator`, and `BrightroomMetalLibrary`. To test a custom
  feature, evaluate it through `FeatureRenderer` rather than calling
  `apply(to:context:)` with a context you build.

## Migration Checklist

- [ ] The package requirement is `from: "6.0.0"`.
- [ ] Saved edits use your own `Codable` model; documents written by
      `ParametricDocumentCodec` are converted once
      ([5.x conversion list](parametric-persistence.md#converting-5x-documents)).
- [ ] The 5.x `EditingDocument`, `MainTree`, and `EffectPipeline` are
      replaced by root features that conform to `Feature`.
- [ ] No `FeatureID`, `FeatureID`-typed `id:`, or `isEnabled:` remains;
      enablement is optional members, `if`, or nodes left out of masks.
- [ ] Custom effects conform to `ImageEffect` and `Equatable`; custom domain
      features conform to `Feature` and return a zero-origin image.
- [ ] Code that caught `FeatureGraphCompilerError` catches
      `FeatureEvaluationError`, and code that relied on
      `emptyLocalAdjustmentEffectPipeline` checks the content itself.
- [ ] Filters pass `[AnyImageEffect]`; color-cube loaders take `id: String`
      instead of `FeatureID`.
- [ ] `ImageProvider` is replaced by `SourceImage`, and `EditingStack` and
      `PhotosCropEditingModel` by an `ImageEditorDocument` in your state.
- [ ] `ImageEditor(document:)` replaces `SwiftUIPhotosCropView`, and `onDone`
      renders the document with `render(options:)`.
- [ ] `SwiftUICropView` is replaced with `ImageEditorCanvas`, which has a
      document binding and uses `editingTarget(_:)`; your code commits undo
      steps for canvas edits.
- [ ] `CropModifier` is passed to `await ImageEditorDocument(source:cropModifier:)`.
- [ ] Filters are supplied through `options.filters`.
- [ ] The renames in [Name Changes at a Glance](#name-changes-at-a-glance)
      are applied, including `QuarterTurn` case names and log filters.
- [ ] Crop rectangles are selections before the quarter turn; rectangles
      saved by 5.1.0 with a sideways rotation are converted.
- [ ] Loading, crop, filters, adjustments, blur mask, undo, reopening, and
      final rendering are tested again.
