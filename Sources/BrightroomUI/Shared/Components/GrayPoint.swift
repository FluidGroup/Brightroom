//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
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
import CoreImage
import Foundation
import Metal

import BrightroomEngine
import BrightroomParametric

/// White balance from a gray point: the temperature and tint that make a clicked area of a
/// feature's output neutral.
///
/// The area is measured as it enters `effects.whiteBalance` (after the preset, exposure and
/// brightness), over a preview source, in the canvas and export working space (extended-linear
/// Display P3), so the white balance renders it neutral on the canvas and in the export.
public enum GrayPoint {

  /// Why a click gives no white balance.
  public enum Rejection: Error, Equatable, Sendable {
    /// There is no pixel of the image to sample at the point.
    case outsideImage
    /// The area is too dark to tell its colour, or a channel has no light at all.
    case tooDark
    /// A channel of the area is clipped.
    case tooBright
  }

  /// The side of the square averaged around the point, in pixels of the preview source.
  static let sampleSize = 7

  /// The canvas and export colour contract: an extended-linear Display P3 working space at half
  /// float.
  private static let context: CIContext = {
    let options: [CIContextOption: Any] = [
      .name: "Brightroom.GrayPoint",
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
      .cacheIntermediates: false,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: options)
  }()

  /// The white balance that makes the area around `outputPoint` neutral, solved within the ranges
  /// off the calling actor; nil when the area is neutral already, so the feature needs no white
  /// balance.
  ///
  /// The point is mapped through the crop the canvas shows. The result replaces
  /// `feature.effects.whiteBalance`, which is not measured. The rejection is `.outsideImage` when
  /// there is nothing to sample at the point: it is off the crop output or off the image, or the
  /// image cannot be evaluated there (it fails, or its colour is not finite).
  ///
  /// - Parameters:
  ///   - outputPoint: A point of the crop output (full resolution, top-left origin), such as the
  ///     click a macOS canvas reports through `pointSampling(_:)`.
  ///   - feature: The feature the canvas shows. It is authored over `previewSource.source`; a
  ///     feature of another image samples the wrong pixels.
  ///   - temperatureRange: The temperatures the result stays within, such as the range of the
  ///     host's Temperature control.
  ///   - tintRange: The tints the result stays within.
  ///   - adjustmentRendering: The calculations the adjustments use: the selection the canvas
  ///     renders with (`adjustmentRendering(_:)`).
  @concurrent
  public static func solve(
    at outputPoint: CGPoint,
    in feature: ImageEditorFeature,
    over previewSource: PreviewSource,
    temperatureRange: ClosedRange<Double> = -3000...3000,
    tintRange: ClosedRange<Double> = -100...100,
    adjustmentRendering: AdjustmentRendering = .standard
  ) async -> Result<WhiteBalanceFeature?, Rejection> {
    let preview = previewSource.image
    let imageSize = previewSource.source.pixelSize
    // The canvas fits the crop to the image, so the point is mapped through the crop it draws.
    guard
      let geometry = EditingCanvasCropOutputGeometry(
        crop: CropGuideState(cropFeature: feature.crop, imageSize: imageSize)
      ),
      geometry.outputBounds.contains(outputPoint)
    else {
      return .failure(.outsideImage)
    }
    // Top-left origin, full resolution.
    let sourcePoint = outputPoint.applying(geometry.outputToSourceTransform)
    guard CGRect(origin: .zero, size: imageSize).contains(sourcePoint) else {
      return .failure(.outsideImage)
    }

    // The preview has a bottom-left origin.
    let scale = preview.extent.width / imageSize.width
    let previewPoint = CGPoint(x: sourcePoint.x * scale, y: (imageSize.height - sourcePoint.y) * scale)
    let color: SIMD3<Double>
    do {
      color = try sample(
        effectsBeforeWhiteBalance(feature.effects),
        over: preview,
        imageSize: imageSize,
        at: previewPoint,
        adjustmentRendering: adjustmentRendering
      )
    } catch {
      EditorLog.error(.editingCanvas, "Gray point failed: \(error)")
      return .failure(.outsideImage)
    }

    if let rejection = rejection(of: color) {
      return .failure(rejection)
    }
    return .success(
      whiteBalance(
        neutralizing: color,
        temperatureRange: temperatureRange,
        tintRange: tintRange,
        context: context
      )
    )
  }

  /// The members `Effects.body` evaluates before `whiteBalance`: the preset, exposure and
  /// brightness. Keep it in step with the body; a test checks it against the body's order.
  static func effectsBeforeWhiteBalance(
    _ effects: ImageEditorFeature.Effects
  ) -> ImageEditorFeature.Effects {
    ImageEditorFeature.Effects(
      preset: effects.preset,
      exposure: effects.exposure,
      brightness: effects.brightness
    )
  }

