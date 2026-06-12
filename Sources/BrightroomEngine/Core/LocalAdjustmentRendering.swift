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

  enum PreviewPurpose: Sendable {
    case editingBase
    case editing
  }

  /// Evaluates the feature list in document order, like the export renderer.
  ///
  /// `.editingBase` skips local adjustments (their mask rasterization is
  /// owned by the render path that knows its target resolution); `.editing`
  /// includes them. Crop features are domain features and not evaluated here.
  func makePreviewImage(
    from sourceImage: CIImage,
    purpose: PreviewPurpose
  ) -> CIImage {
    features.reduce(sourceImage) { image, feature in
      switch feature.payload {
      case .globalEffects(let filters):
        return filters.apply(to: image)
      case .localAdjustment(let layer):
        switch purpose {
        case .editingBase:
          return image
        case .editing:
          return layer.apply(to: image)
        }
      case .crop:
        return image
      }
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

/// Memoizes the CPU mask raster, which costs O(image area + stamp count) per
/// pass (~150ms at full resolution). Masks are Equatable value types, so an
/// equality-validated cache returns bit-identical rasters.
///
/// Only preview-scale rasters are retained: editing previews are bounded by
/// `EditingStack`'s 2560px editing size and re-render repeatedly, while an
/// export-resolution raster is produced once per export and never requested
/// again — pinning one in a process-lifetime static would cost ~200MB for a
/// 48MP image.
private enum LocalAdjustmentMaskRasterStore {

  private struct Entry {
    let mask: EditingStack.Edit.LocalAdjustmentMask
    let size: CGSize
    let cgImage: CGImage
    let byteCost: Int
  }

  private static let lock = NSLock()
  private static var entries: [Entry] = []
  private static let maxEntryByteCost = 32 * 1024 * 1024
  private static let totalByteBudget = 64 * 1024 * 1024

  static func image(
    for mask: EditingStack.Edit.LocalAdjustmentMask,
    size: CGSize
  ) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }

    guard let index = entries.firstIndex(where: { $0.size == size && $0.mask == mask }) else {
      return nil
    }
    let entry = entries.remove(at: index)
    entries.append(entry)
    return entry.cgImage
  }

  static func store(
    _ cgImage: CGImage,
    for mask: EditingStack.Edit.LocalAdjustmentMask,
    size: CGSize
  ) {
    let byteCost = cgImage.bytesPerRow * cgImage.height
    guard byteCost <= maxEntryByteCost else {
      return
    }

    lock.lock()
    defer { lock.unlock() }

    entries.removeAll { $0.size == size && $0.mask == mask }
    entries.append(Entry(mask: mask, size: size, cgImage: cgImage, byteCost: byteCost))

    var totalCost = entries.reduce(0) { $0 + $1.byteCost }
    while totalCost > totalByteBudget, entries.isEmpty == false {
      totalCost -= entries.removeFirst().byteCost
    }
  }
}

extension EditingStack.Edit.LocalAdjustmentMask {

  fileprivate func makeCIImage(size: CGSize) -> CIImage? {
    let targetSize = CGSize(
      width: max(size.width.rounded(), 1),
      height: max(size.height.rounded(), 1)
    )

    if let cached = LocalAdjustmentMaskRasterStore.image(for: self, size: targetSize) {
      return CIImage(cgImage: cached)
        .cropped(to: CGRect(origin: .zero, size: targetSize))
    }

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

    LocalAdjustmentMaskRasterStore.store(cgImage, for: self, size: targetSize)

    // Stamps are authored in display coordinates (top-left origin, y-down),
    // which is exactly UIGraphics' coordinate system, so the raster is
    // already visually correct. `CIImage(cgImage:)` preserves visual
    // orientation — adding a flip here renders exported masks upside-down
    // relative to the interactive preview. (A flip is required for
    // `CIImage(mtlTexture:)`, not for `CIImage(cgImage:)`.)
    return CIImage(cgImage: cgImage)
      .cropped(to: CGRect(origin: .zero, size: targetSize))
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

    // The gradient depends only on the per-stroke brush, so build it once
    // instead of per stamp; a long stroke holds hundreds of stamps.
    let softStampGradient: CGGradient?
    if hardness >= 0.999 {
      softStampGradient = nil
    } else {
      guard let gradient = Self.makeSoftStampGradient(hardness: hardness, opacity: opacity) else {
        return
      }
      softStampGradient = gradient
    }

    for stamp in stamps {
      if let softStampGradient {
        context.drawRadialGradient(
          softStampGradient,
          startCenter: stamp,
          startRadius: 0,
          endCenter: stamp,
          endRadius: radius,
          options: []
        )
      } else {
        let rect = CGRect(
          x: stamp.x - radius,
          y: stamp.y - radius,
          width: radius * 2,
          height: radius * 2
        )
        context.setFillColor(UIColor(white: 1, alpha: opacity).cgColor)
        context.fillEllipse(in: rect)
      }
    }
  }

  private static func makeSoftStampGradient(
    hardness: CGFloat,
    opacity: CGFloat
  ) -> CGGradient? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // The falloff must match the interactive Metal brush
    // (EditingCanvasBrushMaskShaderSource):
    //   alpha = (1 - smoothstep(hardness, 1, distance)) * opacity
    // A plain linear ramp renders a fatter tail per stamp, and over-blending
    // across overlapping stamps compounds that into visibly wider and
    // stronger coverage in exports than the preview ever showed.
    let hardnessStop = min(max(hardness, 0.001), 0.999)
    let stepCount = 16
    var locations: [CGFloat] = [0, hardnessStop]
    var colors: [CGColor] = [
      UIColor(white: 1, alpha: opacity).cgColor,
      UIColor(white: 1, alpha: opacity).cgColor,
    ]
    for index in 1...stepCount {
      let bandFraction = CGFloat(index) / CGFloat(stepCount)
      let smooth = bandFraction * bandFraction * (3 - 2 * bandFraction)
      locations.append(hardnessStop + (1 - hardnessStop) * bandFraction)
      colors.append(UIColor(white: 1, alpha: opacity * (1 - smooth)).cgColor)
    }

    return CGGradient(
      colorsSpace: colorSpace,
      colors: colors as CFArray,
      locations: &locations
    )
  }
}
