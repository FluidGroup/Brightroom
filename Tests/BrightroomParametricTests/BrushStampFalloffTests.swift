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
import Testing

@testable import BrightroomParametric

/// Pins the canonical brush-stamp falloff produced by the parametric CIKernel
/// rasterizer (`FeatureGraphCompiler.renderMask`, the export/preview path).
///
/// The falloff is `BrushStampFalloff.metalh`'s `brushStampAlpha`:
/// `alpha = (normalizedDistance > 1) ? 0
///        : (hardness < 0.999 ? 1 - smoothstep(clamp(hardness,0,0.998), 1, d) : 1)
///          * clamp(opacity, 0, 1)`
/// where `normalizedDistance = distance / radius` and `radius = diameter / 2`.
///
/// The kernel returns `float4(a, a, a, a)`, so alpha == red == any channel; the
/// tests read the red channel. A single stamp is rendered centered so the y-up
/// (Core Image working space) vs y-down (CGImage) origin distinction is
/// symmetric and does not affect the asserted points.
struct BrushStampFalloffTests {

  private static let context = CIContext()

  private static let extentSize = 64
  private static let center = CGPoint(x: 32, y: 32)
  private static let diameter: Double = 40  // radius 20

  // MARK: - Canonical shape (soft brush so the falloff is observable)

  /// Center alpha must reach `opacity * 255` (within an 8-bit / AA tolerance),
  /// a point clearly outside the radius must be ~0, and a mid-radius point must
  /// fall strictly between the two — i.e. the falloff is monotonic-ish.
  @Test func `Center full outside zero mid radius between`() throws {
    let opacity: Double = 1
    let image = try Self.renderSingleStamp(hardness: 0, opacity: opacity)

    // Center: full opacity.
    let centerValue = Self.red(in: image, x: 32, y: 32)
    #expect(abs(Int(centerValue) - Int(opacity * 255)) <= 6, "center should be ~opacity*255")

    // Clearly outside the radius (distance 28 > radius 20): zero.
    let outsideValue = Self.red(in: image, x: 60, y: 32)
    #expect(Int(outsideValue) <= 4, "pixel outside the radius should be ~0")

    // Mid-radius (distance 10, normalizedDistance 0.5): strictly between.
    let midValue = Self.red(in: image, x: 42, y: 32)
    #expect(Int(midValue) > Int(outsideValue), "mid-radius should exceed the outside value")
    #expect(Int(midValue) < Int(centerValue), "mid-radius should be below the center value")
  }

  /// The falloff is monotonically non-increasing as distance grows along a ray
  /// from the stamp center.
  @Test func `Falloff is monotonic along ray`() throws {
    let image = try Self.renderSingleStamp(hardness: 0, opacity: 1)

    // Sample x from the center outward; alpha must never increase.
    var previous = 256
    for x in stride(from: 32, through: 56, by: 2) {
      let value = Int(Self.red(in: image, x: x, y: 32))
      #expect(value <= previous + 2, "falloff increased at x=\(x): \(value) > \(previous)")
      previous = value
    }
  }

  // MARK: - Hardness controls edge sharpness

  /// At a near-edge point, hardness 1.0 (hard) keeps full alpha while hardness
  /// 0.0 (soft) has already faded — so the hard edge is sharper.
  @Test func `Hard edge is sharper than soft edge`() throws {
    let hard = try Self.renderSingleStamp(hardness: 1, opacity: 1)
    let soft = try Self.renderSingleStamp(hardness: 0, opacity: 1)

    // Near-edge point: distance 17 from center -> normalizedDistance 0.85.
    let nearEdge = (x: 49, y: 32)

    let hardValue = Int(Self.red(in: hard, x: nearEdge.x, y: nearEdge.y))
    let softValue = Int(Self.red(in: soft, x: nearEdge.x, y: nearEdge.y))

    // Hard brush holds full alpha right up to the radius edge.
    #expect(hardValue > 240, "hard near-edge should remain ~full alpha")
    // Soft brush has faded substantially by the same point.
    #expect(softValue < hardValue - 40, "soft near-edge should be clearly weaker than hard")
  }

  // MARK: - Rendering

  private static func renderSingleStamp(hardness: Double, opacity: Double) throws -> CGImage {
    let extent = CGRect(x: 0, y: 0, width: extentSize, height: extentSize)
    let maskTree = MaskTree(
      root: .brush(
        BrushMask(
          strokes: [
            BrushMaskStroke(
              stamps: [center],
              brush: BrushMaskBrush(diameter: diameter, hardness: hardness, opacity: opacity)
            )
          ]
        )
      )
    )

    let ciImage = try FeatureGraphCompiler().renderMask(maskTree, extent: extent)
    return try #require(context.createCGImage(ciImage, from: extent))
  }

  /// Reads the red channel at the given pixel. The brush kernel writes
  /// `float4(a, a, a, a)`, so red equals the mask alpha.
  private static func red(in image: CGImage, x: Int, y: Int) -> UInt8 {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let clampedX = min(max(x, 0), width - 1)
    let clampedY = min(max(y, 0), height - 1)
    let offset = (clampedY * width + clampedX) * 4
    return pixels[offset]
  }
}
