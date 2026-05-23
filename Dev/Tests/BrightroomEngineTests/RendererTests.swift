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

import MobileCoreServices
import StateGraph
import XCTest

@testable import BrightroomEngine

final class RendererTests: XCTestCase {
  enum ColorSpaces {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  }

  private func assertStandardRGBInputColorSpace(
    _ colorSpace: CGColorSpace?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let colorSpace else {
      XCTFail("Expected input image to have an RGB color space.", file: file, line: line)
      return
    }

    XCTAssertEqual(colorSpace.model, .rgb, file: file, line: line)
    XCTAssertNotEqual(colorSpace, ColorSpaces.displayP3, file: file, line: line)
  }

  func testCropping() throws {
    let imageSource = ImageSource(image: Asset.l1000069.image)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(toFitAspectRatio: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [],
      drawer: []
    )

    let rendered = try renderer.render()
    print(rendered)
  }

  func testV2_InputDisplayP3_no_effects() throws {
    let imageSource = ImageSource(image: Asset.instaLogo.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.displayP3)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let image = try renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_no_effects() throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let image = try renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_effects() throws {
    let imageSource = ImageSource(image: Asset.unsplash3.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    var filter = FilterExposure()
    filter.value = 0.72

    renderer.edit.modifiers = [filter.asAny()]

    let image = try renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_effects_crop() throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    var filter = FilterExposure()
    filter.value = 0.72

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(toFitAspectRatio: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [filter.asAny()],
      drawer: []
    )

    let image = try renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_effects_crop_resizing() throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    var filter = FilterExposure()
    filter.value = 0.72

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(toFitAspectRatio: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [filter.asAny()],
      drawer: []
    )

    let image = try renderer.render(options: .init(resolution: .resize(maxPixelSize: 300), workingColorSpace: ColorSpaces.displayP3)).cgImage

    XCTAssert(image.width == 300 || image.height == 300)
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_rotation_resizing() throws {
    let imageSource = ImageSource(image: Asset.unsplash1.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    assertStandardRGBInputColorSpace(inputCGImage.colorSpace)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.rotation = .angle_90
    crop.updateCropExtent(toFitAspectRatio: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [],
      drawer: []
    )

    let image = try renderer.render(options: .init(resolution: .resize(maxPixelSize: 300), workingColorSpace: ColorSpaces.displayP3)).cgImage

    XCTAssert(image.width == 300 || image.height == 300)
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_drawing() throws {
    let imageSource = ImageSource(image: Asset.leica.image)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(.init(x: 854.0, y: 1766.0, width: 2863.0, height: 2863.0))

    let data = _pixelengine_bundle.path(forResource: "path-data", ofType: nil)
      .map {
        URL(fileURLWithPath: $0)
      }.map {
        try! Data.init(contentsOf: $0)
      }

    let mask = BlurredMask.init(paths: [
      .init(
        brush: .init(color: UIColor(white: 0, alpha: 1), pixelSize: 356.4214711729622),
        path: try NSKeyedUnarchiver.unarchivedObject(ofClass: UIBezierPath.self, from: data!)!
      ),
    ])

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [],
      drawer: [mask]
    )

    let image = try renderer.render(options: .init(resolution: .resize(maxPixelSize: 300), workingColorSpace: ColorSpaces.displayP3)).cgImage

    #if false
    // for debugging quickly
    try UIImage(cgImage: image).jpegData(compressionQuality: 1)?.write(to: URL(fileURLWithPath: "/Users/muukii/Desktop/rendered.jpg"))
    #endif

//    XCTAssert(image.width == 300 || image.height == 300)
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_DisplayP3_to_sRGB() throws {
    let imageSource = ImageSource(image: Asset.instaLogo.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.displayP3)

    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    let image = try renderer.render(options: .init(workingColorSpace: ColorSpaces.displayP3)).cgImage

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)

    let data = ImageTool.makeImageForJPEGOptimizedSharing(image: image)

    let result = UIImage(data: data as Data)!.cgImage

    XCTAssertEqual(result?.colorSpace, ColorSpaces.sRGB)
  }
}

final class RenderCropTests: XCTestCase {

  func testCanonicalizesImageSizeToPixelDimensions() {
    let crop = RenderCrop(
      imageSize: .init(width: 99.999999999, height: 100.2),
      cropExtent: .init(x: 0, y: 0, width: 100, height: 100)
    )

    XCTAssertEqual(crop.imageSize, .init(width: 100, height: 100))
  }

  func testCanonicalizesFractionalOriginInward() {
    let crop = RenderCrop(
      imageSize: .init(width: 100, height: 100),
      cropExtent: .init(x: 0.2, y: 3.4, width: 20.8, height: 30.9)
    )

    XCTAssertEqual(crop.cropRect, .init(x: 1, y: 4, width: 20, height: 30))
    XCTAssertEqual(crop.cropExtent, .init(x: 1, y: 4, width: 20, height: 30))
  }

  func testCanonicalizesFractionalMaxInward() {
    let crop = RenderCrop(
      imageSize: .init(width: 1000, height: 1000),
      cropExtent: .init(x: 0, y: 0, width: 999.8, height: 499.8)
    )

    XCTAssertEqual(crop.cropExtent, .init(x: 0, y: 0, width: 999, height: 499))
  }

  func testTreatsNearIntegersAsIntegers() {
    let crop = RenderCrop(
      imageSize: .init(width: 100, height: 100),
      cropExtent: .init(
        x: 0.000000001,
        y: 0.000000001,
        width: 99.999999998,
        height: 99.999999998
      )
    )

    XCTAssertEqual(crop.cropExtent, .init(x: 0, y: 0, width: 100, height: 100))
  }

  func testClampsOutsideImageBounds() {
    let crop = RenderCrop(
      imageSize: .init(width: 100, height: 100),
      cropExtent: .init(x: -10.4, y: -20.1, width: 150.9, height: 130.2)
    )

    XCTAssertEqual(crop.cropExtent, .init(x: 0, y: 0, width: 100, height: 100))
  }

  func testSubPixelCropFallsBackToNearestSinglePixel() {
    let crop = RenderCrop(
      imageSize: .init(width: 100, height: 100),
      cropExtent: .init(x: 10.2, y: 20.2, width: 0.2, height: 0.2)
    )

    XCTAssertEqual(crop.cropExtent, .init(x: 10, y: 20, width: 1, height: 1))
  }

  func testBrokenCropFallsBackToSinglePixelAtOrigin() {
    let crop = RenderCrop(
      imageSize: .init(width: 100, height: 100),
      cropExtent: .init(
        x: CGFloat.nan,
        y: CGFloat.nan,
        width: CGFloat.nan,
        height: CGFloat.nan
      )
    )

    XCTAssertEqual(crop.cropExtent, CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  func testCanonicalizationIsIdempotent() {
    let first = RenderCrop(
      imageSize: .init(width: 100, height: 100),
      cropExtent: .init(x: 0.2, y: 0.2, width: 99.6, height: 99.6)
    )
    let second = RenderCrop(
      imageSize: first.imageSize,
      cropRect: first.cropRect,
      rotation: first.rotation,
      adjustmentAngle: first.adjustmentAngle
    )

    XCTAssertEqual(second, first)
  }

  func testAspectRatioCropDoesNotIntroduceFractionalRenderRectLoop() {
    var editingCrop = EditingCrop(imageSize: .init(width: 7864, height: 5248))
    editingCrop.updateCropExtent(toFitAspectRatio: .init(width: 4, height: 5))

    let first = RenderCrop(editingCrop)
    let second = RenderCrop(
      imageSize: first.imageSize,
      cropRect: first.cropRect,
      rotation: first.rotation,
      adjustmentAngle: first.adjustmentAngle
    )

    XCTAssertEqual(first, second)
  }

  func testRetainsRotationAndAdjustmentAngle() {
    var editingCrop = EditingCrop(
      imageSize: .init(width: 100, height: 100),
      cropRect: .init(x: 0.2, y: 0.2, width: 99.6, height: 99.6)
    )
    editingCrop.rotation = .angle_90
    editingCrop.adjustmentAngle = .degrees(0.25)

    let crop = RenderCrop(editingCrop)

    XCTAssertEqual(crop.rotation, .angle_90)
    XCTAssertEqual(crop.adjustmentAngle, .degrees(0.25))
  }

  func testEditingCropRenderingEquivalenceUsesPixelCropContract() {
    let initial = EditingCrop(
      imageSize: .init(width: 100, height: 100),
      cropRect: .init(x: 0, y: 0, width: 100, height: 100)
    )
    let nearInteger = EditingCrop(
      imageSize: .init(width: 100, height: 100),
      cropRect: .init(
        x: 0.000000001,
        y: 0.000000001,
        width: 99.999999998,
        height: 99.999999998
      )
    )
    let inwardPixel = EditingCrop(
      imageSize: .init(width: 100, height: 100),
      cropRect: .init(x: 0.2, y: 0, width: 99.8, height: 100)
    )

    XCTAssertTrue(initial.isRenderingEquivalent(to: nearInteger))
    XCTAssertFalse(initial.isRenderingEquivalent(to: inwardPixel))
  }

  func testEditRenderingEquivalenceUsesPixelCropContract() {
    let initial = EditingStack.Edit(
      crop: EditingCrop(
        imageSize: .init(width: 100, height: 100),
        cropRect: .init(x: 0, y: 0, width: 100, height: 100)
      )
    )
    let nearInteger = EditingStack.Edit(
      crop: EditingCrop(
        imageSize: .init(width: 100, height: 100),
        cropRect: .init(
          x: 0.000000001,
          y: 0.000000001,
          width: 99.999999998,
          height: 99.999999998
        )
      )
    )
    let inwardPixel = EditingStack.Edit(
      crop: EditingCrop(
        imageSize: .init(width: 100, height: 100),
        cropRect: .init(x: 0.2, y: 0, width: 99.8, height: 100)
      )
    )

    XCTAssertTrue(initial.isRenderingEquivalent(to: nearInteger))
    XCTAssertFalse(initial.isRenderingEquivalent(to: inwardPixel))
  }
}

final class RenderCropRendererTests: XCTestCase {

  func testFullRenderCropExcludesFractionalBrightEdges() throws {
    let sourceImage = try Self.makeImageWithBrightBorder(size: 16)
    let imageSource = ImageSource(cgImage: sourceImage)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    renderer.edit = .init(
      croppingRect: Self.fractionalCrop(for: sourceImage),
      modifiers: [],
      drawer: []
    )

    let renderedImage = try renderer.render().cgImage

    XCTAssertEqual(renderedImage.width, 14)
    XCTAssertEqual(renderedImage.height, 14)
    try Self.assertEdgesAreDark(renderedImage)
  }

  func testDrawingRenderCropExcludesFractionalBrightEdges() throws {
    let sourceImage = try Self.makeImageWithBrightBorder(size: 16)
    let imageSource = ImageSource(cgImage: sourceImage)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    renderer.edit = .init(
      croppingRect: Self.fractionalCrop(for: sourceImage),
      modifiers: [],
      drawer: [NoOpDrawing()]
    )

    let renderedImage = try renderer.render().cgImage

    XCTAssertEqual(renderedImage.width, 14)
    XCTAssertEqual(renderedImage.height, 14)
    try Self.assertEdgesAreDark(renderedImage)
  }

  func testPreviewCropExcludesFractionalBrightEdges() throws {
    let sourceImage = try Self.makeImageWithBrightBorder(size: 16)
    let stack = EditingStack(
      imageProvider: .init(image: UIImage(cgImage: sourceImage))
    )

    let croppedImage = stack.makeCroppedCIImage(
      sourceImage: sourceImage,
      crop: Self.fractionalCrop(for: sourceImage),
      orientation: .up
    )
    let renderedImage = try XCTUnwrap(
      CIContext().createCGImage(croppedImage, from: croppedImage.extent)
    )

    XCTAssertEqual(renderedImage.width, 14)
    XCTAssertEqual(renderedImage.height, 14)
    try Self.assertEdgesAreDark(renderedImage)
  }

  private static func fractionalCrop(for image: CGImage) -> EditingCrop {
    EditingCrop(
      imageSize: image.size,
      cropRect: .init(
        x: 0.2,
        y: 0.2,
        width: CGFloat(image.width) - 0.4,
        height: CGFloat(image.height) - 0.4
      )
    )
  }

  private static func makeImageWithBrightBorder(size: Int) throws -> CGImage {
    let extent = CGFloat(size)
    let maxCoordinate = CGFloat(size - 1)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try XCTUnwrap(
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

    return try XCTUnwrap(context.makeImage())
  }

  private static func assertEdgesAreDark(
    _ image: CGImage,
    file: StaticString = #filePath,
    line: UInt = #line
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
      XCTAssertLessThan(pixel.maximumRGB, 8, file: file, line: line)
    }
  }

  private static func rgbaPixel(at point: CGPoint, in image: CGImage) throws -> RGBAPixel {
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try XCTUnwrap(
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

    let bytes = try XCTUnwrap(context.data)
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

  private struct NoOpDrawing: GraphicsDrawing {
    func draw(in context: CGContext) {}
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
