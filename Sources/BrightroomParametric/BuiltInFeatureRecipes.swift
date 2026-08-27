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
// The parameter structs stay pure data in ParametricFeatureModel.swift; their
// evaluation behavior lives here as capability conformances. Every effect is
// extent-preserving (`cropped(to: image.extent)`).

// MARK: - Domain features

extension CropFeature: DomainFeatureType {

  public func validate() throws {
    guard cropRect.isParametricValidExtent else {
      throw FeatureGraphCompilerError.invalidCropRect(id, cropRect)
    }
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try validate()

    let absoluteCropRect = cropRect.offsetBy(
      dx: image.extent.minX,
      dy: image.extent.minY
    )

    // Rotate the source about the crop-rect center BEFORE extracting the crop
    // window, so a free straighten angle pulls in surrounding source content —
    // matching the engine's CGContext crop, which rotates the destination about
    // the same center and then clips to the crop rect. The engine rotates the
    // destination CTM by `-aggregatedRotation`, which in its y-up context shows
    // the content rotated `+aggregatedRotation`; reproducing that as an image
    // rotation in Core Image's y-up space means rotating by the NEGATED angle.
    // For the default `.zero` / 0 rotation this is the identity transform, so
    // the crop reduces to a pure extent change (existing crop behavior is
    // unchanged).
    let angle = -aggregatedRotationRadians

    let cropped: CIImage
    if angle == 0 {
      cropped = image.cropped(to: absoluteCropRect)
    } else {
      let center = CGPoint(x: absoluteCropRect.midX, y: absoluteCropRect.midY)
      let rotateAboutCenter = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: angle)
        .translatedBy(x: -center.x, y: -center.y)
      // Match the engine's fixed crop-rect canvas: a rotation can leave parts of
      // the crop rect uncovered (triangular corners under a free angle, bands
      // under a quarter turn). Compositing over a transparent canvas of the crop
      // rect keeps the output extent exactly the crop rect instead of shrinking
      // it to the rotated content's intersection. `CIImage(color:)` is the
      // infinite-extent transparent source (unlike `CIImage.empty()`, whose
      // extent is empty and would crop away to nothing).
      let canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
        .cropped(to: absoluteCropRect)
      cropped = image
        .transformed(by: rotateAboutCenter)
        .cropped(to: absoluteCropRect)
        .composited(over: canvas)
    }

    return cropped.transformed(
      by: CGAffineTransform(
        translationX: -absoluteCropRect.minX,
        y: -absoluteCropRect.minY
      )
    )
  }
}

// MARK: - Image effects

extension PresetFeature: ImageEffectFeatureType {

  public var childFeatures: [any Feature] { effects }

  public func validate() throws {
    for effect in effects {
      try effect.validate()
    }
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try effects
      .filter(\.isEnabled)
      .reduce(image) { image, effect in
        try effect.apply(to: image, context: context)
      }
  }
}

extension EffectPipelineFeature: ImageEffectFeatureType {

  public var childFeatures: [any Feature] { pipeline.effects }

  public func validate() throws {
    for effect in pipeline.effects {
      try effect.validate()
    }
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try pipeline.apply(to: image, context: context)
  }
}

extension ColorCubeFeature: ImageEffectFeatureType {

  private var expectedByteCount: Int {
    dimension * dimension * dimension * 4 * MemoryLayout<Float>.size
  }

  public func validate() throws {
    guard cubeData.count == expectedByteCount else {
      throw FeatureGraphCompilerError.invalidColorCubeData(
        id,
        expectedByteCount: expectedByteCount,
        actualByteCount: cubeData.count
      )
    }
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try validate()

    let filter = ParametricColorCubeHelper.makeColorCubeFilter(
      cubeData: cubeData,
      dimension: dimension,
      identifier: identifier
    )
    filter.setValue(image, forKeyPath: kCIInputImageKey)

    guard let filtered = filter.outputImage else {
      throw FeatureGraphCompilerError.failedToCreateImage("CIColorCubeWithColorSpace")
    }

    let foreground = filtered.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount)),
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
      throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
    }

    return output.cropped(to: image.extent)
  }
}

