//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import Foundation
import MobileCoreServices
import StateGraph
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

struct RendererTests {
  enum ColorSpaces {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  }

  private func assertStandardRGBInputColorSpace(
    _ colorSpace: CGColorSpace?,
    sourceLocation: Testing.SourceLocation = Testing.SourceLocation(
      fileID: #fileID,
      filePath: #filePath,
      line: #line,
      column: #column
    )
  ) {
    guard let colorSpace else {
      Issue.record("Expected input image to have an RGB color space.", sourceLocation: sourceLocation)
      return
    }

    #expect(colorSpace.model == .rgb, sourceLocation: sourceLocation)
    #expect(colorSpace != ColorSpaces.displayP3, sourceLocation: sourceLocation)
  }

  @Test func cropping() async throws {
    let imageSource = ImageSource(image: Asset.l1000069.image)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let size = imageSource.readImageSize()
    let crop = CropFeature.test(
      imageSize: size,
      cropRect: CropGeometry.cropRect(toFitAspectRatio: .square, in: size)
    )

    renderer.edit = .make(crop: crop, orientedImageSize: size)

    let rendered = try await renderer.render()
    print(rendered)
  }

  @Test func `V2 input display P3 no effects`() async throws {
    let imageSource = ImageSource(image: Asset.instaLogo.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    #expect(inputCGImage.colorSpace == ColorSpaces.displayP3)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let image = try await renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    #expect(image.colorSpace == ColorSpaces.displayP3)
  }

  @Test func `V2 input sRGB no effects`() async throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let image = try await renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    #expect(image.colorSpace == ColorSpaces.displayP3)
  }

  @Test func `V2 input sRGB effects`() async throws {
    let imageSource = ImageSource(image: Asset.unsplash3.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let filter = ExposureFeature(value: 0.72)

    renderer.edit = .make(
      crop: CropFeature.test(imageSize: imageSource.readImageSize()),
      orientedImageSize: imageSource.readImageSize(),
      effects: EffectPipeline(effects: [filter])
    )

    let image = try await renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    #expect(image.colorSpace == ColorSpaces.displayP3)
  }

  @Test func `V2 input sRGB effects crop`() async throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let filter = ExposureFeature(value: 0.72)

    let size = imageSource.readImageSize()
    let crop = CropFeature.test(
      imageSize: size,
      cropRect: CropGeometry.cropRect(toFitAspectRatio: .square, in: size)
    )

    renderer.edit = .make(crop: crop, orientedImageSize: size, effects: EffectPipeline(effects: [filter]))

    let image = try await renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    #expect(image.colorSpace == ColorSpaces.displayP3)
  }

  @Test func `V2 input sRGB effects crop resizing`() async throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let filter = ExposureFeature(value: 0.72)

    let size = imageSource.readImageSize()
    let crop = CropFeature.test(
      imageSize: size,
      cropRect: CropGeometry.cropRect(toFitAspectRatio: .square, in: size)
    )

    renderer.edit = .make(crop: crop, orientedImageSize: size, effects: EffectPipeline(effects: [filter]))

    let image = try await renderer.render(options: .init(resolution: .resize(maxPixelSize: 300), workingColorSpace: ColorSpaces.displayP3)).cgImage

