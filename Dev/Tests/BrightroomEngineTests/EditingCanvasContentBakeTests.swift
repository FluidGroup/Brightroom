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

@testable import BrightroomUI

/// `EditingCanvasContentBake.bake` pre-renders the canvas base/adjusted graphs
/// into a texture so rotation/pan/zoom resample instead of re-evaluating the
/// graph. It must be a faithful drop-in: sampling the baked texture has to match
/// rendering the original image, at the same coordinates. The live canvas can
/// only be seen on device (the Simulator presents black), but this geometry +
/// color equivalence is testable anywhere via a CIContext read-back.
struct EditingCanvasContentBakeTests {

  /// A baked image with a non-zero extent origin must land in the SAME canvas
  /// coordinates and look the same as the source. A coordinate or y-flip
  /// regression moves the gradient and fails the corner comparison.
  @Test func `Baked image matches the source at the same coordinates`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device")
    let commandQueue = try #require(device.makeCommandQueue())
    let workingSpace = EditingCanvasImageProcessing.workingColorSpace
    let ciContext = CIContext(
      mtlCommandQueue: commandQueue,
      options: [.workingColorSpace: workingSpace]
    )

    // Bounded content with a deliberately offset extent and an asymmetric
    // vignette, so origin handling and orientation are both exercised.
    let origin = CGPoint(x: 37, y: 19)
    let size = CGSize(width: 200, height: 140)
    let content = CIImage(color: .init(red: 0.2, green: 0.4, blue: 0.8))
      .cropped(to: CGRect(origin: origin, size: size))
      .applyingFilter("CIVignetteEffect", parameters: [
        kCIInputCenterKey: CIVector(x: origin.x, y: origin.y),
        kCIInputRadiusKey: max(size.width, size.height),
        kCIInputIntensityKey: 1.0,
      ])
      .cropped(to: CGRect(origin: origin, size: size))

    let result = try #require(
      EditingCanvasContentBake.bake(
        content,
        cap: EditingCanvasImageProcessing.contentBakeMaxPixelSize,
        device: device,
        commandQueue: commandQueue,
        ciContext: ciContext,
        pixelFormat: EditingCanvasImageProcessing.colorTextureFormat,
        colorSpace: EditingCanvasImageProcessing.intermediateColorSpace
      )
    )

    // Drop-in: identical extent in canvas coordinates.
    #expect(result.image.extent.origin.x == origin.x)
    #expect(result.image.extent.origin.y == origin.y)
    #expect(abs(result.image.extent.width - size.width) < 1)
    #expect(abs(result.image.extent.height - size.height) < 1)

    // Flush the bake before reading back through a fresh (different-queue) read.
    flush(commandQueue)

    let readContext = CIContext(options: [.workingColorSpace: workingSpace])
    let probes: [CGPoint] = [
      CGPoint(x: origin.x + 4, y: origin.y + 4),                       // bottom-left
      CGPoint(x: origin.x + size.width - 4, y: origin.y + 4),          // bottom-right
      CGPoint(x: origin.x + 4, y: origin.y + size.height - 4),         // top-left
      CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2), // center
    ]
    var maxDelta = 0
    for probe in probes {
      let a = sample(content, at: probe, context: readContext)
      let b = sample(result.image, at: probe, context: readContext)
      for index in 0..<4 {
        maxDelta = max(maxDelta, abs(Int(a[index]) - Int(b[index])))
      }
    }
    // A wrong origin / flip lands a different gradient value at each probe →
    // deltas near 255. A faithful bake differs only by float-texture rounding.
    #expect(maxDelta <= 6, "baked content diverged from source (maxDelta=\(maxDelta))")
  }

  /// The cap downsamples large content; the result must still cover the same
  /// extent (resampled), not collapse or shift.
  @Test func `Bake respects the resolution cap while preserving extent`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device")
    let commandQueue = try #require(device.makeCommandQueue())
    let ciContext = CIContext(mtlCommandQueue: commandQueue, options: [:])

    let big = CGRect(x: 0, y: 0, width: 8000, height: 6000)
    let content = CIImage(color: .init(red: 0.5, green: 0.25, blue: 0.75)).cropped(to: big)

    let result = try #require(
      EditingCanvasContentBake.bake(
        content,
        cap: 2560,
        device: device,
        commandQueue: commandQueue,
        ciContext: ciContext,
        pixelFormat: EditingCanvasImageProcessing.colorTextureFormat,
        colorSpace: EditingCanvasImageProcessing.intermediateColorSpace
      )
    )

    // Backing texture capped on the longest side.
    #expect(result.texture.width <= 2560)
    #expect(result.texture.height <= 2560)
    #expect(max(result.texture.width, result.texture.height) == 2560)
    // But the CIImage still spans the original extent.
    #expect(abs(result.image.extent.width - big.width) < 2)
    #expect(abs(result.image.extent.height - big.height) < 2)
  }

  // MARK: - Helpers

  private func flush(_ queue: MTLCommandQueue) {
    let cb = queue.makeCommandBuffer()
    cb?.commit()
    cb?.waitUntilCompleted()
  }

  private func sample(
    _ image: CIImage,
    at point: CGPoint,
    context: CIContext
  ) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
      image,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
    return pixel
  }
}
