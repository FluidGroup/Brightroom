//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreGraphics
import Foundation

/// A stable identifier for a parametric editing feature or mask node.
///
/// Feature identifiers are stored in documents so debug views, UI selections,
/// and future references can survive Codable round trips.
public struct FeatureID: Codable, Equatable, Hashable, Sendable {

  /// The serialized identifier value.
  public var rawValue: String

  /// Creates an identifier with the provided serialized value.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Creates a new unique identifier.
  public init() {
    self.rawValue = UUID().uuidString
  }
}

/// A serializable parametric operation that can appear in an editing document.
///
/// Concrete feature enums use this protocol to expose common identity and
/// enabled-state behavior without storing protocol existentials in documents.
public protocol Feature: Codable, Equatable, Sendable {

  /// The stable identity of this feature.
  var id: FeatureID { get }

  /// A Boolean value indicating whether the feature contributes to rendering.
  var isEnabled: Bool { get }
}

/// A parametric image editing document.
///
/// The document intentionally stores edit parameters only. The source image is
/// supplied to the compiler so the same document can be evaluated for preview,
/// export, or debugging without baking pixels into the model.
public struct EditingDocument: Codable, Equatable, Sendable {

  /// The ordered main feature tree evaluated from source image to output image.
  public var mainTree: MainTree

  /// Creates a document with the provided main tree.
  public init(mainTree: MainTree = .init()) {
    self.mainTree = mainTree
  }
}

/// The main editing sequence for a document.
///
/// Main-tree features are evaluated in array order. Domain-changing features
/// such as crop are allowed here, while local adjustment subtrees are restricted
/// to extent-preserving operations.
public struct MainTree: Codable, Equatable, Sendable {

  /// The features evaluated in source-to-output order.
  public var features: [MainFeature]

  /// Creates a main tree with the provided ordered features.
  public init(features: [MainFeature] = []) {
    self.features = features
  }
}

/// A feature that can appear in the document's main tree.
public enum MainFeature: Codable, Equatable, Sendable {

  /// A feature that may change image extent or coordinate domain.
  case domain(DomainFeature)

  /// A global, extent-preserving image effect.
  case effect(ImageEffectFeature)

  /// A local branch that composites an effect pipeline through a mask tree.
  case localAdjustment(LocalAdjustmentFeature)
}

extension MainFeature: Feature {

  public var id: FeatureID {
    switch self {
    case let .domain(feature):
      feature.id
    case let .effect(feature):
      feature.id
    case let .localAdjustment(feature):
      feature.id
    }
  }

  public var isEnabled: Bool {
    switch self {
    case let .domain(feature):
      feature.isEnabled
    case let .effect(feature):
      feature.isEnabled
    case let .localAdjustment(feature):
      feature.isEnabled
    }
  }
}

/// A main-tree feature that may change the current image domain.
///
/// Domain features are deliberately excluded from local adjustment subtrees.
/// This makes crop and future geometry correction semantics explicit.
public enum DomainFeature: Codable, Equatable, Sendable {

  /// Crops the current domain and resets the resulting image to zero origin.
  case crop(CropFeature)
}

extension DomainFeature: Feature {

  public var id: FeatureID {
    switch self {
    case let .crop(feature):
      feature.id
    }
  }

  public var isEnabled: Bool {
    switch self {
    case let .crop(feature):
      feature.isEnabled
    }
  }
}

/// A crop in the current main-tree domain.
///
/// The crop rectangle is interpreted relative to the image produced by the
/// previous main-tree feature. A second crop therefore crops the already-cropped
/// output of the first crop.
public struct CropFeature: Feature {

  /// The stable identity of this crop.
  public var id: FeatureID

  /// A Boolean value indicating whether this crop participates in rendering.
  public var isEnabled: Bool

  /// The rectangle to keep, expressed in the current domain.
  public var cropRect: CGRect

  /// Creates a current-domain crop feature.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    cropRect: CGRect
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.cropRect = cropRect
  }
}

/// An extent-preserving image effect.
///
/// Image effects can appear directly in the main tree or inside a local
/// adjustment effect pipeline.
public enum ImageEffectFeature: Codable, Equatable, Sendable {

  /// Applies a named group of image effects.
  case preset(PresetFeature)

  /// Applies a color-cube lookup table.
  case colorCube(ColorCubeFeature)

  /// Adjusts luminance using Core Image color controls.
  case brightness(BrightnessFeature)

  /// Adjusts contrast using Core Image color controls.
  case contrast(ContrastFeature)

