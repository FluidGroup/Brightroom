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
/// Case names say how far the picture turns counterclockwise on screen; the
/// number is the magnitude of the raw value, in the order the built-in rotate
/// button steps through. Raw values are signed degrees in the y-down (UIKit)
/// convention, where a negative angle turns counterclockwise; they are
/// stable, so hosts can store them. This is a pure CoreGraphics/Foundation
/// type with no SwiftUI dependency.
public enum QuarterTurn: Int, Equatable, Sendable, CaseIterable {

  /// No rotation (0°).
  case zero = 0

  /// 90° counterclockwise on screen (-90°).
  case counterclockwise90 = -90

  /// 180° counterclockwise on screen, a half turn (-180°).
  case counterclockwise180 = -180

  /// 270° counterclockwise on screen (-270°), the same as 90° clockwise.
  case counterclockwise270 = -270

  /// The rotation in radians, in the same y-down convention as the raw value.
  public var radians: Double {
    Double(rawValue) * .pi / 180
  }

  /// Whether the turn exchanges the output's horizontal and vertical axes.
  public var isSideways: Bool {
    switch self {
    case .counterclockwise90, .counterclockwise270:
      return true
    case .zero, .counterclockwise180:
      return false
    }
  }
}

/// A crop in the current domain.
///
/// The crop rectangle is interpreted relative to the image produced by the
/// previous feature. A second crop therefore crops the already-cropped
/// output of the first crop. Evaluation straightens the source, extracts the
/// crop, and then applies its quarter turn to the cropped output.
/// The stored rectangle describes the selection before that final turn;
/// changing `quarterTurn` does not change the selected source area.
public struct CropFeature: Feature, Equatable {

  /// The rectangle to keep after straightening and before the output quarter
  /// turn, relative to the current input image's origin (bottom-left, y-up).
  ///
  /// Its size is the crop size. A sideways `quarterTurn` exchanges only the
  /// final output dimensions; the selection rectangle remains unchanged.
  /// Regions outside the input are transparent. Pixel fitting is the caller's
  /// responsibility; evaluation does not shrink the requested canvas. Snap a
  /// rectangle to whole pixels inside the input with
  /// `pixelAligned(imageSize:)`, or create the crop with
  /// `init(topLeftRect:imageSize:quarterTurn:straightenRadians:)` or
  /// `fitted(to:imageSize:)`, which align it.
  public var rect: CGRect

  /// The quarter turn applied to the cropped output.
  public var quarterTurn: QuarterTurn

  /// A free straightening angle in radians, applied about the center of `rect`
  /// before extracting the crop and applying `quarterTurn`.
  ///
  /// A positive angle turns the image clockwise on screen. This is the sign
  /// convention of `QuarterTurn.radians`, whose counterclockwise turns are
  /// negative.
  public var straightenRadians: Double

  /// Creates a current-domain crop feature.
  public init(
    rect: CGRect,
    quarterTurn: QuarterTurn = .zero,
    straightenRadians: Double = 0
  ) {
    self.rect = rect
    self.quarterTurn = quarterTurn
    self.straightenRadians = straightenRadians
  }
}

/// A named group of image effects: a filter, such as a film look.
///
/// The effects are decided by data (a catalog), so they are type-erased.
/// Two filters are equal when their whole value is equal (name, id, and
/// effects); `id` names the look, so a picker can tell one filter from
/// another without comparing their effects.
///
/// A filter is a composite: its `body` is its effects, evaluated in order.
/// Nest another filter with `AnyImageEffect(innerFilter)`.
public struct FilterFeature: ImageEffect, Equatable, Identifiable {

  /// The display name associated with the filter.
  public var name: String

  /// The stable filter identifier.
  public var id: String

  /// The effects evaluated inside the filter, in order.
  public var effects: [AnyImageEffect]