  /// The white balance that makes `color` (RGB in `context`'s working space, as it enters
  /// `whiteBalance`) neutral, within `temperatureRange` and `tintRange`; nil when both values are
  /// within 0.5 of neutral.
  ///
  /// Gauss–Newton on the red and blue ratios to green, with a Jacobian from finite differences
  /// (50 K, 1 tint unit), from neutral or the nearest value the ranges allow. A colour no white
  /// balance within the ranges makes neutral is balanced as far as the ranges allow.
  static func whiteBalance(
    neutralizing color: SIMD3<Double>,
    temperatureRange: ClosedRange<Double>,
    tintRange: ClosedRange<Double>,
    context: CIContext
  ) -> WhiteBalanceFeature? {
    func residual(temperature: Double, tint: Double) -> SIMD2<Double> {
      let balanced = render(
        color,
        through: WhiteBalanceFeature(temperature: temperature, tint: tint),
        context: context
      )
      return SIMD2(balanced.x / balanced.y - 1, balanced.z / balanced.y - 1)
    }
    func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
      min(max(value, range.lowerBound), range.upperBound)
    }

    var temperature = clamped(0, to: temperatureRange)
    var tint = clamped(0, to: tintRange)
    for _ in 0..<12 {
      let r = residual(temperature: temperature, tint: tint)
      guard
        r.x.isFinite,
        r.y.isFinite,
        max(abs(r.x), abs(r.y)) >= 1e-4
      else {
        break
      }
      let byTemperature = (residual(temperature: temperature + 50, tint: tint) - r) / 50
      let byTint = residual(temperature: temperature, tint: tint + 1) - r
      let determinant = byTemperature.x * byTint.y - byTint.x * byTemperature.y
      guard abs(determinant) > 1e-12 else {
        break
      }
      let temperatureStep = (byTint.y * r.x - byTint.x * r.y) / determinant
      let tintStep = (byTemperature.x * r.y - byTemperature.y * r.x) / determinant
      temperature = clamped(temperature - temperatureStep, to: temperatureRange)
      tint = clamped(tint - tintStep, to: tintRange)
    }

    guard abs(temperature) >= 0.5 || abs(tint) >= 0.5 else {
      return nil
    }
    return WhiteBalanceFeature(temperature: temperature, tint: tint)
  }

  /// The working-space colour of `effects`' output over `preview`, averaged over the square of
  /// whole pixels around `point` (preview pixels, bottom-left origin) that lies inside the preview.
  private static func sample(
    _ effects: ImageEditorFeature.Effects,
    over preview: CIImage,
    imageSize: CGSize,
    at point: CGPoint,
    adjustmentRendering: AdjustmentRendering
  ) throws -> SIMD3<Double> {
    let output = try effects.apply(
      to: preview,
      context: FeatureEvaluationContext(
        chainEntryExtent: preview.extent,
        renderScale: EditingCanvasRenderImageFactory.renderScale(
          evaluated: preview.extent.size,
          fullResolution: imageSize
        ),
        adjustmentRendering: adjustmentRendering
      )
    )
    let half = CGFloat(sampleSize / 2)
    let square = CGRect(
      x: point.x.rounded(.down) - half,
      y: point.y.rounded(.down) - half,
      width: CGFloat(sampleSize),
      height: CGFloat(sampleSize)
    )
    .intersection(preview.extent)
    let average = output.applyingFilter(
      "CIAreaAverage",
      parameters: [kCIInputExtentKey: CIVector(cgRect: square)]
    )
    return read(average, context: context)
  }

  /// `color` after `balance`, in `context`'s working space.
  private static func render(
    _ color: SIMD3<Double>,
    through balance: WhiteBalanceFeature,
    context: CIContext
  ) -> SIMD3<Double> {
    let components: [Float] = [Float(color.x), Float(color.y), Float(color.z), 1]
    let image = CIImage(
      bitmapData: components.withUnsafeBytes { Data($0) },
      bytesPerRow: MemoryLayout<Float>.size * 4,
      size: CGSize(width: 1, height: 1),
      format: .RGBAf,
      colorSpace: context.workingColorSpace
    )
    // The recipe applies one filter and never throws.
    let balanced = (try? balance.apply(to: image, context: FeatureEvaluationContext())) ?? image
    return read(balanced, context: context)
  }

  /// The colour of the pixel at the origin of `image`, rendered through `context` without colour
  /// matching, so in its working space.
  private static func read(_ image: CIImage, context: CIContext) -> SIMD3<Double> {
    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      image,
      toBitmap: &pixel,
      rowBytes: MemoryLayout<Float>.size * 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBAf,
      colorSpace: nil
    )
    return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
  }

  /// `.outsideImage` for a colour that is not finite (a NaN pixel of a float image, say), which no
  /// comparison below catches, `.tooDark` below a Display P3 luminance of 0.02 or with a channel
  /// without light, and `.tooBright` with a channel at or above 0.98; nil for a colour a white
  /// balance can be solved from.
  private static func rejection(of color: SIMD3<Double>) -> Rejection? {
    guard color.x.isFinite, color.y.isFinite, color.z.isFinite else {
      return .outsideImage
    }
    let luminance = (color * SIMD3(0.2290, 0.6917, 0.0793)).sum()
    if luminance < 0.02 || color.min() <= 0 {
      return .tooDark
    }
    if color.max() >= 0.98 {
      return .tooBright
    }
    return nil
  }
}