extension BrightnessFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIColorControls",
      parameters: ["inputBrightness": value]
    )
    .cropped(to: image.extent)
  }
}

extension ContrastFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIColorControls",
      parameters: [kCIInputContrastKey: 1 + value]
    )
    .cropped(to: image.extent)
  }
}

extension SaturationFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIColorControls",
      parameters: [kCIInputSaturationKey: 1 + value]
    )
    .cropped(to: image.extent)
  }
}

extension ExposureFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard abs(value) > 0.0001 else {
      return image
    }
    return image.applyingFilter(
      "CIExposureAdjust",
      parameters: [kCIInputEVKey: value]
    )
    .cropped(to: image.extent)
  }
}

extension HighlightsFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIHighlightShadowAdjust",
      parameters: ["inputHighlightAmount": 1 - value]
    )
    .cropped(to: image.extent)
  }
}

extension ShadowsFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CIHighlightShadowAdjust",
      parameters: ["inputShadowAmount": value]
    )
    .cropped(to: image.extent)
  }
}

extension HighlightShadowTintFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let shadow = CIImage(color: shadowColor.parametricCIColor)
      .cropped(to: image.extent)
    guard let shadowOutput = CIFilter(
      name: "CISourceOverCompositing",
      parameters: [
        kCIInputImageKey: shadow,
        kCIInputBackgroundImageKey: image,
      ]
    )?.outputImage else {
      throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
    }

    let highlight = CIImage(color: highlightColor.parametricCIColor)
      .cropped(to: image.extent)
    guard let highlightOutput = CIFilter(
      name: "CISourceOverCompositing",
      parameters: [
        kCIInputImageKey: highlight,
        kCIInputBackgroundImageKey: shadowOutput,
      ]
    )?.outputImage else {
      throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
    }

    return highlightOutput.cropped(to: image.extent)
  }
}

extension TemperatureFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image.applyingFilter(
      "CITemperatureAndTint",
      parameters: [
        "inputNeutral": CIVector(x: CGFloat(value) + 6500, y: CGFloat(tint)),
        "inputTargetNeutral": CIVector(x: 6500, y: 0),
      ]
    )
    .cropped(to: image.extent)
  }
}

extension SharpenFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let radius = ParametricRadiusCalculator.radius(
      value: radius,
      max: ParametricFilterConstants.gaussianBlurSliderMax,
      imageExtent: context.radiusBasis(for: image)
    )
    return image.applyingFilter(
      "CISharpenLuminance",
      parameters: [
        "inputRadius": radius,
        "inputSharpness": sharpness,
      ]
    )
    .cropped(to: image.extent)
  }
}

extension GaussianBlurFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let radius: Double
    switch self.radius {
    case let .absolute(value):
      radius = value
    case let .editingStackFilterValue(value):
      radius = ParametricRadiusCalculator.radius(
        value: value,
        max: ParametricFilterConstants.gaussianBlurSliderMax,
        imageExtent: context.radiusBasis(for: image)
      )
    }

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

extension UnsharpMaskFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let radius = ParametricRadiusCalculator.radius(
      value: radius,
      max: ParametricFilterConstants.unsharpMaskRadiusSliderMax,
      imageExtent: context.radiusBasis(for: image)
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

extension VignetteFeature: ImageEffectFeatureType {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    ParametricVignetteRenderer.apply(value: value, to: image)
  }
}

extension FadeFeature: ImageEffectFeatureType {

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
      throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
    }

    return output.cropped(to: image.extent)
  }
}

// MARK: - Helpers

extension ParametricRGBAColor {

  var parametricCIColor: CIColor {
    CIColor(
      red: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
  }
}

extension CGRect {

  var isParametricValidExtent: Bool {
    origin.x.isFinite
      && origin.y.isFinite
      && size.width.isFinite
      && size.height.isFinite
      && size.width > 0
      && size.height > 0
  }
}
