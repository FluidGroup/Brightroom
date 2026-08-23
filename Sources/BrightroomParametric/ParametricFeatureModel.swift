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

/// A parametric operation that can appear in an editing document.
///
/// Features are pure parameter values. Evaluation behavior is added by
/// capability protocols (`ImageEffectFeatureType`, `DomainFeatureType`);
/// persistence is added by `PersistableFeature`. The runtime document is not
/// Codable by itself — serialization goes through `ParametricDocumentCodec`.
public protocol Feature: Equatable, Sendable {

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
public struct EditingDocument: Equatable, Sendable {

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
public struct MainTree: Equatable, Sendable {

  /// The features evaluated in source-to-output order.
  public var features: [MainFeature]

  /// Creates a main tree with the provided ordered features.
  public init(features: [MainFeature] = []) {
    self.features = features
  }
}

/// A feature that can appear in the document's main tree.
///
/// The effect and domain vocabularies are open: any type conforming to the
/// capability protocols can appear here, including host-defined features.
/// Local adjustments are a structural branch owned by the engine.
public enum MainFeature: Equatable, Sendable {

  /// A feature that may change image extent or coordinate domain.
  case domain(any DomainFeatureType)

  /// A global, extent-preserving image effect.
  case effect(any ImageEffectFeatureType)

  /// A local branch that composites an effect pipeline through a mask tree.
  case localAdjustment(LocalAdjustmentFeature)

  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case let (.domain(a), .domain(b)):
      return parametricFeatureIsEqual(a, b)
    case let (.effect(a), .effect(b)):
      return parametricFeatureIsEqual(a, b)
    case let (.localAdjustment(a), .localAdjustment(b)):
      return a == b
    default:
      return false
    }
  }
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

/// A quarter-turn rotation step applied by a crop feature.
///
/// Raw values are the signed degrees the engine uses (`EditingCrop.Rotation.angle`),
/// so the sign convention is identical and host bridges map 1:1. This is a pure
/// CoreGraphics/Foundation type with no SwiftUI dependency.
public enum QuarterTurn: Int, Codable, Equatable, Sendable, CaseIterable {

  /// No rotation (0°).
  case zero = 0

  /// A quarter turn (-90°), matching `EditingCrop.Rotation.angle_90`.
  case quarterCW = -90

  /// A half turn (-180°).
  case half = -180

  /// A three-quarter turn (-270°).
  case quarterCCW = -270

  /// The rotation expressed in radians.
  public var radians: Double {
    Double(rawValue) * .pi / 180
  }
}

/// A crop in the current main-tree domain.
///
/// The crop rectangle is interpreted relative to the image produced by the
/// previous main-tree feature. A second crop therefore crops the already-cropped
/// output of the first crop. The crop also carries the quarter-turn rotation and
/// the free straightening angle, both applied about the crop-rect center, so the
/// whole crop geometry is expressed as a single parametric feature.
public struct CropFeature: Feature, Codable {

  /// The stable identity of this crop.
  public var id: FeatureID

  /// A Boolean value indicating whether this crop participates in rendering.
  public var isEnabled: Bool

  /// The rectangle to keep, expressed in the current domain (Core Image
  /// bottom-left, y-up).
  public var cropRect: CGRect

  /// The quarter-turn rotation applied about the crop-rect center.
  public var rotation: QuarterTurn

  /// A free straightening angle in radians, applied about the crop-rect center
  /// in addition to `rotation`.
  public var straightenRadians: Double

  /// The combined rotation (quarter turn + straighten) in radians.
  public var aggregatedRotationRadians: Double {
    rotation.radians + (straightenRadians.isFinite ? straightenRadians : 0)
  }

  /// Creates a current-domain crop feature.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    cropRect: CGRect,
    rotation: QuarterTurn = .zero,
    straightenRadians: Double = 0
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.cropRect = cropRect
    self.rotation = rotation
    self.straightenRadians = straightenRadians
  }
}

/// A named group of extent-preserving effects.
///
/// This is the parametric equivalent of a filter preset. It stores typed
/// effect values so the document remains inspectable.
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
  public var effects: [any ImageEffectFeatureType]

  /// Creates a preset feature.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    name: String,
    identifier: String,
    effects: [any ImageEffectFeatureType]
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.name = name
    self.identifier = identifier
    self.effects = effects
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.isEnabled == rhs.isEnabled
      && lhs.name == rhs.name
      && lhs.identifier == rhs.identifier
      && parametricFeaturesAreEqual(lhs.effects, rhs.effects)
  }
}

