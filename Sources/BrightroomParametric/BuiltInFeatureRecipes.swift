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

import CoreImage
import Foundation

// Core Image recipes for the built-in features.
//
// The parameter structs stay pure data in BuiltInFeatures.swift; their
// evaluation (`apply(to:context:)`) lives here. Every effect is
// extent-preserving (`cropped(to: image.extent)`).

// MARK: - Domain features

extension CropFeature {

  /// Checks that `rect` describes a finite, non-empty extent.
  ///
  /// `apply(to:context:)` calls this before evaluating. A host that rebuilds
  /// stored crops can call it to reject an invalid rectangle at load time.
  ///
  /// - Throws: `FeatureEvaluationError.invalidCropRect`.
  public func validate() throws {
    guard rect.isValidExtent else {
      throw FeatureEvaluationError.invalidCropRect(rect)
    }
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try validate()

    let geometry = outputGeometry(in: image.extent)

    // Normalize before clipping so half-pixel stored origins do not round an
    // intermediate crop outward. Straightening can expose transparent corners;
    // the canvas preserves the requested crop even where the source is absent.
    let canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: geometry.cropBounds)
    let cropped = image
      .transformed(by: geometry.inputToCropTransform)
      .cropped(to: geometry.cropBounds)
      .composited(over: canvas)

    // Turning the already-cropped canvas preserves odd/even pixel dimensions.
    return cropped
      .transformed(by: geometry.cropToOutputTransform)
      .cropped(to: geometry.outputBounds)
  }
}

// MARK: - Image effects

extension ColorCubeFeature {

  private var expectedByteCount: Int {
    dimension * dimension * dimension * 4 * MemoryLayout<Float>.size
  }

  /// Checks that `cubeData` holds exactly `dimension³` RGBA float entries.
  ///
  /// `apply(to:context:)` calls this before evaluating. A host that rebuilds
  /// stored lookup tables can call it to reject mismatched data at load time.
  ///
  /// - Throws: `FeatureEvaluationError.invalidColorCubeData`.
  public func validate() throws {
    guard cubeData.count == expectedByteCount else {
      throw FeatureEvaluationError.invalidColorCubeData(
        id: id,
        expectedByteCount: expectedByteCount,
        actualByteCount: cubeData.count
      )
    }
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try validate()

    let filter = ColorCubeFilterFactory.makeColorCubeFilter(
      cubeData: cubeData,
      dimension: dimension,
      id: id
    )
    filter.setValue(image, forKeyPath: kCIInputImageKey)

    guard let filtered = filter.outputImage else {
      throw FeatureEvaluationError.imageCreationFailed("CIColorCubeWithColorSpace")
    }

    let foreground = filtered.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(intensity)),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      ]
    )

    guard let output = CIFilter(
      name: "CISourceOverCompositing",
      parameters: [
        kCIInputImageKey: foreground,
        kCIInputBackgroundImageKey: image,
      ]
    )?.outputImage else {
      throw FeatureEvaluationError.imageCreationFailed("CISourceOverCompositing")
    }

    return output.cropped(to: image.extent)
  }
}

extension BrightnessFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIColorControls",
      parameters: ["inputBrightness": value]
    )
    .cropped(to: image.extent)
  }
}

extension ContrastFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIColorControls",
      parameters: [kCIInputContrastKey: 1 + value]
    )
    .cropped(to: image.extent)
  }
}

extension SaturationFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIColorControls",
      parameters: [kCIInputSaturationKey: 1 + value]
    )
    .cropped(to: image.extent)
  }
}

extension ExposureFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard abs(ev) > 0.0001 else {
      return image
    }
    return image.applyingFilter(
      "CIExposureAdjust",
      parameters: [kCIInputEVKey: ev]
    )
    .cropped(to: image.extent)
  }
}

extension HighlightsFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIHighlightShadowAdjust",
      parameters: ["inputHighlightAmount": 1 - value]
    )
    .cropped(to: image.extent)
  }
}

extension ShadowsFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIHighlightShadowAdjust",
      parameters: ["inputShadowAmount": value]
    )
    .cropped(to: image.extent)
  }
}

extension HighlightShadowTintFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let shadow = CIImage(color: shadowColor.ciColor)
      .cropped(to: image.extent)
    guard let shadowOutput = CIFilter(
      name: "CISourceOverCompositing",
      parameters: [
        kCIInputImageKey: shadow,
        kCIInputBackgroundImageKey: image,
      ]
    )?.outputImage else {
      throw FeatureEvaluationError.imageCreationFailed("CISourceOverCompositing")
    }

    let highlight = CIImage(color: highlightColor.ciColor)
      .cropped(to: image.extent)
    guard let highlightOutput = CIFilter(
      name: "CISourceOverCompositing",
      parameters: [
        kCIInputImageKey: highlight,
        kCIInputBackgroundImageKey: shadowOutput,
      ]
    )?.outputImage else {
      throw FeatureEvaluationError.imageCreationFailed("CISourceOverCompositing")
    }

    return highlightOutput.cropped(to: image.extent)
  }
}

extension WhiteBalanceFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CITemperatureAndTint",
      parameters: [
        "inputNeutral": CIVector(x: CGFloat(temperature) + 6500, y: CGFloat(tint)),
        "inputTargetNeutral": CIVector(x: 6500, y: 0),
      ]
    )
    .cropped(to: image.extent)
  }
}

extension SharpenFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let radius = RadiusCalculator.radius(
      value: radius,
      max: FilterConstants.gaussianBlurSliderMax,
      imageExtent: context.chainEntryExtent(for: image)
    )
    return image.applyingFilter(
      "CISharpenLuminance",
      parameters: [
        "inputRadius": radius,
        "inputSharpness": intensity,
      ]
    )
    .cropped(to: image.extent)
  }
}

extension GaussianBlurFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let radius = radius.pixels(chainEntryExtent: context.chainEntryExtent(for: image))

    guard radius > 0.0001 else {
      return image
    }
    return image
      .clamped(to: image.extent)
      .applyingFilter(
        "CIGaussianBlur",
        parameters: [kCIInputRadiusKey: radius]
      )
      .cropped(to: image.extent)
  }
}

extension UnsharpMaskFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let radius = RadiusCalculator.radius(
      value: radius,
      max: FilterConstants.unsharpMaskRadiusSliderMax,
      imageExtent: context.chainEntryExtent(for: image)
    )
    return image.applyingFilter(
      "CIUnsharpMask",
      parameters: [
        "inputIntensity": intensity,
        "inputRadius": radius,
      ]
    )
    .cropped(to: image.extent)
  }
}

extension VignetteFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    VignetteRecipe.apply(value: value, to: image)
  }
}

extension FadeFeature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let foreground = CIImage(
      color: CIColor(
        red: 1,
        green: 1,
        blue: 1,
        alpha: CGFloat(intensity)
      )
    )
    .cropped(to: image.extent)

    guard let output = CIFilter(
      name: "CISourceOverCompositing",
      parameters: [
        kCIInputImageKey: foreground,
        kCIInputBackgroundImageKey: image,
      ]
    )?.outputImage else {
      throw FeatureEvaluationError.imageCreationFailed("CISourceOverCompositing")
    }

    return output.cropped(to: image.extent)
  }
}

// MARK: - Helpers

extension HighlightShadowTintFeature.Color {

  var ciColor: CIColor {
    CIColor(
      red: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
  }
}

extension CGRect {

  var isValidExtent: Bool {
    origin.x.isFinite
      && origin.y.isFinite
      && size.width.isFinite
      && size.height.isFinite
      && size.width > 0
      && size.height > 0
  }
}
