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

/// A quarter-turn rotation step applied by a crop feature.
///
/// Case names say which way the picture turns on screen. Raw values are
/// signed degrees in the y-down (UIKit) convention, where a negative angle
/// turns counterclockwise; they are stable, so hosts can store them. This is
/// a pure CoreGraphics/Foundation type with no SwiftUI dependency.
public enum QuarterTurn: Int, Equatable, Sendable, CaseIterable {

  /// No rotation (0°).
  case zero = 0

  /// A quarter turn counterclockwise on screen (-90°).
  case counterclockwise = -90

  /// A half turn (-180°).
  case halfTurn = -180

  /// A quarter turn clockwise on screen (-270°, three quarters
  /// counterclockwise).
  case clockwise = -270

  /// The rotation in radians, in the same y-down convention as the raw value.
  public var radians: Double {
    Double(rawValue) * .pi / 180
  }

  /// Whether the turn exchanges the output's horizontal and vertical axes.
  public var isSideways: Bool {
    switch self {
    case .counterclockwise, .clockwise:
      return true
    case .zero, .halfTurn:
      return false
    }
  }
}

/// A crop in the current domain.
///
/// The crop rectangle is interpreted relative to the image produced by the
/// previous feature. A second crop therefore crops the already-cropped
/// output of the first crop. Evaluation straightens the source, extracts the
/// crop, and then applies its quarter-turn rotation to the cropped output.
/// The stored rectangle describes the selection before that final turn;
/// changing `rotation` does not change the selected source area.
public struct CropFeature: Feature, Equatable {

  /// The rectangle to keep after straightening and before the output quarter
  /// turn, relative to the current input image's origin (bottom-left, y-up).
  ///
  /// Its size is the crop size. A sideways `rotation` exchanges only the final
  /// output dimensions; the selection rectangle remains unchanged.
  /// Regions outside the input are transparent. Pixel fitting is the caller's
  /// responsibility; evaluation does not shrink the requested canvas.
  public var cropRect: CGRect

  /// The quarter-turn rotation applied to the cropped output.
  public var rotation: QuarterTurn

  /// A free straightening angle in radians, applied about the crop-rect center
  /// before extracting the crop and applying `rotation`.
  public var straightenRadians: Double

  /// Creates a current-domain crop feature.
  public init(
    cropRect: CGRect,
    rotation: QuarterTurn = .zero,
    straightenRadians: Double = 0
  ) {
    self.cropRect = cropRect
    self.rotation = rotation
    self.straightenRadians = straightenRadians
  }
}

/// A named group of image effects, such as a filter preset.
///
/// The effects are decided by data (a catalog), so they are type-erased.
/// Equal presets compare equal; selection UIs compare `identifier`.
///
/// A preset is a composite: its `body` is its effects, evaluated in order.
/// Nest another preset with `AnyImageEffect(innerPreset)`.
public struct PresetFeature: ImageEffect, Equatable {

  /// The display name associated with the preset.
  public var name: String

  /// The stable preset identifier.
  public var identifier: String

  /// The effects evaluated inside the preset, in order.
  public var effects: [AnyImageEffect]

  /// Creates a preset feature.
  public init(
    name: String,
    identifier: String,
    effects: [AnyImageEffect]
  ) {
    self.name = name
    self.identifier = identifier
    self.effects = effects
  }

  public var body: [AnyImageEffect] {
    effects
  }
}

/// A color-cube lookup-table effect.
///
/// The feature stores cube data directly so rendering can stay in the Core Image
/// graph without asking an `ImageSource` or bundle resource to materialize.
public struct ColorCubeFeature: ImageEffect, Equatable {

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
    name: String,
    identifier: String,
    amount: Double = 1,
    dimension: Int,
    cubeData: Data
  ) {
    self.name = name
    self.identifier = identifier
    self.amount = amount
    self.dimension = dimension
    self.cubeData = cubeData
  }
}

/// A brightness adjustment.
public struct BrightnessFeature: ImageEffect, Equatable {

  /// The brightness value passed to `CIColorControls`.
  public var value: Double

  /// Creates a brightness adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A contrast adjustment.
public struct ContrastFeature: ImageEffect, Equatable {

  /// The contrast offset passed to `CIColorControls` as `1 + value`.
  public var value: Double

  /// Creates a contrast adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A saturation adjustment.
public struct SaturationFeature: ImageEffect, Equatable {

  /// The saturation offset passed to `CIColorControls` as `1 + value`.
  public var value: Double

  /// Creates a saturation adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// An exposure adjustment.
public struct ExposureFeature: ImageEffect, Equatable {

  /// The exposure value passed to `CIExposureAdjust`.
  public var value: Double

  /// Creates an exposure adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A highlight recovery adjustment.
public struct HighlightsFeature: ImageEffect, Equatable {

  /// The highlight recovery value. It is applied as `1 - value`.
  public var value: Double

  /// Creates a highlight adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A shadow lift adjustment.
public struct ShadowsFeature: ImageEffect, Equatable {

  /// The shadow amount passed to `CIHighlightShadowAdjust`.
  public var value: Double

  /// Creates a shadow adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// An RGBA color value used by parametric feature parameters.
public struct ParametricRGBAColor: Equatable, Sendable {

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
///
/// - Important: The names describe the intended *use*, not a masked evaluation.
///   The recipe source-over composites both colors across the whole image with
///   no luminance or region weighting; the only thing that limits either tint is
///   the alpha the caller chooses. This behavior is part of the feature's
///   contract, so a stored edit keeps rendering the same.
public struct HighlightShadowTintFeature: ImageEffect, Equatable {

