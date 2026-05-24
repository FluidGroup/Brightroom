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
import UIKit

extension EditingStack.Edit {

  public enum PreviewPurpose: Sendable {
    case editingBase
    case editing
    case cropInteraction
  }

  public func makePreviewImage(
    from sourceImage: CIImage,
    purpose: PreviewPurpose = .editing
  ) -> CIImage {
    switch purpose {
    case .editingBase:
      filters.apply(to: sourceImage)
    case .editing:
      applyLocalAdjustments(to: filters.apply(to: sourceImage))
    case .cropInteraction:
      sourceImage
    }
  }

  func applyLocalAdjustments(to image: CIImage) -> CIImage {
    localAdjustments.reduce(image) { currentImage, layer in
      layer.apply(to: currentImage)
    }
  }
}

extension EditingStack.Edit.LocalAdjustmentLayer {

  func apply(to image: CIImage) -> CIImage {
    guard isEnabled, mask.isEmpty == false else {
      return image
    }

    let extent = image.extent
    let imageInZeroOrigin = image.removingExtentOffset()
    let adjustedImage = effect
      .apply(to: imageInZeroOrigin, previewScale: 1)
      .cropped(to: CGRect(origin: .zero, size: extent.size))

    guard let maskImage = mask.makeCIImage(size: extent.size) else {
      return image
    }

    let composited = adjustedImage.applyingFilter(
      "CIBlendWithAlphaMask",
      parameters: [
        kCIInputBackgroundImageKey: imageInZeroOrigin,
        kCIInputMaskImageKey: maskImage,
      ]
    )

    if extent.origin == .zero {
      return composited
    } else {
      return composited.transformed(
        by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
      )
    }
  }
}

extension EditingStack.Edit.LocalAdjustmentEffect {

  public var isActive: Bool {
    switch self {
    case let .gaussianBlur(radius):
      return radius > 0.01
    case let .exposure(value):
      return abs(value) > 0.001
    }
  }

  public func apply(
    to image: CIImage,
    previewScale: CGFloat = 1
  ) -> CIImage {
    switch self {
    case let .gaussianBlur(radius):
      let scaledRadius = radius * max(previewScale, 0.0001)
      guard scaledRadius > 0.01 else {
        return image
      }

      return image
        .clamped(to: image.extent)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: scaledRadius]
        )
        .cropped(to: image.extent)

    case let .exposure(value):
      guard abs(value) > 0.001 else {
        return image
      }

      return image.applyingFilter(
        "CIExposureAdjust",
        parameters: [kCIInputEVKey: value]
      )
    }
  }
}

extension EditingStack.Edit.LocalAdjustmentMask {

  func makeCIImage(size: CGSize) -> CIImage? {
    let targetSize = CGSize(
      width: max(size.width.rounded(), 1),
      height: max(size.height.rounded(), 1)
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false

    let image = UIGraphicsImageRenderer(size: targetSize, format: format).image { rendererContext in
      let context = rendererContext.cgContext
      context.setBlendMode(.normal)
      context.setFillColor(UIColor.clear.cgColor)
      context.fill(CGRect(origin: .zero, size: targetSize))

      for stroke in strokes {
        stroke.drawMask(in: context)
      }
    }

    guard let cgImage = image.cgImage else {
      return nil
    }

    return CIImage(cgImage: cgImage)
  }
}

extension EditingStack.Edit.LocalAdjustmentStroke {

  fileprivate func drawMask(in context: CGContext) {
    guard stamps.isEmpty == false else {
      return
    }

    let radius = max(brush.size / 2, 0.5)
    let opacity = min(max(brush.opacity, 0), 1)
    let hardness = min(max(brush.hardness, 0), 1)

    for stamp in stamps {
      let rect = CGRect(
        x: stamp.x - radius,
        y: stamp.y - radius,
        width: radius * 2,
        height: radius * 2
      )

      if hardness >= 0.999 {
        context.setFillColor(UIColor(white: 1, alpha: opacity).cgColor)
        context.fillEllipse(in: rect)
      } else {
        drawSoftStamp(
          in: context,
          center: stamp,
          radius: radius,
          hardness: hardness,
          opacity: opacity
        )
      }
    }
  }

  private func drawSoftStamp(
    in context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    hardness: CGFloat,
    opacity: CGFloat
  ) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
      UIColor(white: 1, alpha: opacity).cgColor,
      UIColor(white: 1, alpha: opacity).cgColor,
      UIColor(white: 1, alpha: 0).cgColor,
    ] as CFArray
    var locations: [CGFloat] = [
      0,
      min(max(hardness, 0.001), 0.999),
      1,
    ]

    guard let gradient = CGGradient(
      colorsSpace: colorSpace,
      colors: colors,
      locations: &locations
    ) else {
      return
    }

    context.drawRadialGradient(
      gradient,
      startCenter: center,
      startRadius: 0,
      endCenter: center,
      endRadius: radius,
      options: []
    )
  }
}
