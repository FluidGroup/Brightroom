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
6 it is BrightroomEngine's value that pairs a root feature with its source
image and history.

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
7. Replace `SwiftUICropView` with `ImageEditorCanvas(document:)`,
   `featureFocus(_:)` with `editingTarget(_:)`, and its actions with an
   `ImageEditorCanvasReader`.
8. Pass an `InitialCrop` to `await ImageEditorDocument(source:initialCrop:)`
   instead of a `CropModifier` to `EditingStack`.
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

BrightroomParametric no longer imports SwiftUI: the feature tree rows moved
to BrightroomUI ([Debug Feature Tree](#debug-feature-tree)) and
`RenderedImage.swiftUIImage` is removed ([Renderers](#renderers)).
`RenderedImage.uiImage` stays, where UIKit is available.

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
| `SwiftUICropView.StateSnapshot` | `ImageEditorCanvas.CropGuide`, reported by `onCropGuideChange(_:)` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `SwiftUICropView.ResetAction`, `.RotateAction`, `.ApplyAction` | `ImageEditorCanvasReader` and `ImageEditorCanvasProxy` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `SwiftUICropView.AdjustmentAngleCommitAction` | `straightenAngle(_:isEditing:)` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `CropViewFeatureFocus` | `ImageEditorCanvas.Target`, set with `editingTarget(_:)` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `CropViewMaskingBrush` | `ImageEditorCanvas.Brush` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `EditingCanvasStrokeSmoothingConfiguration`, `EditingCanvasStrokeSmoothingAlgorithm` | `ImageEditorCanvas.Brush.Smoothing` | [ImageEditorCanvas](#swiftuicropview--imageeditorcanvas) |
| `CropRotation` | `QuarterTurn` | [QuarterTurn Case Names](#quarterturn-case-names) |
| `CropEditingState` | Removed from the public API. Use `CropFeature`. | [CropEditingState](#cropeditingstate-is-no-longer-public) |
| `EditingStack.CropModifier` (BrightroomEngine) | `InitialCrop` (BrightroomUI) | [InitialCrop](#initialcrop-replaces-cropmodifier) |
| `SwiftUIMetalImageView`, `ImageDisplayBackground` | Removed; the demo app keeps its own copy | [Helpers No Longer Public](#helpers-no-longer-public) |

### BrightroomEngine

| 5.1.1 | 6.0 | See |
| --- | --- | --- |
| `ImageProvider`, `ImageSource`, `ImageProviderError` | `SourceImage`, `SourceImageError` | [SourceImage](#sourceimage-replaces-imageprovider) |
| `EditingStack` (with `Edit`, `Loaded`, `Options`, `Revision`), `EditingStackError` | Removed. Its edit and history are `EditingDocument`; its loading is `SourceImage`. | [EditingStack](#editingstack-is-removed) |
| `BrightRoomImageRenderer`, `ImageRenderer` | `EditingDocument.render(options:)` | [EditingStack](#editingstack-is-removed) |
| `EditingFeatureTree`, `FeatureTreePoint` | Removed. Address features by member name. | [Addressing Features](#addressing-features) |
| `PixelAspectRatio` | `AspectRatio` (BrightroomParametric) | [Aspect Ratio](#aspect-ratio) |
| `CropGeometry` | Removed from the public API. Use `CropFeature.fitted(to:imageSize:)` and `pixelAligned(imageSize:)`. | [Crop Conversions](#crop-conversions) |
| `ImageTool` | Internal | [Image Decoding](#image-decoding) |
| `ColorCubeLoader`, `ColorCubeHelper`, `PresetStorage` (with their error types) | Removed. Use the `ColorCubeFeature` loaders and `ImageEditor.Options.filters`. | [Loading LUT Files](#loading-lut-files) |
| `Geometry` | Internal | [Helpers No Longer Public](#helpers-no-longer-public) |
| `_BrightroomDebounce` | Removed | [Helpers No Longer Public](#helpers-no-longer-public) |

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
| `GaussianBlurRadius` | `EffectRadius` | [Feature Members](#feature-members) |
| `ParametricRGBAColor` | `HighlightShadowTintFeature.Color` | [Feature Members](#feature-members) |
| `PresetFeature` | `FilterFeature` | [Filters and Color Cubes](#filters-and-color-cubes) |
| `ColorCubeFeatureLoadingError` | `ColorCubeLoadingError` | [Filters and Color Cubes](#filters-and-color-cubes) |
| `ToneCurveEditorValue`, `ToneCurveChannel` | `ToneCurveFeature.Curves`, `ToneCurveFeature.Channel` | [Tone Curve and Color Mixer Values](#tone-curve-and-color-mixer-values) |
| `ColorMixerAdjustment`, `ColorMixerBandAdjustment`, `ColorMixerBand` | `ColorMixerFeature.Bands`, `.BandCorrection`, `.Band` | [Tone Curve and Color Mixer Values](#tone-curve-and-color-mixer-values) |
| `ToneCurveRenderIdentity`, `ColorMixerRenderIdentity` | `ToneCurveFeature.RenderKey`, `ColorMixerFeature.RenderKey` | [Tone Curve and Color Mixer Values](#tone-curve-and-color-mixer-values) |
| `BrushStampMetalLibrary` | Not public | [Metal Library](#metal-library) |
| `FeatureTreeView`, `FeatureTreeOutline` | `FeatureTreeView` is removed; `FeatureTreeOutline` moved to BrightroomUI | [Debug Feature Tree](#debug-feature-tree) |
| `FeatureTreeDescriptor` | `FeatureTreeNode.nodes(for:)` | [Debug Feature Tree](#debug-feature-tree) |
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
identity. `==` still compares it along with the other stored properties: a
filter's name and effects, and a LUT's name, intensity, dimension, and cube
data.
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
| `FeatureGraphCompiler`, `FeatureGraphCompiler.Options`, `makeOutput(from:document:…)` | `FeatureRenderer().makeImage(from:feature:)` |
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
| `GaussianBlurRadius.editingStackFilterValue(_:)` | `EffectRadius.proportional(_:)`, as in `GaussianBlurFeature(radius: .proportional(40))` |
| `ParametricKernelRegistry`, `ParametricKernelRegistryError`, `FeatureEvaluationContext.kernelRegistry`, and the `kernelRegistry:` parameter of `FeatureEvaluationContext.init` | None; the kernels are internal, and the renderers build the context. See [Helpers No Longer Public](#helpers-no-longer-public). |
| `FeatureTreeNode.isEnabled`; `FeatureTreeView(document:)`, `FeatureTreeOutline(document:)`, and `FeatureTreeDescriptor.nodes(for:)` taking `EditingDocument` | `FeatureTreeOutline(feature:)` (BrightroomUI) and `FeatureTreeNode.nodes(for:)` taking `some Feature`. See [Debug Feature Tree](#debug-feature-tree). |

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

The debug rows (`FeatureTreeOutline(feature:)`) identify nodes by their type
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

Both features now compute in extended-linear Display-P3 whatever `CIContext`
renders them. In 5.1.x their kernels read the context's working-space values
as Display-P3, so their colors depended on the context: a default
`CIContext()` and `ParametricVideoRenderer`'s default video context
(`ciContext: nil`, which AVFoundation renders in linear sRGB) shifted the
colors, and a gamma-encoded working space shifted them further. Video rendered by
`VideoRenderer.makeVideoComposition(for:feature:renderSizeMode:ciContext:)`
with the default context now matches stills and the export; so does a still
you render with your own context. `ExportRenderer` and the editor canvas
already worked in that space, and their pixels are unchanged. Remove any
workaround that passed a Display-P3 context only for these features. Keep a
floating-point working format: an 8-bit one still loses precision.

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

The image covers `extent` and is transparent where nothing is painted. A
brush mask is drawn as one Core Image node, so a mask with thousands of
stamps renders and exports like a small one. In 5.1.1 a dense mask (about
5,000 stamps) could export a correctly sized, fully transparent image without
an error.

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
- To test a custom feature, evaluate it with
  `FeatureRenderer().makeImage(from:feature:)`. `FeatureEvaluationContext`
  has no public initializer; the renderer builds it.

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
`amount`). They are the only way to load a LUT: BrightroomEngine's
`ColorCubeLoader`, `ColorCubeLoaderError`, `ColorCubeHelper`,
`ColorCubeHelperError`, and `PresetStorage` are removed (see
[Loading LUT Files](#loading-lut-files)).

```swift
import BrightroomParametric
import Foundation

func loadLUT(at url: URL) throws -> ColorCubeFeature {
  try ColorCubeFeature(contentsOfCubeFile: url, intensity: 0.8)
}
```

The image loaders (`init(contentsOfCubeImage:…)` and `init(cubeImage:…)`)
read a LUT image's pixel values as they are stored, in the image's own RGB
color space. 5.1.1's `init(cubeImageAt:…)` converted them to the device RGB
space first, so a LUT image tagged with a space other than sRGB, such as
Display P3 (common for images taken from an iPhone) or Adobe RGB, now loads
different values than it did through that initializer: the ones the file
stores, which is what 5.1.1's `ColorCubeHelper.createColorCubeData` read.
sRGB LUT images load the same values as before. An image in an extended
space, such as extended Display P3 or extended linear sRGB, loads its values
in 0...1 unchanged through the standard-range version of the space, and
values outside it are clipped. An image in a non-RGB space is still
converted to sRGB. To keep 5.1.1's result for a wide-gamut LUT image, draw it
into an sRGB image yourself and pass that to `init(cubeImage:…)`.

### Loading LUT Files

BrightroomEngine's LUT loading is removed in favor of the `ColorCubeFeature`
loaders:

| 5.1.1 (BrightroomEngine) | 6.0 |
| --- | --- |
| `ColorCubeLoader(bundle:).load()`, `ColorCubeLoaderError` | Your own scan of a folder, calling `ColorCubeFeature(contentsOfCubeImage:…)` or `ColorCubeFeature(contentsOfCubeFile:…)` per file (below) |
| `ColorCubeHelper.createColorCubeData(inputImage:cubeDimension:)`, `ColorCubeHelperError` | `ColorCubeFeature(cubeImage:name:id:intensity:dimension:)` |
| `ColorCubeHelper.makeColorCubeFilter(cubeData:dimension:cacheKey:)` | None. Apply the `ColorCubeFeature` as a feature. |
| `PresetStorage`, `PresetStorage.default`, `loadLUTs(fromBundle:)` | None. Pass the filters to `ImageEditor.Options.filters`, which is what the editor reads. (5.1.1's editor did not read `PresetStorage` either.) |

The file naming rule is your app's, so Brightroom no longer scans bundles.
This function follows 5.1.1's `ColorCubeLoader` rule,
`LUT_<dimension>_<name>.{png,jpg,jpeg}` and `<name>.cube`, and builds the
same names and ids (the id is the file name). Unlike 5.1.1, it skips other
files instead of failing on a `LUT_` file that is not an image, and it uses
the dimension in the name only to check the image's pixel count. A `.cube`
file without a `TITLE` is named after its whole base name: 5.1.1 removed a
`LUT_<dimension>_` prefix from it, and this function keeps it.

```swift
import BrightroomParametric
import BrightroomUI
import CoreGraphics
import Foundation

func loadLUTFilters(in directory: URL) throws -> [FilterFeature] {
  try FileManager.default
    .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .compactMap { url -> FilterFeature? in
      let cube: ColorCubeFeature
      switch url.pathExtension.lowercased() {
      case "cube":
        cube = try ColorCubeFeature(contentsOfCubeFile: url)
      case "png", "jpg", "jpeg":
        let parts = url.deletingPathExtension().lastPathComponent
          .split(separator: "_", maxSplits: 2)
        guard parts.count == 3, parts[0] == "LUT" else { return nil }
        cube = try ColorCubeFeature(
          contentsOfCubeImage: url,
          name: String(parts[2]),  // "Gloss" for LUT_64_Gloss.png, as in 5.1.1
          dimension: Int(parts[1])
        )
      default:
        return nil
      }
      return FilterFeature(name: cube.name, id: cube.id, effects: [AnyImageEffect(cube)])
    }
}

func makeEditorOptions() throws -> ImageEditor.Options {
  var options = ImageEditor.Options()
  options.filters = try loadLUTFilters(in: Bundle.main.bundleURL)
  return options
}

// In place of ColorCubeHelper.createColorCubeData, for a LUT image the user
// picks. Give every LUT its own id.
func importLUT(_ image: CGImage) throws -> ColorCubeFeature {
  try ColorCubeFeature(
    cubeImage: image,
    name: "Imported",
    id: UUID().uuidString,
    dimension: 64
  )
}
```

Give every LUT a unique `id`. The editor treats filters with the same `id`
as the same filter, and rendering caches the Core Image filter by the id and
the dimension, so two LUTs that share both render the same.

### Debug Feature Tree

`FeatureTreeOutline(feature:)` accepts any `some Feature` and shows its body
structure in evaluation order. `nil` members are left out, composites and
presets show their members as children, and nodes have type-path ids
(such as `FilterFeature#0/WhiteBalanceFeature#0`), so an absent member does
not change the ids of the nodes after it.
`FeatureTreeNode` lost `isEnabled`.

The outline moved to BrightroomUI, so BrightroomParametric does not depend on
SwiftUI for it. `FeatureTreeView` is removed: it only wrapped the outline in a
`List`, so put the outline in a `List` of your own. BrightroomUI supports
iOS only; on macOS, show the nodes that `FeatureTreeNode.nodes(for:)`
returns, which stays in BrightroomParametric.

| 5.1.1 | 6.0 |
| --- | --- |
| `FeatureTreeView(document:)`, `FeatureTreeView(nodes:)` | Removed. `List { FeatureTreeOutline(feature:) }`, or `List { FeatureTreeOutline(nodes:) }` for nodes |
| `FeatureTreeOutline` in BrightroomParametric | `FeatureTreeOutline` in BrightroomUI; add `import BrightroomUI` |
| `FeatureTreeDescriptor.nodes(for:)` | `FeatureTreeNode.nodes(for:)` |

```swift
import BrightroomParametric
import BrightroomUI
import SwiftUI

struct FeatureInspector<Inspected: Feature>: View {
  var feature: Inspected

  var body: some View {
    List {
      FeatureTreeOutline(feature: feature)
    }
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

### EditingStack Is Removed

`EditingStack` is gone. BrightroomUI's editors prepare their preview
themselves, with a package-internal loader that holds no edit and no history;
apps never create one.

| 5.1.1 | 6.0 |
| --- | --- |
| `EditingStack(imageProvider:options:cropModifier:)` | A `SourceImage`, then `ImageEditorDocument(source:)`, or `await ImageEditorDocument(source:initialCrop:)` for a policy-decided crop |
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
| `cropModifier` | `await ImageEditorDocument(source:initialCrop:)`. See [InitialCrop](#initialcrop-replaces-cropmodifier). |
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

`localBlur` accepts any `Mask`, but the editor paints and previews only a
plain `.brush` mask, the shape it authors. Check `isLocalBlurPaintable`: it is
false when the blur's mask is anything else (`.inverted`, `.feathered`,
`.union`, `.intersection`, `.subtraction`). Such a mask renders at export, but
the canvas shows the image without it, and `ImageEditorCanvas` paints nothing
for the `.localBlur` target. `ImageEditor`'s Blur mode then disables the brush
and keeps Clear, so the user can still remove the blur. Removing the blur
(`localBlur = nil`, or Clear) makes it paintable again.

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
`.angle_90` is `.counterclockwise90`, `CropEditingState.rotation` is
`CropFeature.quarterTurn`. `SwiftUICropView`'s `rotation(_:)` has no
replacement on `ImageEditorCanvas`
([ImageEditorCanvas](#swiftuicropview--imageeditorcanvas)).

## SwiftUICropView → ImageEditorCanvas

`SwiftUICropView` is now `ImageEditorCanvas`. It edits an
`ImageEditorDocument` through a binding instead of the stack's edit:

- `init(editingStack:isGuideInteractionEnabled:areAnimationsEnabled:contentInset:stateHandler:)`
  and the variant with `cropInsideOverlay`/`cropOutsideOverlay` take
  `document: Binding<ImageEditorDocument>` instead of `editingStack:`. The
  canvas prepares the document's source image itself, and a document of
  another image rebuilds it. `isGuideInteractionEnabled:` and
  `stateHandler:` are modifiers now (below).
- Changes made on the canvas (applied crops and brush strokes) are written
  to the document's `feature`. The canvas never commits; call
  `document.commit()` when a change should become an undo step.
- `editingTarget(_:)` with `ImageEditorCanvas.Target` (`.crop`, `.localBlur`,
  or `nil` to only view) replaces `featureFocus(_:)` and
  `CropViewFeatureFocus`. The target is the adjustment point: the feature the
  canvas edits while it shows the evaluated result. The seed effect of
  `CropViewFeatureFocus.masking(_:id:)` is gone: the first stroke creates
  `localBlur` with the default blur. To use another blur, set
  `document.feature.localBlur` yourself. The `.localBlur` target paints
  only while `document.feature.isLocalBlurPaintable` is true (no blur, or a
  plain `.brush` mask); with any other mask it views the output, as `nil`
  does, and a stroke in progress is cancelled. Disable your own brush
  controls the same way, and keep a way to remove the blur.
- Renamed members: `adjustmentAngle(_:)` is `straightenAngle(_:isEditing:)`,
  `croppingAspectRatio(_:)` is `lockedAspectRatio(_:)` (taking an
  `AspectRatio`), and `SwiftUICropView.AdjustmentKind` is `CropInteraction`
  (`.scrollView` is `.movingImage`, `.guide` is `.resizingGuide`).
- `CropInteraction` has one idle value, the empty set. The
  `cropInsideOverlay` and `cropOutsideOverlay` builders take a
  `CropInteraction` instead of an `AdjustmentKind?`: where you matched
  `nil`, test `isEmpty`. `CropGuide.interaction` is the same value.
- `CropInteraction` holds every interaction in progress. In 5.1.1 the
  overlays and `StateSnapshot.adjustmentKind` received only the latest
  one, and the first to end reported idle: moving the image while resizing
  the guide, then lifting one finger, reported idle while the other kept
  going, and a finger still panning after a pinch ended was reported idle
  too. Now both overlap as `[.movingImage, .resizingGuide]`, and the set is
  empty only when the last one ends. `resetCrop()` ends an image move in
  progress (the overlays hear it too), and a guide resize continues until
  its gesture ends; in 5.1.1 a reset reported idle in both cases without
  telling the overlays.
- `straightenAngle(_:isEditing:)` and `lockedAspectRatio(_:)` take values
  only; the `Binding` forms are removed, and the canvas no longer writes
  its angle, turn, or lock back to your state. Follow them through
  `onCropGuideChange(_:)`: `pendingCrop.straightenRadians`,
  `pendingCrop.quarterTurn`, and `lockedAspectRatio`.
- A value input now takes effect only when your value changes from the
  previous update. In 5.x the canvas applied it on every update, so a
  constant such as `.adjustmentAngle(.zero)` pulled the canvas back after
  every undo, and `croppingAspectRatio(_:)` relocked the guide after a
  reset. Now the canvas keeps what a reset, a turn, or an undo did until
  you pass a different value. To lock again after a reset, pass `nil` and
  then the ratio, or mirror `CropGuide.lockedAspectRatio` into your state
  so the ratio you pass changes.
- `rotation(_:)` is removed. Turn the output with the proxy's
  `rotateCounterclockwise()` (below) and read the turn from
  `CropGuide.pendingCrop.quarterTurn`.
- `ResetAction`, `RotateAction`, and `ApplyAction`, with
  `registerResetAction(_:)`, `registerRotateAction(_:)`, and
  `registerApplyAction(_:)`, are replaced by `ImageEditorCanvasReader`,
  which works like `ScrollViewReader`: put the canvas and your controls in
  its content, and call the `ImageEditorCanvasProxy` it passes.
  `resetCrop()`, `rotateCounterclockwise()`, and `applyPendingCrop()` do
  what calling the three actions did. `applyPendingCrop()` still writes the
  crop to your binding before it returns, so
  `canvas.applyPendingCrop(); document.commit()` puts the crop in the undo
  step. A command before the canvas is mounted still does nothing. With
  several canvases under one reader, commands go to the one mounted most
  recently; an action registered on two canvases went to the one SwiftUI
  updated last.
- `stateHandler:` is the `onCropGuideChange(_:)` modifier, and
  `StateSnapshot` is `ImageEditorCanvas.CropGuide`:

  | 5.1.1 `StateSnapshot` | 6.0 `CropGuide` |
  | --- | --- |
  | `proposedCrop` (a `CropEditingState`) | `pendingCrop`, a `CropFeature?`: the crop Apply writes, pixel-aligned, in the same y-up coordinates as `document.feature.crop`. The output size is `pendingCrop.outputGeometry(in: .zero).outputBounds.size`; `proposedCrop.cropExtent` was the selection before the quarter turn, so its width and height were exchanged for a sideways crop. |
  | `frame` | `canvasBounds`: the canvas's size with a zero origin, in the canvas's own coordinates. `frame` was the canvas's frame in a view SwiftUI owns, and a change of size alone was not reported, so the snapshot delivered on mount could carry a zero frame. A change of size is now reported. |
  | `adjustmentKind` | `interaction` (`CropInteraction`) |
  | `preferredAspectRatio` | `lockedAspectRatio`, the name of the modifier that sets it |

  The callback no longer runs inside a SwiftUI view update, so it can write
  to `@State`. A change made while SwiftUI updates the canvas (mounting it,
  displaying a new document such as an undo, or applying an input) now
  arrives on the next main-actor turn instead of during `makeUIView` or
  `updateUIView`, and only the latest such change arrives. A change of the
  canvas's size, reported from layout, arrives the same way. A change from a
  gesture or a command still arrives before the call returns. A guide equal
  to the last one reported is not reported again.
- `isGuideInteractionEnabled:` is the `cropGuideDisabled(_:)` modifier,
  with the opposite value: `isGuideInteractionEnabled: false` is
  `.cropGuideDisabled()`.
- `AdjustmentAngleCommitAction` and
  `registerAdjustmentAngleCommitAction(_:)` are removed. Pass
  `isEditing: true` to `straightenAngle(_:isEditing:)` while a control
  changes the angle, and `false` when it ends: the canvas shows the angle
  without recording the crop while editing, and records the crop at the
  final angle when the edit ends, as the commit action did. The commit
  action recorded before it returned; the end of the edit reaches the
  canvas on its next update. `applyPendingCrop()` records an edit still in
  progress at the angle on screen first, so ending the edit and applying
  in the same action writes the recorded crop when the final angle is the
  one last shown. In 5.x registering the action also stopped every
  `adjustmentAngle(_:)` value from recording; now only `isEditing` does.
- `maskingBrush(_:)` and `strokeSmoothing(_:)` are one `brush(_:)`.
  `CropViewMaskingBrush` is `ImageEditorCanvas.Brush`, and the smoothing
  configuration is its `smoothing` member: `.off`, `.bezier(strength:)`,
  `.catmullRom(strength:)`, or `.movingAverage(strength:)` (the default is
  `.bezier(strength: 0.85)`).
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

Commands, before:

```swift
// Brightroom 5.x
@State private var applyAction = SwiftUICropView.ApplyAction()

SwiftUICropView(editingStack: editingStack)
  .registerApplyAction(applyAction)
Button("Apply") { applyAction() }
```

After:

```swift
import BrightroomEngine
import BrightroomUI
import SwiftUI

struct CropEditor: View {
  @Binding var document: ImageEditorDocument

  var body: some View {
    ImageEditorCanvasReader { canvas in
      VStack {
        ImageEditorCanvas(document: $document)
        HStack {
          Button("Rotate") { canvas.rotateCounterclockwise() }
          Button("Apply") {
            canvas.applyPendingCrop()
            document.commit()
          }
        }
      }
    }
  }
}
```

## InitialCrop Replaces CropModifier

`EditingStack.CropModifier` is now `InitialCrop` in BrightroomUI. It runs
once, when you create a document with
`await ImageEditorDocument(source:initialCrop:)`, and never for a document
you rebuild from saved values. Its crop is the document's committed state, so
undo does not return to the full-image crop.

- `CropModifier(modify:)` is `InitialCrop(_:)`. The closure is `async` and
  `@Sendable`, and returns the crop instead of calling a completion:
  `@Sendable (InitialCrop.Input) async -> CropFeature`. `Input` carries what
  the 5.x closure received: `image` (a downsampled preview scaled up to the
  image's size, with a zero origin), `imageSize` (the oriented pixel size),
  and `crop` (the whole image). The closure runs off the main actor, so the
  state it captures must be `Sendable`; move blocking work to your own
  queue, as `faceDetection` does.
- The document snaps the returned crop to whole pixels inside the image with
  `CropFeature.pixelAligned(imageSize:)`.
- `.faceDetection(paddingBias:aspectRatio:)` takes an `AspectRatio`.
  `.fullImage` keeps the whole image, and `.aspectRatio(_:)` starts from the
  largest centered crop of a ratio. None of them locks the ratio in the
  editor; use `ImageEditor.Options.aspectRatioPolicy` for that.

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
    initialCrop: .faceDetection(aspectRatio: .square)
  )
}

let squareCrop = InitialCrop.aspectRatio(.square)

let portraitCrop = InitialCrop { input in
  input.crop.fitted(to: AspectRatio(width: 4, height: 5), imageSize: input.imageSize)
}
```

## Crop Rectangles and Output Rotation

`CropFeature` evaluates straighten → crop → exact quarter turn. `rect`
(5.x `cropRect`), `topLeftRect(imageSize:)`, and
`CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)` describe
the selection after straightening and before the quarter turn. In 5.1.0 they described the frame in the output
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
  `CropFeature.fitted(to:imageSize:)`, the canvas's `lockedAspectRatio(_:)`,
  and `InitialCrop.faceDetection(aspectRatio:)`. A locked ratio turns with
  the output without refitting the selection.
- Crops keep the requested canvas at every rotation; parts outside the input
  are transparent. Quarter turns no longer trim a row or column to even out
  the dimensions, so odd sizes keep every pixel.
- New API: `CropFeature.outputGeometry(in:)`, which returns
  `CropFeature.OutputGeometry` (`outputBounds`, `inputToOutputTransform`);
  `CropFeature.pixelAligned(imageSize:)`, which snaps a crop to whole pixels
  inside its input as `CropFeature(topLeftRect:…)` does;
  `CropFeature.fitted(to:imageSize:)`, the largest centered selection of an
  output aspect ratio; and `QuarterTurn.isSideways`.
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

## CropEditingState Is No Longer Public

`CropEditingState` is BrightroomUI's internal crop-guide state now. The crop
values you use are `CropFeature`, `QuarterTurn`, and `AspectRatio`.
`CropFeature.rect` is y-up (bottom-left origin) while
`CropEditingState.cropExtent` was y-down, so a rectangle passed from one to
the other compiled and selected the wrong area.

| 5.1.1 | 6.0 |
| --- | --- |
| `CropEditingState(cropFeature:imageSize:)`, `makeCropFeature()` | The `CropFeature` itself |
| `cropExtent` | `CropFeature.topLeftRect(imageSize:)` (y-down) or `rect` (y-up) |
| `rotation` | `CropFeature.quarterTurn` |
| `adjustmentAngle` | `CropFeature.straightenRadians`; `Angle(radians:)` converts it |
| `updateCropExtent(toFitAspectRatio:)`, `updateCropExtentIfNeeded(toFitAspectRatio:)` | `CropFeature.fitted(to:imageSize:)` |
| `updateCropExtent(_:)` | `CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)` |
| `updateCropExtent(toFitBoundingBox:respectingApectRatio:)` | `InitialCrop.faceDetection(paddingBias:aspectRatio:)`, or your own rectangle fitted to the ratio and aligned in the order the `fittingRect` row of [Crop Conversions](#crop-conversions) gives |
| `makeInitial()` | `CropFeature(rect: CGRect(origin: .zero, size: imageSize))` |
| `isRenderingEquivalent(to:)` | `CropFeature.isPixelEquivalent(to:imageSize:)` |
| `id` | None ([Removed Identity and Flags](#removed-identity-and-flags)) |
| `imageSize`, `_usedAspectRatio`, `aggregatedRotation`, `purgeAspectRatio()` | None. Lock a ratio on the canvas with `lockedAspectRatio(_:)`. |
| `CropEditingState.Rotation`, `CropEditingState.AdjustmentAngle` | `QuarterTurn`, `Angle` |

Assign `document.feature.crop` directly. The canvas and `InitialCrop` write
pixel-aligned crops, but a crop you assign is rendered as given: fractional
edges are resampled and parts outside the image are transparent. Create it
with `fitted(to:imageSize:)` or `CropFeature(topLeftRect:…)`, or call
`pixelAligned(imageSize:)` on it.

Before:

```swift
// Brightroom 5.x
var crop = CropEditingState(cropFeature: feature.crop, imageSize: imageSize)
crop.updateCropExtent(toFitAspectRatio: .square)
feature.crop = crop.makeCropFeature()
```

After:

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI

func squareDocument(for source: SourceImage) -> ImageEditorDocument {
  var document = ImageEditorDocument(source: source)
  document.feature.crop = document.feature.crop.fitted(
    to: .square,
    imageSize: source.pixelSize
  )
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
| `ParametricExportRenderer.render(source:document:options:device:)` | `ExportRenderer.render(from:feature:options:)`, which renders like `device: .automatic`. See [Helpers No Longer Public](#helpers-no-longer-public). |
| `ParametricExportRenderer.Options(workingFormat:workingColorSpace:)`, `.workingFormat`, `.workingColorSpace` | `ExportRenderer.Options(outputFormat:outputColorSpace:)`, `.outputFormat`, `.outputColorSpace`. They were always the output format and the output color-space tag; processing runs in a half-float working space either way. |
| `ParametricExportRenderer.ExportFileType` | `ExportRenderer.FileType` |
| `ParametricExportRenderer.RenderingDevice` | Not public. See [Helpers No Longer Public](#helpers-no-longer-public). |
| `ParametricExportRenderer.RenderingError` | `ExportRendererError` |
| `ParametricExportRenderer.Rendered` | `RenderedImage` |
| `ParametricExportRenderer.Rendered.swiftUIImage` | Removed. `Image(decorative: try rendered.cgImage, scale: 1, orientation: .up)` |
| `ParametricVideoRenderer` | `VideoRenderer` |
| `ParametricVideoRenderer.makeFrameImage(from:feature:renderExtent:presentationTime:)` | `VideoRenderer.makeImage(from:feature:renderExtent:presentationTime:)` |
| `ParametricVideoRenderer.resolveRenderSize(sourceRenderSize:document:mode:)` | Not public. See [Helpers No Longer Public](#helpers-no-longer-public). |
| `ParametricVideoRendererError` | `VideoRendererError` |
| `FeatureEvaluationContext.radiusReferenceExtent`, `radiusBasis(for:)` | `FeatureEvaluationContext.chainEntryExtent`, `chainEntryExtent(for:)` |
| `FeatureEvaluationContext(radiusReferenceExtent:presentationTime:)`, `withRadiusReferenceExtent(_:)` | Not public. Pass `chainEntryExtent:` to `FeatureRenderer.makeImage`. See [Helpers No Longer Public](#helpers-no-longer-public). |
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

An image in a color space that is not RGB, such as a grayscale JPEG, now
exports. 5.1.1 tagged the result with the source's own
space, which Core Image cannot use for RGB pixels, so every render of such an
image with the default options failed. 6.0 tags an RGB result with sRGB
when the source's space (or `outputColorSpace`) is not RGB. A luminance
`outputFormat` such as `.L8` works the other way round: it keeps a gray
space and tags anything else with Generic Gray Gamma 2.2, where 5.1.1 failed.
RGB sources and RGB `outputColorSpace` values are tagged as before.

`Output.file` now stores the depth `outputFormat` asks for when the file type
can. 5.1.1 always wrote 8 bits per component and still reported the requested
format in `Rendered.options`. In 6.0 a format deeper than 8 bits, such as
`.RGBA16` or `.RGBAh`, is stored with 16 bits per component in a PNG and 10 in
a HEIF; JPEG stays at 8. That holds for every format whose `.memory` result
has more than 8 bits per component, including `.RGBX16`, `.rgbXh`, and
`.rgbXf`. No file type stores floating-point components, so values outside
0...1 are clamped as before. `RenderedImage.options.outputFormat`
reports the format the file stores (`.RGBA8`, `.RGBA16`, or `.RGB10`), which
can differ from the requested one; the default `.BGRA8` is now reported as
`.RGBA8`. `.memory` delivers and reports the requested format as before. A
16-bit write uses a scratch file of 8 bytes per pixel on disk, twice that of an
8-bit one. A PNG or JPEG write has the same peak memory at either depth, but
Image I/O's HEIF encoder holds the whole frame, and a 10-bit HEIF needs about
twice the memory of an 8-bit one (469MB against 255MB at 6000², measured on
macOS). Keep `.BGRA8` for very large HEIF exports.

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
| `GaussianBlurRadius` | `EffectRadius` |
| `GaussianBlurFeature(radius: Double)`, `GaussianBlurFeature(value:)` | `GaussianBlurFeature(radius: .absolute(_:))`, `GaussianBlurFeature(radius: .proportional(_:))` |
| `TemperatureFeature(value:tint:)`, `.value` | `WhiteBalanceFeature(temperature:tint:)`, `.temperature` |
| `ExposureFeature(value:)`, `.value` | `ExposureFeature(ev:)`, `.ev` |
| `SharpenFeature(sharpness:radius:)`, `.sharpness` | `SharpenFeature(intensity:radius:)`, `.intensity` |
| `ParametricRGBAColor` | `HighlightShadowTintFeature.Color` |

Library types that conform to `Feature` end in `Feature`. Values that are not
features (`Mask`, `BrushMask`, `QuarterTurn`, `EffectRadius`) have no suffix,
and a value type used by only one feature is nested in it
(`HighlightShadowTintFeature.Color`, `BrushMask.Stroke`).

### Filters and Color Cubes

| 5.1.1 | 6.0 |
| --- | --- |
| `PresetFeature(name:identifier:effects:)`, `.identifier` | `FilterFeature(name:id:effects:)`, `.id` (`Identifiable`) |
| `ColorCubeFeature.identifier`, `.amount` | `ColorCubeFeature.id`, `.intensity` |
| `ColorCubeFeature(cubeImageAt:…)` | `ColorCubeFeature(contentsOfCubeImage:…)` |
| `ColorCubeFeature.inferCubeDimension(width:height:)` | Removed from the public API. The image loaders infer the dimension when you pass `dimension: nil`. |
| `ColorCubeFeatureLoadingError` | `ColorCubeLoadingError` |
| `.failedToCreateImage(_:)`, `.missingLUT3DSize`, `.invalidLUT3DSize(_:line:)` | `.unreadableImage(_:)`, `.missingCubeSize`, `.invalidCubeSize(_:line:)` |
| `FeatureGraphCompilerError.invalidColorCubeData(FeatureID, …)` | `FeatureEvaluationError.invalidColorCubeData(id:…)`, where `id` is the cube's `id`. See [Errors](#errors). |
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
| `ColorMixerRenderIdentity.semanticVersion` | Not public; `==` on `RenderKey` still includes it |

### Metal Library

| 5.1.1 | 6.0 |
| --- | --- |
| `BrushStampMetalLibrary`, `BrushStampMetalLibraryError` | Not public. Brightroom loads its own kernels; a kernel that cannot load throws `FeatureEvaluationError.kernelUnavailable(name:reason:)`. |

## Renamed Engine API

BrightroomEngine keeps the document and its source image. Crop value types
moved next to `CropFeature` in BrightroomParametric, so add
`import BrightroomParametric` where you name them.

### Aspect Ratio

"Pixel aspect ratio" names the shape of one pixel
(`AVVideoPixelAspectRatioKey`), not the proportion of an image or a crop.

| 5.1.1 | 6.0 |
| --- | --- |
| `PixelAspectRatio` (BrightroomEngine) | `AspectRatio` (BrightroomParametric) |
| `PixelAspectRatio._minimized()`, `._comparingValue` | Not public. See [Helpers No Longer Public](#helpers-no-longer-public). |

### Crop Conversions

The y-down conversions and the pixel-grid comparison were extensions that
BrightroomEngine added to `CropFeature`. They are now part of `CropFeature`
in BrightroomParametric. "Display" is kept for the viewport, and the
comparison checks the pixels a crop selects, not how it renders.
`CropGeometry` is no longer public; `CropFeature` covers what hosts used it
for.

| 5.1.1 | 6.0 |
| --- | --- |
| `CropFeature(id:isEnabled:displayCropRect:imageSize:rotation:straighten:)` | `CropFeature(topLeftRect:imageSize:quarterTurn:straightenRadians:)` |
| `CropFeature.displayCropRect(imageSize:)` | `CropFeature.topLeftRect(imageSize:)` |
| `CropFeature.isRenderingEquivalent(to:orientedImageSize:)` | `CropFeature.isPixelEquivalent(to:imageSize:)` |
| `CropEditingState.isRenderingEquivalent(to:)` | `CropFeature.isPixelEquivalent(to:imageSize:)` ([CropEditingState](#cropeditingstate-is-no-longer-public)) |
| `CropGeometry.cropRect(toFitAspectRatio:in:)` | `CropFeature.fitted(to:imageSize:)` (the ratio describes the output) |
| `CropGeometry.fittingRect(rect:in:respectingAspectRatio:)`, `fittingRect(rect:in:straightenRadians:respectingAspectRatio:)` | `CropFeature.pixelAligned(imageSize:)`, which clips the selection (or fits its straightened footprint) to the image. To keep a ratio, fit it the way 5.1.1 did before aligning: without straightening, intersect your rectangle with the image (`rect.intersection(CGRect(origin: .zero, size: imageSize))`) and then fit the ratio into the result with `AspectRatio.rectThatFits(in:)`; with straightening, fit the ratio into your rectangle. Fitting the ratio first and letting `pixelAligned` clip a rectangle that extends past the image loses the ratio. |
| `CropGeometry.rect(_:turnedBy:)` | None. For a sideways turn, exchange the width and height about the same center. |
| `CropGeometry.cropRect(toFitBoundingBox:within:in:respectingAspectRatio:)` | `InitialCrop.faceDetection(paddingBias:aspectRatio:)`, or your own rectangle fitted to the ratio and aligned in the order the `fittingRect` row gives |

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
| Dispatch queue labels `app.muukii.Brightroom.EditingStack`, `…EditingStack.central` | None. The preview is prepared in a Swift concurrency task, not on a named dispatch queue. |

## Helpers No Longer Public

Some public symbols existed only so Brightroom's own modules could share
code. In 6.0 they are package access (visible only inside the Brightroom
package), internal, or removed. None of them has a public replacement with
the same shape; the table says what to use instead.

| 5.1.1 | 6.0 |
| --- | --- |
| `FeatureEvaluationContext(kernelRegistry:radiusReferenceExtent:presentationTime:)`, `withRadiusReferenceExtent(_:)` | Package access. Evaluate a feature with `FeatureRenderer().makeImage(from:feature:chainEntryExtent:presentationTime:)`, which moves the source to zero origin and builds the context. A feature still reads `chainEntryExtent`, `chainEntryExtent(for:)`, and `presentationTime`, and passes the context it receives on to the features it evaluates. |
| `ParametricExportRenderer.RenderingDevice` and the `device:` parameter of `render(source:document:options:device:)` | Package access. `ExportRenderer.render(from:feature:options:)` does what `.automatic` did: it renders on the GPU, and asks Core Image for its software renderer when the image exceeds the GPU context's size limits. On iOS 26 (checked on the Simulator) that renderer also runs on Metal and reports the same limits, so it does not raise them. |
| `ParametricVideoRenderer.resolveRenderSize(sourceRenderSize:document:mode:)` | Package access. `VideoRenderer.makeVideoComposition(for:feature:renderSizeMode:ciContext:)` resolves the size. To compute it yourself, read the extent of `FeatureRenderer().makeImage(from:feature:)` over a transparent image of the source size. |
| `ColorMixerRenderIdentity.semanticVersion` | Internal. Two `ColorMixerFeature.RenderKey` values still compare unequal when the semantics differ. |
| `BrushStampMetalLibrary`, `BrushStampMetalLibraryError` | Package access. A kernel that cannot load throws `FeatureEvaluationError.kernelUnavailable(name:reason:)`. |
| `PixelAspectRatio._minimized()`, `._comparingValue` | Package access (`AspectRatio.reduced()`) and private. Compare ratios with `==`; for lowest terms, divide the width and height by their greatest common divisor. |
| `Geometry` (BrightroomEngine) | Internal, and its aspect-fit, aspect-fill, and diagonal helpers are removed. For a fit, use `AspectRatio(size).sizeThatFits(in:)` and `rectThatFits(in:)`, which do not round the size up. A fill has no public replacement: scale the ratio by the larger of `width / ratio.width` and `height / ratio.height`, and center it (`rectThatAspectFill` ignored the rectangle's origin). For `sizeThatAspectFit(size:maxPixelSize:)`, decode at that size with `SourceImage.makeCIImage(maxPixelSize:)`, or scale by `min(1, maxPixelSize / max(width, height))` and round. |
| `CIImage.removingExtentOffset()` (BrightroomEngine) | Removed. `image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))`. `FeatureRenderer` already does this to the image you pass. |
| `Optional.BrightroomUnwrappedNilError` (BrightroomEngine) | Internal. No public API threw it. |
| `_BrightroomDebounce` (BrightroomEngine) | Removed. Use a `Task` you cancel and restart, or your own timer. |
| `SwiftUIMetalImageView`, `ImageDisplayBackground` (BrightroomUI) | Removed. The editor never used them. Show a rendered image with `Image(decorative: try rendered.cgImage, scale: 1, orientation: .up)`, or copy the demo app's view (`Dev/Sources/SwiftUIDemo/MetalImageView.swift`), which draws a `CIImage` with Metal. |

`ToneCurveEvaluator`, `ToneCurveFeature.semanticVersion`, and
`CropFeature.outputGeometry(in:)` stay public: a host can draw the curve a
tone curve renders, store the curve semantics it saved, and size a crop's
output.

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
- [ ] Canvas commands go through `ImageEditorCanvasReader`, state you
      mirrored through bindings or `stateHandler` comes from
      `onCropGuideChange(_:)`, and code that relied on a value input
      being applied on every update passes a changed value instead.
- [ ] Code that used `CropEditingState` or `CropGeometry` works on
      `CropFeature`, and crops you assign are pixel-aligned.
- [ ] An `InitialCrop` is passed to `await ImageEditorDocument(source:initialCrop:)`
      instead of a `CropModifier` to `EditingStack`.
- [ ] Filters are supplied through `options.filters`.
- [ ] LUTs are loaded with the `ColorCubeFeature` loaders instead of
      `ColorCubeLoader`, `ColorCubeHelper`, or `PresetStorage`, each LUT has
      a unique `id`, and wide-gamut LUT images are checked again.
- [ ] Tone Curve and Color Mixer output rendered outside `ExportRenderer`,
      such as video through `VideoRenderer`'s default context, is checked
      again: it now matches the export
      ([Tone Curve and Color Mixer](#tone-curve-and-color-mixer)).
- [ ] Code that showed `FeatureTreeView` puts `FeatureTreeOutline` from
      BrightroomUI in a `List`, and code that read `swiftUIImage` builds
      `Image(decorative:scale:orientation:)` from `cgImage`.
- [ ] Code that built a `FeatureEvaluationContext`, passed `device:` to an
      export, or used `Geometry`, `SwiftUIMetalImageView`, or another helper
      in [Helpers No Longer Public](#helpers-no-longer-public) uses the
      public API listed there.
- [ ] The renames in [Name Changes at a Glance](#name-changes-at-a-glance)
      are applied, including `QuarterTurn` case names and log filters.
- [ ] Crop rectangles are selections before the quarter turn; rectangles
      saved by 5.1.0 with a sideways rotation are converted.
- [ ] Loading, crop, filters, adjustments, blur mask, undo, reopening, and
      final rendering are tested again.
