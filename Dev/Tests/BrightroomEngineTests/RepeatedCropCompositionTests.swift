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
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Pins the repeatable-crop semantics from `docs/vision-of-editing.md`: a crop
/// is a domain feature evaluated in stack order, and a downstream crop operates
/// on the *already-cropped* result of the upstream crop.
///
/// `CropFeature.apply` interprets `cropRect` relative to the running image's
/// extent, so `Crop A -> Crop B` must compose to the same pixels as the single
/// crop that selects `B`'s window mapped back through `A`'s origin. These tests
/// evaluate through `FeatureGraphCompiler` (the shared preview/export path), so
/// they prove the engine already supports the multi-crop stack the parametric
/// feature editor builds on.
struct RepeatedCropCompositionTests {

  private static let context = CIContext()

  @Test func `Second crop operates on the first crop's cropped domain`() throws {
    // A 40x40 gradient source: each pixel encodes its position, so any
    // misalignment between the composed path and the equivalent single crop
    // surfaces as a pixel mismatch.
    let source = try Self.gradientImage(width: 40, height: 40)

    // Crop A keeps source x in [10,30), y in [10,30) -> a 20x20 domain at origin.
    let cropA = CropFeature(
      id: FeatureID(rawValue: "test.crop.a"),
      cropRect: CGRect(x: 10, y: 10, width: 20, height: 20)
    )
    // Crop B selects x in [5,15), y in [5,15) of A's 20x20 domain, i.e. source
    // x in [15,25), y in [15,25).
    let cropB = CropFeature(
      id: FeatureID(rawValue: "test.crop.b"),
      cropRect: CGRect(x: 5, y: 5, width: 10, height: 10)
    )
    // The single crop selecting the same absolute source window.
    let equivalent = CropFeature(
      id: FeatureID(rawValue: "test.crop.single"),
      cropRect: CGRect(x: 15, y: 15, width: 10, height: 10)
    )

    let composed = try Self.render(source: source, crops: [cropA, cropB])
    let single = try Self.render(source: source, crops: [equivalent])

    #expect(composed.width == 10)
    #expect(composed.height == 10)
    #expect(single.width == 10)
    #expect(single.height == 10)

    let mismatch = Self.firstPixelMismatch(composed, single)
    #expect(
      mismatch == nil,
      "Composed Crop A -> Crop B must equal the equivalent single crop; first mismatch: \(mismatch as Any)"
    )
  }

  @Test func `Repeated crops chain to the final selected window`() throws {
    let source = try Self.gradientImage(width: 40, height: 40)

    // Three stacked crops narrowing the domain each time.
    let c1 = CropFeature(id: FeatureID(rawValue: "c1"), cropRect: CGRect(x: 4, y: 4, width: 32, height: 32))
    let c2 = CropFeature(id: FeatureID(rawValue: "c2"), cropRect: CGRect(x: 4, y: 4, width: 16, height: 16))
    let c3 = CropFeature(id: FeatureID(rawValue: "c3"), cropRect: CGRect(x: 2, y: 2, width: 8, height: 8))
    // Absolute source window: x/y start 4+4+2 = 10, size 8.
    let equivalent = CropFeature(id: FeatureID(rawValue: "single"), cropRect: CGRect(x: 10, y: 10, width: 8, height: 8))

    let composed = try Self.render(source: source, crops: [c1, c2, c3])
    let single = try Self.render(source: source, crops: [equivalent])

    #expect(composed.width == 8)
    #expect(composed.height == 8)
    #expect(Self.firstPixelMismatch(composed, single) == nil)
  }

  @Test func `Prefix evaluation stops before the targeted crop's input domain`() throws {
    // The middle crop's input domain (everything before crop B) must equal the
    // result of crop A alone — the domain a parametric editor previews while
    // editing crop B.
    let source = try Self.gradientImage(width: 40, height: 40)

    let cropA = CropFeature(id: FeatureID(rawValue: "a"), cropRect: CGRect(x: 8, y: 8, width: 24, height: 24))
    let cropB = CropFeature(id: FeatureID(rawValue: "b"), cropRect: CGRect(x: 4, y: 4, width: 12, height: 12))

    let document = EditingDocument(mainTree: MainTree(features: [cropA, cropB].map(MainFeature.domain)))

    // Prefix of 1 feature = only crop A applied.
    let prefixOutput = try FeatureGraphCompiler().makeOutput(
      from: source,
      document: document,
      prefixFeatureCount: 1
    )
    let prefixImage = try #require(Self.context.createCGImage(prefixOutput.image, from: prefixOutput.image.extent))

    // The equivalent: crop A alone.
    let onlyA = try Self.render(source: source, crops: [cropA])

    #expect(prefixImage.width == 24)
    #expect(prefixImage.height == 24)
    #expect(Self.firstPixelMismatch(prefixImage, onlyA) == nil)

    // A nil prefix evaluates the whole document (both crops).
    let full = try Self.render(source: source, crops: [cropA, cropB])
    #expect(full.width == 12)
    #expect(full.height == 12)
  }

  // MARK: - Helpers

  private static func render(source: CIImage, crops: [CropFeature]) throws -> CGImage {
    let document = EditingDocument(
      mainTree: MainTree(features: crops.map(MainFeature.domain))
    )
    let output = try FeatureGraphCompiler().makeOutput(from: source, document: document)
    let extent = output.image.extent
    return try #require(context.createCGImage(output.image, from: extent))
  }

  /// A gradient where red encodes x and green encodes y, so pixel identity is
  /// position-dependent.
  private static func gradientImage(width: Int, height: Int) throws -> CIImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8(min(255, x * 6))
        pixels[offset + 1] = UInt8(min(255, y * 6))
        pixels[offset + 2] = 128
        pixels[offset + 3] = 255
      }
    }
    let cgContext = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    let cgImage = try #require(cgContext.makeImage())
    return CIImage(cgImage: cgImage)
  }

  /// Returns the first (x, y) whose RGBA differs beyond an 8-bit tolerance, or
  /// nil when the images match.
  private static func firstPixelMismatch(_ a: CGImage, _ b: CGImage) -> (x: Int, y: Int)? {
    guard a.width == b.width, a.height == b.height else {
      return (x: -1, y: -1)
    }
    let width = a.width
    let height = a.height
    let pa = rgbaBytes(a)
    let pb = rgbaBytes(b)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        for channel in 0..<4 where abs(Int(pa[offset + channel]) - Int(pb[offset + channel])) > 2 {
          return (x: x, y: y)
        }
      }
    }
    return nil
  }

  private static func rgbaBytes(_ image: CGImage) -> [UInt8] {
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
    return pixels
  }
}
