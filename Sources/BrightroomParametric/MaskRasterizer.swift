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

/// Renders a `Mask` into an alpha image in the current feature domain.
///
/// This is the single mask evaluator shared by `LocalAdjustmentFeature` and
/// `FeatureRenderer.makeMaskImage(for:extent:)`, so mask inspection
/// shows exactly the alpha a local adjustment composites through. Brush stamps are interpreted in Core Image working-space
/// coordinates (bottom-left origin, y-up).
struct MaskRasterizer: Sendable {

  /// The kernels used for mask subtraction.
  private let kernelRegistry = MaskKernels()

  func render(_ mask: Mask, extent: CGRect) throws -> CIImage {
    try renderNode(mask, extent: extent)
      .cropped(to: extent)
  }

  private func renderNode(_ mask: Mask, extent: CGRect) throws -> CIImage {
    switch mask {
    case let .brush(brushMask):
      return try render(brushMask, extent: extent)

    case let .inverted(input):
      let inputImage = try renderNode(input, extent: extent)
      return inputImage.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
          "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
      )
      .cropped(to: extent)

    case let .feathered(input, radius):
      let inputImage = try renderNode(input, extent: extent)
      guard radius > 0.0001 else {
        return inputImage
      }
      return inputImage
        .clamped(to: extent)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: radius]
        )
        .cropped(to: extent)

    case let .union(masks):
      guard masks.isEmpty == false else {
        throw FeatureEvaluationError.emptyMaskComposite
      }
      return try masks.reduce(CIImage.transparentImage(extent: extent)) { accumulated, mask in
        let next = try renderNode(mask, extent: extent)
        return try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMax,
          extent: extent
        )
      }

    case let .intersection(masks):
      guard let first = masks.first else {
        throw FeatureEvaluationError.emptyMaskComposite
      }
      var accumulated = try renderNode(first, extent: extent)
      for mask in masks.dropFirst() {
        let next = try renderNode(mask, extent: extent)
        accumulated = try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMultiply,
          extent: extent
        )
      }
      return accumulated.cropped(to: extent)

    case let .subtraction(base, removing):
      let baseImage = try renderNode(base, extent: extent)
      let removingImage = try renderNode(removing, extent: extent)
      return try kernelRegistry.subtractMask(
        base: baseImage,
        removing: removingImage,
        extent: extent
      )
    }
  }

  private func render(_ mask: BrushMask, extent: CGRect) throws -> CIImage {
    // The whole brush mask is one Core Image node. `BrushMaskImageProcessor`
    // draws every stamp with `BrushStampPipeline`, the same instanced `.max`
    // pass the live canvas uses, into whichever tile Core Image renders. A graph
    // with a node per stamp grew with the stamp count until Core Image could no
    // longer fuse it into a working Metal function (the export came out
    // transparent without an error), and it evaluated every stamp at every
    // pixel.
    try BrushMaskImageProcessor.makeImage(mask, extent: extent)
      .cropped(to: extent)
  }

  private func blendMask(
    foreground: CIImage,
    background: CIImage,
    kernel: CIBlendKernel,
    extent: CGRect
  ) throws -> CIImage {
    guard let output = kernel.apply(
      foreground: foreground,
      background: background
    ) else {
      throw FeatureEvaluationError.imageCreationFailed("CIBlendKernel")
    }
    return output.cropped(to: extent)
  }
}