  /// Creates a filter feature.
  public init(
    name: String,
    id: String,
    effects: [AnyImageEffect]
  ) {
    self.name = name
    self.id = id
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

  /// The name that tells this lookup table from another: `cubeData` is
  /// binary, so a host keeps the id unique per table. Equality compares the
  /// whole value, the data included.
  public var id: String

  /// The opacity used when compositing the color-cube result over its input.
  /// `1` applies the lookup table fully, `0` leaves the input unchanged.
  public var intensity: Double

  /// The color-cube dimension.
  public var dimension: Int

  /// RGBA float cube data in `CIColorCubeWithColorSpace` layout.
  public var cubeData: Data

  /// Creates a color-cube effect.
  public init(
    name: String,
    id: String,
    intensity: Double = 1,
    dimension: Int,
    cubeData: Data
  ) {
    self.name = name
    self.id = id
    self.intensity = intensity
    self.dimension = dimension
    self.cubeData = cubeData
  }
}

/// A brightness adjustment.
public struct BrightnessFeature: ImageEffect, Equatable {

  /// The brightness offset passed to `CIColorControls`. `0` is neutral.
  public var value: Double

  /// Creates a brightness adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A contrast adjustment.
public struct ContrastFeature: ImageEffect, Equatable {

  /// The contrast offset passed to `CIColorControls` as `1 + value`. `0` is
  /// neutral.
  public var value: Double

  /// Creates a contrast adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A saturation adjustment.
public struct SaturationFeature: ImageEffect, Equatable {

  /// The saturation offset passed to `CIColorControls` as `1 + value`. `0` is
  /// neutral, `-1` removes all color.
  public var value: Double

  /// Creates a saturation adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// An exposure adjustment.
public struct ExposureFeature: ImageEffect, Equatable {

  /// The exposure change in stops (EV), passed to `CIExposureAdjust`. `0` is
  /// neutral.
  public var ev: Double

  /// Creates an exposure adjustment.
  public init(ev: Double) {
    self.ev = ev
  }
}

/// A highlight recovery adjustment.
public struct HighlightsFeature: ImageEffect, Equatable {

  /// The highlight recovery value. It is applied as `1 - value`. `0` is
  /// neutral.
  public var value: Double

  /// Creates a highlight adjustment.
  public init(value: Double) {
    self.value = value
  }
}

/// A shadow lift adjustment.
public struct ShadowsFeature: ImageEffect, Equatable {

  /// The shadow amount passed to `CIHighlightShadowAdjust`. `0` is neutral.
  public var value: Double