/// A color-cube lookup-table effect.
///
/// The feature stores cube data directly so rendering can stay in the Core Image
/// graph without asking an `ImageSource` or bundle resource to materialize.
public struct ColorCubeFeature: Feature, Codable {

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
public struct BrightnessFeature: Feature, Codable {

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
public struct ContrastFeature: Feature, Codable {

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
public struct SaturationFeature: Feature, Codable {

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
public struct ExposureFeature: Feature, Codable {

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
public struct HighlightsFeature: Feature, Codable {

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
public struct ShadowsFeature: Feature, Codable {

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
public struct HighlightShadowTintFeature: Feature, Codable {

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

/// A two-axis white-balance adjustment evaluated by Core Image.
///
/// `value` shifts color temperature relative to Brightroom's neutral white
/// point, while `tint` moves the same white point along the green–magenta axis.
/// Keeping both values in one feature preserves the coupled semantics of
/// `CITemperatureAndTint` instead of approximating them as sequential filters.
public struct TemperatureFeature: Feature, Codable {

  /// The stable identity of this effect.
  public var id: FeatureID

  /// A Boolean value indicating whether this effect participates in rendering.
  public var isEnabled: Bool

  /// The color-temperature offset from Brightroom's neutral value, in Kelvin.
  public var value: Double

  /// The green–magenta tint offset from Brightroom's neutral value.
  public var tint: Double

  /// Creates a white-balance adjustment.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    value: Double,
    tint: Double = 0
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.value = value
    self.tint = tint
  }
}

/// A luminance sharpen adjustment.
public struct SharpenFeature: Feature, Codable {

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
public struct GaussianBlurFeature: Feature, Codable {

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
public struct UnsharpMaskFeature: Feature, Codable {

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
public struct VignetteFeature: Feature, Codable {

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
public struct FadeFeature: Feature, Codable {

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
public struct EffectPipeline: Equatable, Sendable {

  /// The effects applied from first to last.
  public var effects: [any ImageEffectFeatureType]

  /// Creates an effect pipeline.
  public init(effects: [any ImageEffectFeatureType] = []) {
    self.effects = effects
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    parametricFeaturesAreEqual(lhs.effects, rhs.effects)
  }

  // MARK: - Typed queries

  /// The first effect of the given type, if present.
  public func first<T: ImageEffectFeatureType>(of type: T.Type) -> T? {
    for effect in effects {
      if let typed = effect as? T {
        return typed
      }
    }
    return nil
  }

  /// The index of the first effect of the given type, if present.
  public func firstIndex<T: ImageEffectFeatureType>(of type: T.Type) -> Int? {
    effects.firstIndex(where: { $0 is T })
  }

  /// Replaces the first effect of `T` in place, removes it when `value` is
  /// nil, or inserts a new value when absent.
  ///
  /// Ordering is the caller's decision: `insertionIndex` resolves where a
  /// NEW effect goes (defaults to appending). An existing effect keeps its
  /// position.
  public mutating func set<T: ImageEffectFeatureType>(
    _ value: T?,
    insertionIndex: (EffectPipeline) -> Int = { $0.effects.count }
  ) {
    if let index = firstIndex(of: T.self) {
      if let value {
        effects[index] = value
      } else {
        effects.remove(at: index)
      }
    } else if let value {
      let index = min(max(insertionIndex(self), 0), effects.count)
      effects.insert(value, at: index)
    }
  }

  /// Whether the pipeline contains no effects.
  public var isEmpty: Bool {
    effects.isEmpty
  }
}

/// A main-tree effect node that bundles an ordered `EffectPipeline`.
///
/// This is the document representation of the editing stack's global-effects
/// node: it keeps the `EffectPipeline` editing vocabulary as a single,
/// identity-stable feature, while the compiler flattens it through
/// `childFeatures` exactly like `PresetFeature`.
public struct EffectPipelineFeature: Feature, Codable {

  /// The stable identity of this effect node.
  public var id: FeatureID

  /// A Boolean value indicating whether this node participates in rendering.
  public var isEnabled: Bool

  /// The ordered effects applied when this node evaluates.
  public var pipeline: EffectPipeline

  /// Creates an effect-pipeline feature.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    pipeline: EffectPipeline
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.pipeline = pipeline
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
public struct BrushMask: Feature, Codable {

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