    #expect(image.width == 300 || image.height == 300)
    #expect(image.colorSpace == ColorSpaces.displayP3)
  }

  @Test func `V2 input sRGB rotation resizing`() async throws {
    let imageSource = ImageSource(image: Asset.unsplash1.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let size = imageSource.readImageSize()
    let crop = CropFeature.test(
      imageSize: size,
      cropRect: CropGeometry.cropRect(toFitAspectRatio: .square, in: size),
      rotation: .quarterCW
    )

    renderer.edit = .make(crop: crop, orientedImageSize: size)

    let image = try await renderer.render(options: .init(resolution: .resize(maxPixelSize: 300), workingColorSpace: ColorSpaces.displayP3)).cgImage

    #expect(image.width == 300 || image.height == 300)
    #expect(image.colorSpace == ColorSpaces.displayP3)
  }

  @Test func `V2 display P3 to sRGB`() async throws {
    let imageSource = ImageSource(image: Asset.instaLogo.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    #expect(inputCGImage.colorSpace == ColorSpaces.displayP3)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let image = try await renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    #expect(image.colorSpace == ColorSpaces.displayP3)

    let data = ImageTool.makeImageForJPEGOptimizedSharing(image: image)

    let result = UIImage(data: data as Data)!.cgImage

    #expect(result?.colorSpace == ColorSpaces.sRGB)
  }
}

struct RenderCropTests {

  @Test func `canonicalizes image size to pixel dimensions`() {
    let crop = RenderCrop(
      cropRectYDown: .init(x: 0, y: 0, width: 100, height: 100),
      imageSize: .init(width: 99.999999999, height: 100.2)
    )

    #expect(crop.imageSize == .init(width: 100, height: 100))
  }

  @Test func `canonicalizes fractional origin inward`() {
    let crop = RenderCrop(
      cropRectYDown: .init(x: 0.2, y: 3.4, width: 20.8, height: 30.9),
      imageSize: .init(width: 100, height: 100)
    )

    #expect(crop.cropRect == .init(x: 1, y: 4, width: 20, height: 30))
    #expect(crop.cropExtent == .init(x: 1, y: 4, width: 20, height: 30))
  }

  @Test func `canonicalizes fractional max inward`() {
    let crop = RenderCrop(
      cropRectYDown: .init(x: 0, y: 0, width: 999.8, height: 499.8),
      imageSize: .init(width: 1000, height: 1000)
    )

    #expect(crop.cropExtent == .init(x: 0, y: 0, width: 999, height: 499))
  }

  @Test func `treats near integers as integers`() {
    let crop = RenderCrop(
      cropRectYDown: .init(
        x: 0.000000001,
        y: 0.000000001,
        width: 99.999999998,
        height: 99.999999998
      ),
      imageSize: .init(width: 100, height: 100)
    )

    #expect(crop.cropExtent == .init(x: 0, y: 0, width: 100, height: 100))
  }

  @Test func `clamps outside image bounds`() {
    let crop = RenderCrop(
      cropRectYDown: .init(x: -10.4, y: -20.1, width: 150.9, height: 130.2),
      imageSize: .init(width: 100, height: 100)
    )

    #expect(crop.cropExtent == .init(x: 0, y: 0, width: 100, height: 100))
  }

  @Test func `sub pixel crop falls back to nearest single pixel`() {
    let crop = RenderCrop(
      cropRectYDown: .init(x: 10.2, y: 20.2, width: 0.2, height: 0.2),
      imageSize: .init(width: 100, height: 100)
    )

    #expect(crop.cropExtent == .init(x: 10, y: 20, width: 1, height: 1))
  }

  @Test func `broken crop falls back to single pixel at origin`() {
    let crop = RenderCrop(
      cropRectYDown: .init(
        x: CGFloat.nan,
        y: CGFloat.nan,
        width: CGFloat.nan,
        height: CGFloat.nan
      ),
      imageSize: .init(width: 100, height: 100)
    )

    #expect(crop.cropExtent == CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  @Test func `canonicalization is idempotent`() {
    let first = RenderCrop(
      cropRectYDown: .init(x: 0.2, y: 0.2, width: 99.6, height: 99.6),
      imageSize: .init(width: 100, height: 100)
    )
    let second = RenderCrop(
      imageSize: first.imageSize,
      cropRect: first.cropRect,
      rotation: first.rotation,
      straightenRadians: first.straightenRadians
    )

    #expect(second == first)
  }

  @Test func `aspect ratio crop does not introduce fractional render rect loop`() {
    let imageSize = CGSize(width: 7864, height: 5248)
    let cropRect = CropGeometry.cropRect(toFitAspectRatio: .init(width: 4, height: 5), in: imageSize)

    let first = RenderCrop(cropRectYDown: cropRect, imageSize: imageSize)
    let second = RenderCrop(
      imageSize: first.imageSize,
      cropRect: first.cropRect,
      rotation: first.rotation,
      straightenRadians: first.straightenRadians
    )

    #expect(first == second)
  }

  @Test func `retains rotation and adjustment angle`() {
    let crop = RenderCrop(
      cropRectYDown: .init(x: 0.2, y: 0.2, width: 99.6, height: 99.6),
      imageSize: .init(width: 100, height: 100),
      rotation: .quarterCW,
      straightenRadians: 0.25 * .pi / 180
    )

    #expect(crop.rotation == .quarterCW)
    #expect(abs(crop.straightenRadians - 0.25 * .pi / 180) <= 1e-12)
  }

  @Test func `edit rendering equivalence uses pixel crop contract`() {
    let initial = EditingStack.Edit.test(
      imageSize: .init(width: 100, height: 100),
      cropRect: .init(x: 0, y: 0, width: 100, height: 100)
    )
    let nearInteger = EditingStack.Edit.test(
      imageSize: .init(width: 100, height: 100),
      cropRect: .init(
        x: 0.000000001,
        y: 0.000000001,
        width: 99.999999998,
        height: 99.999999998
      )
    )
    let inwardPixel = EditingStack.Edit.test(
      imageSize: .init(width: 100, height: 100),
      cropRect: .init(x: 0.2, y: 0, width: 99.8, height: 100)
    )

    #expect(initial.isRenderingEquivalent(to: nearInteger))
    #expect(!initial.isRenderingEquivalent(to: inwardPixel))
  }
}

/// Pins the shared y-flip + integer-snap contract on `CropFeature` that UI crop
/// commits (`CropEditingState`) and the engine bridge both flow through. If these
/// drift, `isRenderingEquivalent` oscillates and the live crop jitters / reverts.
struct CropFeatureDisplaySpaceTests {

  @Test func `display rect flip maps y-down top-left to y-up bottom-left`() {
    let imageSize = CGSize(width: 200, height: 100)
    // y-down display rect anchored at the top-left of the image.
    let feature = CropFeature(
      displayCropRect: .init(x: 10, y: 20, width: 80, height: 30),
      imageSize: imageSize
    )
    // Stored (y-up) rect: top edge (display y=20) becomes the far edge from the
    // bottom: maxY = 100 - 20 = 80, so minY = 80 - 30 = 50.
    #expect(feature.cropRect == .init(x: 10, y: 50, width: 80, height: 30))
  }

  @Test func `display rect round trip is stable`() {
    let imageSize = CGSize(width: 7864, height: 5248)
    let cases: [(CGRect, QuarterTurn, Double)] = [
      (.init(x: 0, y: 0, width: 7864, height: 5248), .zero, 0),
      (.init(x: 100, y: 200, width: 4000, height: 3000), .quarterCW, 0),
      (.init(x: 1745.4, y: 0.2, width: 4373.6, height: 5247.8), .half, 0.02),
      (.init(x: 12, y: 34, width: 56, height: 78), .quarterCCW, -0.05),
    ]

    for (displayRect, rotation, straighten) in cases {
      let feature = CropFeature(
        displayCropRect: displayRect,
        imageSize: imageSize,
        rotation: rotation,
        straighten: straighten
      )
      // Re-seeding the working model from the stored crop and re-committing must
      // be a fixed point — otherwise document-follow fights the live viewport.
      let reseeded = CropFeature(
        id: feature.id,
        displayCropRect: feature.displayCropRect(imageSize: imageSize),
        imageSize: imageSize,
        rotation: feature.rotation,
        straighten: feature.straightenRadians
      )
      #expect(reseeded.cropRect == feature.cropRect, "rect @ \(rotation)")
      #expect(reseeded.rotation == feature.rotation, "rotation @ \(rotation)")
      #expect(reseeded.straightenRadians == feature.straightenRadians, "straighten @ \(rotation)")
    }
  }

}

struct RenderCropRendererTests {

  @Test func `full render crop excludes fractional bright edges`() async throws {
    let sourceImage = try Self.makeImageWithBrightBorder(size: 16)
    let imageSource = ImageSource(cgImage: sourceImage)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    renderer.edit = .make(crop: Self.fractionalCrop(for: sourceImage), orientedImageSize: sourceImage.size)

    let renderedImage = try await renderer.render().cgImage

    #expect(renderedImage.width == 14)
    #expect(renderedImage.height == 14)
    try Self.assertEdgesAreDark(renderedImage)
  }

  @Test func `Core Image render crop excludes fractional bright edges`() async throws {
    let sourceImage = try Self.makeImageWithBrightBorder(size: 16)
    let imageSource = ImageSource(cgImage: sourceImage)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    renderer.edit = .make(crop: Self.fractionalCrop(for: sourceImage), orientedImageSize: sourceImage.size)

    // The crop is evaluated as a domain feature in the single Core Image
    // rendering path; this asserts that path excludes the fractional bright
    // border (the crop snaps to integer pixels).
    let renderedImage = try await renderer.render(
      options: .init(workingColorSpace: CGColorSpaceCreateDeviceRGB())
    ).cgImage

    #expect(renderedImage.width == 14)
    #expect(renderedImage.height == 14)
    try Self.assertEdgesAreDark(renderedImage)
  }

  /// The parametric crop path must reproduce the engine's `croppedWithColorspace`
  /// rotation — the pre-unification behavior. This pins the rotation SIGN, which
  /// the dimension-only rotation test cannot catch (both signs share dimensions).
  @Test func `parametric crop rotation matches engine oracle`() async throws {
    let source = try Self.makeAsymmetricMarkerImage(width: 8, height: 12)
    let imageSource = ImageSource(cgImage: source)
    let oriented = try source.oriented(.up)

    for rotation in QuarterTurn.allCases {
      let crop = CropFeature.test(imageSize: source.size, rotation: rotation)

      let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)
      renderer.edit = .make(crop: crop, orientedImageSize: source.size)
      let parametric = try await renderer.render().cgImage

      let oracle = try oriented.croppedWithColorspace(
        to: crop.renderCrop(orientedImageSize: oriented.size)
      )

      #expect(parametric.width == oracle.width, "width @ \(rotation)")
      #expect(parametric.height == oracle.height, "height @ \(rotation)")

      for x in stride(from: 0, to: min(parametric.width, oracle.width), by: 2) {
        for y in stride(from: 0, to: min(parametric.height, oracle.height), by: 2) {
          let a = try Self.rgbaPixel(at: CGPoint(x: x, y: y), in: parametric)
          let b = try Self.rgbaPixel(at: CGPoint(x: x, y: y), in: oracle)
          #expect(
            abs(Int(a.red) - Int(b.red)) <= 24,
            "luma (\(x),\(y)) @ \(rotation): parametric \(a.red) vs oracle \(b.red)"
          )
        }
      }
    }
  }

  private static func fractionalCrop(for image: CGImage) -> CropFeature {
    CropFeature.test(
      imageSize: image.size,
      cropRect: .init(
        x: 0.2,
        y: 0.2,
        width: CGFloat(image.width) - 0.4,
        height: CGFloat(image.height) - 0.4
      )
    )
  }

  private static func makeAsymmetricMarkerImage(width: Int, height: Int) throws -> CGImage {
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    )
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A single bright quadrant — asymmetric in both axes, so a wrong rotation
    // sign (90° vs 270°) moves it to a different corner and the test fails.
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2))
    return try #require(context.makeImage())
  }

  private static func makeImageWithBrightBorder(size: Int) throws -> CGImage {
    let extent = CGFloat(size)
    let maxCoordinate = CGFloat(size - 1)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(
      CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    )

    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(.init(x: 0, y: 0, width: extent, height: extent))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(.init(x: 0, y: 0, width: extent, height: 1))
    context.fill(.init(x: 0, y: maxCoordinate, width: extent, height: 1))
    context.fill(.init(x: 0, y: 0, width: 1, height: extent))
    context.fill(.init(x: maxCoordinate, y: 0, width: 1, height: extent))

    return try #require(context.makeImage())
  }

  private static func assertEdgesAreDark(
    _ image: CGImage,
    sourceLocation: Testing.SourceLocation = Testing.SourceLocation(
      fileID: #fileID,
      filePath: #filePath,
      line: #line,
      column: #column
    )
  ) throws {
    let maxX = CGFloat(image.width - 1)
    let maxY = CGFloat(image.height - 1)
    let midX = CGFloat(image.width / 2)
    let midY = CGFloat(image.height / 2)
    let points = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: maxX, y: 0),
      CGPoint(x: 0, y: maxY),
      CGPoint(x: maxX, y: maxY),
      CGPoint(x: midX, y: 0),
      CGPoint(x: midX, y: maxY),
      CGPoint(x: 0, y: midY),
      CGPoint(x: maxX, y: midY),
    ]

    for point in points {
      let pixel = try rgbaPixel(at: point, in: image)
      #expect(pixel.maximumRGB < 8, sourceLocation: sourceLocation)
    }
  }

  private static func rgbaPixel(at point: CGPoint, in image: CGImage) throws -> RGBAPixel {
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(
      CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    )

    context.draw(image, in: .init(origin: .zero, size: image.size))

    let bytes = try #require(context.data)
      .assumingMemoryBound(to: UInt8.self)
    let x = Int(point.x)
    let y = Int(point.y)
    let index = ((y * image.width) + x) * 4
    return RGBAPixel(
      red: bytes[index],
      green: bytes[index + 1],
      blue: bytes[index + 2],
      alpha: bytes[index + 3]
    )
  }

  private struct RGBAPixel {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    var maximumRGB: UInt8 {
      max(red, green, blue)
    }
  }
}