  /// Adjusts saturation using Core Image color controls.
  case saturation(SaturationFeature)

  /// Adjusts exposure value.
  case exposure(ExposureFeature)

  /// Recovers highlight values using Core Image highlight/shadow adjustment.
  case highlights(HighlightsFeature)

  /// Opens shadow values using Core Image highlight/shadow adjustment.
  case shadows(ShadowsFeature)

  /// Blends separate tint colors over highlight and shadow regions.
  case highlightShadowTint(HighlightShadowTintFeature)

  /// Adjusts color temperature.
  case temperature(TemperatureFeature)

  /// Sharpens luminance using Core Image sharpen luminance.
  case sharpen(SharpenFeature)

  /// Applies a Gaussian blur while preserving the input extent.
  case gaussianBlur(GaussianBlurFeature)

  /// Applies an unsharp mask.
  case unsharpMask(UnsharpMaskFeature)

  /// Applies a vignette.
  case vignette(VignetteFeature)

  /// Blends white over the input image.
  case fade(FadeFeature)
}

extension ImageEffectFeature: Feature {

  public var id: FeatureID {
    switch self {
    case let .preset(feature):
      feature.id
    case let .colorCube(feature):
      feature.id
    case let .brightness(feature):
      feature.id
    case let .contrast(feature):
      feature.id
    case let .saturation(feature):
      feature.id
    case let .exposure(feature):
      feature.id
    case let .highlights(feature):
      feature.id
    case let .shadows(feature):
      feature.id
    case let .highlightShadowTint(feature):
      feature.id
    case let .temperature(feature):
      feature.id
    case let .sharpen(feature):
      feature.id
    case let .gaussianBlur(feature):
      feature.id
    case let .unsharpMask(feature):
      feature.id
    case let .vignette(feature):
      feature.id
    case let .fade(feature):
      feature.id
    }
  }

  public var isEnabled: Bool {
    switch self {
    case let .preset(feature):
      feature.isEnabled
    case let .colorCube(feature):
      feature.isEnabled
    case let .brightness(feature):
      feature.isEnabled
    case let .contrast(feature):
      feature.isEnabled
    case let .saturation(feature):
      feature.isEnabled
    case let .exposure(feature):
      feature.isEnabled
    case let .highlights(feature):
      feature.isEnabled
    case let .shadows(feature):
      feature.isEnabled
    case let .highlightShadowTint(feature):
      feature.isEnabled
    case let .temperature(feature):
      feature.isEnabled
    case let .sharpen(feature):
      feature.isEnabled
    case let .gaussianBlur(feature):
      feature.isEnabled
    case let .unsharpMask(feature):
      feature.isEnabled
    case let .vignette(feature):
      feature.isEnabled
    case let .fade(feature):
      feature.isEnabled
    }
  }
}

/// A named group of extent-preserving effects.
///
/// This is the parametric equivalent of a filter preset. It stores concrete
/// supported effects rather than arbitrary `AnyFilter` values so the document
/// remains Codable and inspectable.
public struct PresetFeature: Feature {

  /// The stable identity of this preset feature.
  public var id: FeatureID

  /// A Boolean value indicating whether this preset participates in rendering.
  public var isEnabled: Bool

  /// The display name associated with the preset.
  public var name: String

  /// The stable preset identifier.
  public var identifier: String

  /// The effects evaluated inside the preset, in order.
  public var effects: [ImageEffectFeature]

  /// Creates a preset feature.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    name: String,
    identifier: String,
    effects: [ImageEffectFeature]
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.name = name
    self.identifier = identifier
    self.effects = effects
  }
}

/// A color-cube lookup-table effect.
///
/// The feature stores cube data directly so rendering can stay in the Core Image
/// graph without asking an `ImageSource` or bundle resource to materialize.
public struct ColorCubeFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The display name associated with the lookup table.
  public var name: String

  /// The stable lookup-table identifier.
  public var identifier: String

  /// The opacity used when compositing the color-cube result over its input.
  public var amount: Double

  /// The color-cube dimension.
  public var dimension: Int

  /// RGBA float cube data in `CIColorCubeWithColorSpace` layout.
  public var cubeData: Data

  /// Creates a color-cube effect.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    name: String,
    identifier: String,
    amount: Double = 1,
    dimension: Int,
    cubeData: Data
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.name = name
    self.identifier = identifier
    self.amount = amount
    self.dimension = dimension
    self.cubeData = cubeData
  }
}