  /// The tint color composited over the whole image, on top of `shadowColor`.
  ///
  /// Not restricted to highlight regions; see the type's discussion.
  public var highlightColor: ParametricRGBAColor

  /// The tint color composited over the whole image, beneath `highlightColor`.
  ///
  /// Not restricted to shadow regions; see the type's discussion.
  public var shadowColor: ParametricRGBAColor

  /// Creates a highlight/shadow tint adjustment.
  public init(
    highlightColor: ParametricRGBAColor,
    shadowColor: ParametricRGBAColor
  ) {
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
public struct TemperatureFeature: ImageEffect, Equatable {

  /// The color-temperature offset from Brightroom's neutral value, in Kelvin.
  public var value: Double

  /// The green–magenta tint offset from Brightroom's neutral value.
  public var tint: Double

  /// Creates a white-balance adjustment.
  public init(
    value: Double,
    tint: Double = 0
  ) {
    self.value = value
    self.tint = tint
  }
}

/// A luminance sharpen adjustment.
public struct SharpenFeature: ImageEffect, Equatable {

  /// The sharpness value passed to `CISharpenLuminance`.
  public var sharpness: Double

  /// The Brightroom filter radius value, resolved against the render pass's
  /// chain-entry extent (see `FeatureEvaluationContext.chainEntryExtent`),
  /// so a mid-chain crop never re-bases it.
  public var radius: Double

  /// Creates a sharpen adjustment.
  public init(
    sharpness: Double,
    radius: Double
  ) {
    self.sharpness = sharpness
    self.radius = radius
  }
}

/// A Gaussian blur radius value.
public enum GaussianBlurRadius: Equatable, Sendable {

  /// A Core Image blur radius in image-domain points.
  case absolute(Double)

  /// A slider value where 100 is a radius of one twentieth of the image
  /// diagonal, scaling linearly. It resolves against the render pass's chain-entry extent (see
  /// `FeatureEvaluationContext.chainEntryExtent`), so a mid-chain crop
  /// never re-bases it.
  case proportional(Double)
}

/// A Gaussian blur that preserves the input extent.
public struct GaussianBlurFeature: ImageEffect, Equatable {

  /// The blur radius descriptor.
  public var radius: GaussianBlurRadius

  /// Creates a Gaussian blur.
  public init(radius: Double) {
    self.radius = .absolute(radius)
  }

  /// Creates a Gaussian blur from a proportional slider value.
  public init(value: Double) {
    self.radius = .proportional(value)
  }
}

/// An unsharp mask adjustment.
public struct UnsharpMaskFeature: ImageEffect, Equatable {

  /// The intensity passed to `CIUnsharpMask`.
  public var intensity: Double

  /// The Brightroom filter radius value, resolved against the render pass's
  /// chain-entry extent (see `FeatureEvaluationContext.chainEntryExtent`),
  /// so a mid-chain crop never re-bases it.
  public var radius: Double

  /// Creates an unsharp mask adjustment.
  public init(
    intensity: Double,
    radius: Double
  ) {
    self.intensity = intensity
    self.radius = radius
  }
}

/// A vignette adjustment.
public struct VignetteFeature: ImageEffect, Equatable {

  /// The Brightroom vignette value used for both intensity and radius scaling.
  public var value: Double

  /// Creates a vignette adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A fade adjustment that overlays white.
public struct FadeFeature: ImageEffect, Equatable {

  /// The opacity of the white overlay.
  public var intensity: Double

  /// Creates a fade adjustment.
  public init(intensity: Double) {
    self.intensity = intensity
  }
}

/// A mask graph that produces alpha in the current feature domain.
public struct MaskTree: Equatable, Sendable {

  /// The root mask node.
  public var root: MaskNode

  /// Creates a mask tree.
  public init(root: MaskNode) {
    self.root = root
  }
}

/// A node in an alpha-only mask tree.
public indirect enum MaskNode: Equatable, Sendable {

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
public struct BrushMask: Equatable, Sendable {

  /// The brush strokes authored in the current feature domain.
  public var strokes: [BrushMaskStroke]

  /// Creates a brush-authored mask.
  public init(strokes: [BrushMaskStroke] = []) {
    self.strokes = strokes
  }
}

/// A continuous brush stroke represented by sampled stamp centers.
public struct BrushMaskStroke: Equatable, Sendable {

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
public struct BrushMaskBrush: Equatable, Sendable {

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
public struct MaskFeather: Equatable, Sendable {

  /// The input mask node to feather.
  public var input: MaskNode

  /// The blur radius used to feather alpha.
  public var radius: Double

  /// Creates a feather operation.
  public init(
    input: MaskNode,
    radius: Double
  ) {
    self.input = input
    self.radius = radius
  }
}

/// A mask subtraction operation.
public struct MaskSubtract: Equatable, Sendable {

  /// The mask to subtract from.
  public var base: MaskNode

  /// The mask removed from the base alpha.
  public var removing: MaskNode

  /// Creates a mask subtraction operation.
  public init(
    base: MaskNode,
    removing: MaskNode
  ) {
    self.base = base
    self.removing = removing
  }
}
