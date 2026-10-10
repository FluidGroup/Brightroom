//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

/// The color space the Tone Curve and Color Mixer kernels compute in.
///
/// Core Image hands a custom kernel its pixels in the working color space of
/// the `CIContext` that renders the recipe. Both kernels are written for
/// extended-linear Display-P3 numbers (the tone curve's stop shaper and P3
/// luminance, the mixer's P3 → XYZ → OKLab matrices), so a recipe matches its
/// input from the working space into that space before the kernel and matches
/// the result back afterwards. The same feature then renders the same colors
/// through any context: the export, canvas, and swatch contexts, which already
/// work in extended-linear Display-P3 (Core Image drops the conversions, so
/// their pixels are unchanged), a default `CIContext()` or AVFoundation's
/// default video context (extended-linear sRGB), or a gamma-encoded working
/// space.
///
/// A context with color management off (`.workingColorSpace: NSNull()`)
/// performs no matching, so the kernels read its values as they are.
///
/// The working format still matters: an 8-bit working format clamps the
/// linear values the kernels read and write to 0...1 and quantizes them, so
/// wide-gamut and extended-range colors are lost. Render through a
/// floating-point format such as `CIFormat.RGBAh`.
nonisolated enum ColorAdjustmentKernelSpace {

  /// Extended-linear Display-P3.
  static let colorSpace: CGColorSpace? = CGColorSpace(
    name: CGColorSpace.extendedLinearDisplayP3
  )

  /// Evaluates `kernel` over `image` expressed in extended-linear Display-P3
  /// and returns its result in the context's working space.
  ///
  /// Throws `FeatureEvaluationError.imageCreationFailed` naming the kernel
  /// when Core Image cannot express the conversion, rather than running the
  /// kernel on numbers it does not interpret correctly. Core Image converts
  /// between RGB color spaces such as these, so this does not happen in
  /// practice.
  static func apply(
    to image: CIImage,
    kernelName: String,
    _ kernel: (CIImage) throws -> CIImage
  ) throws -> CIImage {
    guard
      let colorSpace,
      let kernelInput = image.matchedFromWorkingSpace(to: colorSpace)
    else {
      throw FeatureEvaluationError.imageCreationFailed(kernelName)
    }
    let kernelOutput = try kernel(kernelInput)
    guard let output = kernelOutput.matchedToWorkingSpace(from: colorSpace) else {
      throw FeatureEvaluationError.imageCreationFailed(kernelName)
    }
    return output
  }
}