/// A brightness adjustment.
public struct BrightnessFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The brightness value passed to `CIColorControls`.
  public var value: Double

  /// Creates a brightness adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// A contrast adjustment.
public struct ContrastFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The contrast offset passed to `CIColorControls` as `1 + value`.
  public var value: Double

  /// Creates a contrast adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// A saturation adjustment.
public struct SaturationFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The saturation offset passed to `CIColorControls` as `1 + value`.
  public var value: Double

  /// Creates a saturation adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// An exposure adjustment.
public struct ExposureFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The exposure value passed to `CIExposureAdjust`.
  public var value: Double

  /// Creates an exposure adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// A highlight recovery adjustment.
public struct HighlightsFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The highlight recovery value. It is applied as `1 - value`.
  public var value: Double

  /// Creates a highlight adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// A shadow lift adjustment.
public struct ShadowsFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The shadow amount passed to `CIHighlightShadowAdjust`.
  public var value: Double

  /// Creates a shadow adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// An RGBA color value stored inside a parametric feature document.
public struct ParametricRGBAColor: Codable, Equatable, Sendable {

  /// The red component in the Core Image working range.
  public var red: Double

  /// The green component in the Core Image working range.
  public var green: Double

  /// The blue component in the Core Image working range.
  public var blue: Double

  /// The alpha component in the Core Image working range.
  public var alpha: Double

  /// Creates an RGBA color value.
  public init(
    red: Double,
    green: Double,
    blue: Double,
    alpha: Double
  ) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

/// A highlight/shadow tint effect.
public struct HighlightShadowTintFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The color composited over highlight regions.
  public var highlightColor: ParametricRGBAColor

  /// The color composited over shadow regions.
  public var shadowColor: ParametricRGBAColor

  /// Creates a highlight/shadow tint adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    highlightColor: ParametricRGBAColor,
    shadowColor: ParametricRGBAColor
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.highlightColor = highlightColor
    self.shadowColor = shadowColor
  }
}

/// A color temperature adjustment.
public struct TemperatureFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The temperature offset from Brightroom's neutral value.
  public var value: Double

  /// Creates a temperature adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// A luminance sharpen adjustment.
public struct SharpenFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The sharpness value passed to `CISharpenLuminance`.
  public var sharpness: Double

  /// The Brightroom filter radius value, resolved against the current extent.
  public var radius: Double

  /// Creates a sharpen adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    sharpness: Double,
    radius: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.sharpness = sharpness
    self.radius = radius
  }
}

/// A Gaussian blur radius value.
public enum GaussianBlurRadius: Codable, Equatable, Sendable {

  /// A Core Image blur radius in image-domain points.
  case absolute(Double)

  /// A `FilterGaussianBlur.value` slider value, resolved against image extent.
  case editingStackFilterValue(Double)
}

/// A Gaussian blur that preserves the input extent.
public struct GaussianBlurFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The blur radius descriptor.
  public var radius: GaussianBlurRadius

  /// Creates a Gaussian blur.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    radius: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.radius = .absolute(radius)
  }

  /// Creates a Gaussian blur from `FilterGaussianBlur.value`.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.radius = .editingStackFilterValue(value)
  }
}

/// An unsharp mask adjustment.
public struct UnsharpMaskFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The intensity passed to `CIUnsharpMask`.
  public var intensity: Double

  /// The Brightroom filter radius value, resolved against the current extent.
  public var radius: Double

  /// Creates an unsharp mask adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    intensity: Double,
    radius: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.intensity = intensity
    self.radius = radius
  }
}

/// A vignette adjustment.
public struct VignetteFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The Brightroom vignette value used for both intensity and radius scaling.
  public var value: Double

  /// Creates a vignette adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
  }
}

/// A fade adjustment that overlays white.
public struct FadeFeature: Feature {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The opacity of the white overlay.
  public var intensity: Double

  /// Creates a fade adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    intensity: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.intensity = intensity
  }
}

/// An ordered chain of extent-preserving effects.
public struct EffectPipeline: Codable, Equatable, Sendable {

  /// The effects applied from first to last.
  public var effects: [ImageEffectFeature]

  /// Creates an effect pipeline.
  public init(effects: [ImageEffectFeature] = []) {
    self.effects = effects
  }
}

/// A local adjustment branch.
///
/// The branch evaluates an effect pipeline from the current main image, evaluates
/// a mask tree in the same current domain, and composites the adjusted image
/// back over the base image without changing extent.
public struct LocalAdjustmentFeature: Feature {

