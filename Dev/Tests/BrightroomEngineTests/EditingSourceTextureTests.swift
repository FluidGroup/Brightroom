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
import CoreImage
import Foundation
import Metal
import Testing

@testable import BrightroomEngine

/// `EditingSourcePreparation.makeGPUResidentSource` must be a faithful drop-in
/// for the CGImage-backed editing source it replaces. The on-screen result can
/// only be seen on a real device (the Simulator canvas presents black), but the
/// thing that could silently break — orientation and color — is testable
/// anywhere via a CIContext read-back.
///
/// Each test renders an asymmetric four-quadrant image through both the new
/// texture-backed path and the old `CIImage(cgImage:).oriented()` reference and
/// asserts they match pixel-for-pixel. A y-flip or transpose regression (the
/// exact failure mode that retired the previous `MTKTextureLoader` path) would
/// swap quadrants and fail here.
struct EditingSourceTextureTests {

  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  @Test(
    arguments: [
      CGImagePropertyOrientation.up,
      CGImagePropertyOrientation.right,
      CGImagePropertyOrientation.down,
      CGImagePropertyOrientation.left,
      CGImagePropertyOrientation.upMirrored,
      CGImagePropertyOrientation.rightMirrored,
      CGImagePropertyOrientation.downMirrored,
      CGImagePropertyOrientation.leftMirrored,
    ],
    // 8-bit exercises the adaptive rgba8Unorm path; 16-bit exercises rgba16Float.
    [8, 16]
  )
  func `Texture-backed source matches CIImage(cgImage:).oriented()`(
    orientation: CGImagePropertyOrientation,
    bitsPerComponent: Int
  ) throws {
    let source = makeQuadrantImage(size: 32, bitsPerComponent: bitsPerComponent)
    #expect(source.bitsPerComponent == bitsPerComponent)

    let candidate = try #require(
      EditingSourcePreparation.makeGPUResidentSource(
        cgImage: source,
        orientation: orientation
      ),
      "Metal device unavailable — cannot verify the texture-backed source"
    )
    let reference = CIImage(cgImage: source).oriented(orientation)

    // Drop-in requires the same extent (origin at zero, matching dimensions).
    #expect(candidate.extent.width == reference.extent.width)
    #expect(candidate.extent.height == reference.extent.height)
    #expect(candidate.extent.origin == .zero)

    let context = CIContext(options: [.workingColorSpace: sRGB])
    let width = Int(reference.extent.width)
    let height = Int(reference.extent.height)

    let candidatePixels = render(candidate, context: context, width: width, height: height)
    let referencePixels = render(reference, context: context, width: width, height: height)

    var maxDelta = 0
    for index in candidatePixels.indices {
      maxDelta = max(maxDelta, abs(Int(candidatePixels[index]) - Int(referencePixels[index])))
    }
    // Allow a small tolerance for the float-texture round-trip vs the direct
    // CGImage render; a flip/transpose bug produces deltas of ~255, not ~2.
    #expect(
      maxDelta <= 4,
      "texture-backed source diverged from the CGImage reference (maxDelta=\(maxDelta)) for \(orientation)"
    )
  }

  // MARK: - Helpers

  /// A 2x2 grid of distinct solid colors so any orientation error is visible.
  private func makeQuadrantImage(size: Int, bitsPerComponent: Int = 8) -> CGImage {
    let bitmapInfo: UInt32 = bitsPerComponent == 16
      ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
      : CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(
      data: nil,
      width: size,
      height: size,
      bitsPerComponent: bitsPerComponent,
      bytesPerRow: 0,
      space: sRGB,
      bitmapInfo: bitmapInfo
    )!

    let half = CGFloat(size) / 2
    // Bottom-left, bottom-right, top-left, top-right (CGContext is bottom-up).
    let cells: [(CGRect, CGColor)] = [
      (CGRect(x: 0, y: 0, width: half, height: half), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
      (CGRect(x: half, y: 0, width: half, height: half), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
      (CGRect(x: 0, y: half, width: half, height: half), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
      (CGRect(x: half, y: half, width: half, height: half), CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
    ]
    for (rect, color) in cells {
      context.setFillColor(color)
      context.fill(rect)
    }
    return context.makeImage()!
  }

  private func render(
    _ image: CIImage,
    context: CIContext,
    width: Int,
    height: Int
  ) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    context.render(
      image,
      toBitmap: &pixels,
      rowBytes: width * 4,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      format: .RGBA8,
      colorSpace: sRGB
    )
    return pixels
  }
}