  /// Creates a shadow adjustment.
  public init(value: Double) {
    self.value = value
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

  /// An RGBA tint color in the Core Image working range.
  public struct Color: Equatable, Sendable {

    /// The red component.
    public var red: Double

    /// The green component.
    public var green: Double

    /// The blue component.
    public var blue: Double

    /// The alpha component. It is the only thing that limits the tint.
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

  /// The tint color composited over the whole image, on top of `shadowColor`.
  ///
  /// Not restricted to highlight regions; see the type's discussion.
  public var highlightColor: Color

  /// The tint color composited over the whole image, beneath `highlightColor`.
  ///
  /// Not restricted to shadow regions; see the type's discussion.
  public var shadowColor: Color

  /// Creates a highlight/shadow tint adjustment.
  public init(
    highlightColor: Color,
    shadowColor: Color
  ) {
    self.highlightColor = highlightColor
    self.shadowColor = shadowColor
  }
}

/// A two-axis white-balance adjustment evaluated by Core Image.
///
/// `temperature` shifts color temperature relative to Brightroom's neutral
/// white point, while `tint` moves the same white point along the
/// green–magenta axis. Keeping both values in one feature preserves the coupled
/// semantics of `CITemperatureAndTint` instead of approximating them as
/// sequential filters.
public struct WhiteBalanceFeature: ImageEffect, Equatable {

  /// The color-temperature offset from Brightroom's neutral value, in Kelvin.
  /// `0` is neutral.
  public var temperature: Double

  /// The green–magenta tint offset from Brightroom's neutral value. `0` is
  /// neutral.
  public var tint: Double

  /// Creates a white-balance adjustment.
  public init(
    temperature: Double,
    tint: Double = 0
  ) {
    self.temperature = temperature
    self.tint = tint
  }
}

/// A luminance sharpen adjustment.
public struct SharpenFeature: ImageEffect, Equatable {

  /// The sharpness passed to `CISharpenLuminance`. `0` is neutral.
  public var intensity: Double

  /// The radius passed to `CISharpenLuminance` as `inputRadius`.
  ///
  /// On a 4000×3000 chain entry, `.proportional(1)` is 2.5 px and
  /// `.absolute(3)` is 3 px.
  public var radius: EffectRadius

  /// Creates a sharpen adjustment.
  public init(
    intensity: Double,
    radius: EffectRadius
  ) {
    self.intensity = intensity
    self.radius = radius
  }
}

/// A Gaussian blur that preserves the input extent.
public struct GaussianBlurFeature: ImageEffect, Equatable {

  /// The blur radius.
  public var radius: EffectRadius

  /// Creates a Gaussian blur.
  ///
  /// Pass `.absolute(_:)` for a radius in pixels of the full-resolution
  /// source, or `.proportional(_:)` for a fraction of the chain-entry
  /// diagonal.
  public init(radius: EffectRadius) {
    self.radius = radius
  }
}

/// An unsharp mask adjustment.
public struct UnsharpMaskFeature: ImageEffect, Equatable {

  /// The intensity passed to `CIUnsharpMask`.
  public var intensity: Double

  /// The radius passed to `CIUnsharpMask` as `inputRadius`.
  ///
  /// On a 4000×3000 chain entry, `.proportional(100)` is 250 px and
  /// `.absolute(3)` is 3 px. A large radius raises local contrast (clarity)
  /// rather than sharpening edges.
  public var radius: EffectRadius

  /// Creates an unsharp mask adjustment.
  public init(
    intensity: Double,
    radius: EffectRadius
  ) {
    self.intensity = intensity
    self.radius = radius
  }
}

/// A vignette adjustment.
///
/// The vignette is a circular field centred on the feature's input extent,
/// with a radius of half the input's longer side and a fixed falloff. Its
/// centre and size therefore follow the image the feature receives: placed
/// after a crop, it is centred on the cropped picture.
public struct VignetteFeature: ImageEffect, Equatable {

  /// The strength of the vignette (the intensity of Core Image's
  /// `CIVignetteEffect`). It sets only the strength; the centre and the radius
  /// come from the input extent. `0` is neutral.
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

/// An alpha-only mask in the current feature domain.
///
/// A mask is a value tree: leaves produce alpha (`brush`), and the other
/// cases refine or combine their inputs. It is evaluated against the input
/// extent of the feature that owns it.
public indirect enum Mask: Equatable, Sendable {

  /// Produces alpha from brush strokes.
  case brush(BrushMask)

  /// Inverts the input alpha.
  case inverted(Mask)

  /// Blurs the input alpha by `radius` while preserving extent.
  case feathered(Mask, radius: Double)

  /// Combines masks using alpha union. An empty list throws when evaluated.
  case union([Mask])

  /// Combines masks using alpha intersection. An empty list throws when
  /// evaluated.
  case intersection([Mask])

  /// Removes the alpha of `removing` from the first mask.
  case subtraction(Mask, removing: Mask)
}

/// A brush-authored mask.
public struct BrushMask: Equatable, Sendable {

  /// A continuous brush stroke represented by sampled stamp centers.
  public struct Stroke: Equatable, Sendable {

    /// The stamp centers in current feature-domain coordinates.
    public var stampCenters: [CGPoint]

    /// The brush used to render each stamp.
    public var brush: Brush

    /// Creates a brush stroke.
    public init(
      stampCenters: [CGPoint],
      brush: Brush
    ) {
      self.stampCenters = stampCenters
      self.brush = brush
    }
  }

  /// Brush parameters for a mask stroke.
  public struct Brush: Equatable, Sendable {

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

  /// The brush strokes authored in the current feature domain.
  public var strokes: [Stroke]

  /// Creates a brush-authored mask.
  public init(strokes: [Stroke] = []) {
    self.strokes = strokes
  }
}