  /// The stable identity of this local adjustment.
  public var id: FeatureID

  /// A Boolean value indicating whether this local adjustment participates in rendering.
  public var isEnabled: Bool

  /// The mask tree that produces the alpha used for compositing.
  public var maskTree: MaskTree

  /// The extent-preserving effects applied inside the local branch.
  public var effectPipeline: EffectPipeline

  /// The blend rule used to composite the adjusted branch over the base image.
  public var blendMode: LocalAdjustmentBlendMode

  /// Creates a local adjustment branch.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    maskTree: MaskTree,
    effectPipeline: EffectPipeline,
    blendMode: LocalAdjustmentBlendMode = .alpha
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.maskTree = maskTree
    self.effectPipeline = effectPipeline
    self.blendMode = blendMode
  }
}

/// A blend rule for local adjustment output.
public enum LocalAdjustmentBlendMode: String, Codable, Equatable, Sendable {

  /// Uses the mask alpha to blend adjusted output over the base image.
  case alpha
}

/// A mask graph that produces alpha in the current feature domain.
public struct MaskTree: Codable, Equatable, Sendable {

  /// The root mask node.
  public var root: MaskNode

  /// Creates a mask tree.
  public init(root: MaskNode) {
    self.root = root
  }
}

/// A node in an alpha-only mask tree.
public indirect enum MaskNode: Codable, Equatable, Sendable {

  /// Produces alpha from brush strokes.
  case brush(BrushMask)

  /// Inverts the input alpha.
  case invert(MaskNode)

  /// Blurs the input alpha while preserving extent.
  case feather(MaskFeather)

  /// Combines child masks using alpha union.
  case union([MaskNode])

  /// Combines child masks using alpha intersection.
  case intersect([MaskNode])

  /// Removes one mask from another.
  case subtract(MaskSubtract)
}

/// A brush-authored mask.
public struct BrushMask: Feature {

  /// The stable identity of this mask leaf.
  public var id: FeatureID

  /// A Boolean value indicating whether this mask leaf contributes alpha.
  public var isEnabled: Bool

  /// The brush strokes authored in the current feature domain.
  public var strokes: [BrushMaskStroke]

  /// Creates a brush-authored mask.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    strokes: [BrushMaskStroke] = []
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.strokes = strokes
  }
}

/// A continuous brush stroke represented by sampled stamp centers.
public struct BrushMaskStroke: Codable, Equatable, Sendable {

  /// The stamp centers in current feature-domain coordinates.
  public var stamps: [CGPoint]

  /// The brush used to render each stamp.
  public var brush: BrushMaskBrush

  /// Creates a brush stroke.
  public init(
    stamps: [CGPoint],
    brush: BrushMaskBrush
  ) {
    self.stamps = stamps
    self.brush = brush
  }
}

/// Brush parameters for a mask stroke.
public struct BrushMaskBrush: Codable, Equatable, Sendable {

  /// The brush diameter in current feature-domain units.
  public var diameter: Double

  /// The hard inner alpha region, from `0` for soft to `1` for hard.
  public var hardness: Double

  /// The stamp opacity, from `0` to `1`.
  public var opacity: Double

  /// Creates brush parameters.
  public init(
    diameter: Double,
    hardness: Double,
    opacity: Double
  ) {
    self.diameter = diameter
    self.hardness = hardness
    self.opacity = opacity
  }
}

/// A mask feather operation.
public struct MaskFeather: Codable, Equatable, Sendable {

  /// The stable identity of this operation.
  public var id: FeatureID

  /// A Boolean value indicating whether this operation participates in rendering.
  public var isEnabled: Bool

  /// The input mask node to feather.
  public var input: MaskNode

  /// The blur radius used to feather alpha.
  public var radius: Double

  /// Creates a feather operation.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    input: MaskNode,
    radius: Double
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.input = input
    self.radius = radius
  }
}

/// A mask subtraction operation.
public struct MaskSubtract: Codable, Equatable, Sendable {

  /// The stable identity of this operation.
  public var id: FeatureID

  /// A Boolean value indicating whether this operation participates in rendering.
  public var isEnabled: Bool

  /// The mask to subtract from.
  public var base: MaskNode

  /// The mask removed from the base alpha.
  public var removing: MaskNode

  /// Creates a mask subtraction operation.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    base: MaskNode,
    removing: MaskNode
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.base = base
    self.removing = removing
  }
}
