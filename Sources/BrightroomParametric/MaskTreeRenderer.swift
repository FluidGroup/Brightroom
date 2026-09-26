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

/// Renders a `MaskTree` into an alpha image in the current feature domain.
///
/// This is the single mask evaluator shared by `LocalAdjustment` and
/// `ParametricImageRenderer.makeMaskImage(for:extent:)`, so mask inspection
/// shows exactly the alpha a local adjustment composites through. Brush stamps are interpreted in Core Image working-space
/// coordinates (bottom-left origin, y-up).
struct MaskTreeRenderer: Sendable {

  /// The kernels used for brush stamps and mask subtraction.
  private let kernelRegistry = ParametricKernelRegistry()

  func render(_ maskTree: MaskTree, extent: CGRect) throws -> CIImage {
    try render(maskTree.root, extent: extent)
      .cropped(to: extent)
  }

  private func render(_ node: MaskNode, extent: CGRect) throws -> CIImage {
    switch node {
    case let .brush(mask):
      return try render(mask, extent: extent)

    case let .invert(input):
      let inputImage = try render(input, extent: extent)
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

    case let .feather(feather):
      let inputImage = try render(feather.input, extent: extent)
      guard feather.radius > 0.0001 else {
        return inputImage
      }
      return inputImage
        .clamped(to: extent)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: feather.radius]
        )
        .cropped(to: extent)

    case let .union(nodes):
      guard nodes.isEmpty == false else {
        throw FeatureEvaluationError.emptyMaskComposite
      }
      return try nodes.reduce(CIImage.parametricTransparent(extent: extent)) { accumulated, node in
        let next = try render(node, extent: extent)
        return try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMax,
          extent: extent
        )
      }

    case let .intersect(nodes):
      guard let first = nodes.first else {
        throw FeatureEvaluationError.emptyMaskComposite
      }
      var accumulated = try render(first, extent: extent)
      for node in nodes.dropFirst() {
        let next = try render(node, extent: extent)
        accumulated = try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMultiply,
          extent: extent
        )
      }
      return accumulated.cropped(to: extent)

    case let .subtract(subtract):
      let base = try render(subtract.base, extent: extent)
      let removing = try render(subtract.removing, extent: extent)
      return try kernelRegistry.subtractMask(
        base: base,
        removing: removing,
        extent: extent
      )
    }
  }

  private func render(_ mask: BrushMask, extent: CGRect) throws -> CIImage {
    // Each stamp compiles to one CIImage layer. `componentMax` is associative
    // and commutative, so the stamps reduce in any grouping; folding them in a
    // balanced tree keeps the Core Image graph depth at O(log n) instead of
    // O(n). A dense brush (small spacing) emits hundreds–thousands of stamps
    // per stroke, and a linear fold built a chain that deep — slow to compile
    // and at risk of stack overflow during render. The tree keeps the same
    // node count and the same result.
    var stampImages: [CIImage] = []
    for stroke in mask.strokes {
      let radius = max(stroke.brush.diameter / 2, 0)
      for stamp in stroke.stamps {
        stampImages.append(
          try kernelRegistry.makeBrushStamp(
            extent: extent,
            center: stamp,
            radius: radius,
            hardness: stroke.brush.hardness,
            opacity: stroke.brush.opacity
          )
        )
      }
    }

    return try reduceComponentMax(stampImages, extent: extent)
  }

  /// Reduces mask layers with `componentMax` in a balanced tree so the Core
  /// Image graph depth stays O(log n). `componentMax` is associative and
  /// commutative and `componentMax(transparent, x) == x`, so the pairwise
  /// grouping produces the same alpha field as a linear fold over a transparent
  /// base.
  private func reduceComponentMax(_ images: [CIImage], extent: CGRect) throws -> CIImage {
    guard images.isEmpty == false else {
      return CIImage.parametricTransparent(extent: extent)
    }

    var level = images
    while level.count > 1 {
      var next: [CIImage] = []
      next.reserveCapacity((level.count + 1) / 2)
      var index = 0
      while index < level.count {
        if index + 1 < level.count {
          next.append(
            try blendMask(
              foreground: level[index + 1],
              background: level[index],
              kernel: .componentMax,
              extent: extent
            )
          )
        } else {
          next.append(level[index])
        }
        index += 2
      }
      level = next
    }

    return level[0].cropped(to: extent)
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
      throw FeatureEvaluationError.failedToCreateImage("CIBlendKernel")
    }
    return output.cropped(to: extent)
  }
}
