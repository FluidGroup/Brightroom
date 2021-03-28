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
import Verge
import XCTest

@testable import BrightroomEngine

final class RendererTests: XCTestCase {
  enum ColorSpaces {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  }

  func testCropping() throws {
    let imageSource = ImageSource(image: Asset.l1000069.image)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(by: .square)

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

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    let image = try renderer.render().cgImageDisplayP3

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_no_effects() throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.sRGB)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    let image = try renderer.render().cgImageDisplayP3

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_effects() throws {
    let imageSource = ImageSource(image: Asset.unsplash3.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.sRGB)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    var filter = FilterExposure()
    filter.value = 0.72

    renderer.edit.modifiers = [filter]

    let image = try renderer.render().cgImageDisplayP3

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_effects_crop() throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.sRGB)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    var filter = FilterExposure()
    filter.value = 0.72

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(by: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [filter],
      drawer: []
    )

    let image = try renderer.render().cgImageDisplayP3

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_effects_crop_resizing() throws {
    let imageSource = ImageSource(image: Asset.unsplash2.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.sRGB)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    var filter = FilterExposure()
    filter.value = 0.72

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(by: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [filter],
      drawer: []
    )

    let image = try renderer.render(options: .init(resolution: .resize(maxPixelSize: 300))).cgImageDisplayP3

    XCTAssert(image.width == 300 || image.height == 300)
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_InputSRGB_rotation_resizing() throws {
    let imageSource = ImageSource(image: Asset.unsplash1.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.sRGB)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.rotation = .angle_90
    crop.updateCropExtent(by: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [],
      drawer: []
    )

    let image = try renderer.render(options: .init(resolution: .resize(maxPixelSize: 300))).cgImageDisplayP3

    XCTAssert(image.width == 300 || image.height == 300)
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_drawing() throws {
    let imageSource = ImageSource(image: Asset.leica.image)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    var crop = EditingCrop(imageSize: imageSource.readImageSize())
//    crop.rotation = .angle_90
    crop.updateCropExtentNormalizing(
      .init(x: 854.0, y: 1766.0, width: 2863.0, height: 2863.0),
      respectingAspectRatio: nil
    )
//    crop.updateCropExtent(by: .square)

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

    let image = try renderer.render(options: .init(resolution: .resize(maxPixelSize: 300))).cgImageDisplayP3

    #if false
    // for debugging quickly
    try UIImage(cgImageDisplayP3: image).jpegData(compressionQuality: 1)?.write(to: URL(fileURLWithPath: "/Users/muukii/Desktop/rendered.jpg"))
    #endif

//    XCTAssert(image.width == 300 || image.height == 300)
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }

  func testV2_DisplayP3_to_sRGB() throws {
    let imageSource = ImageSource(image: Asset.instaLogo.image)

    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.displayP3)

    let renderer = ImageRenderer(source: imageSource, orientation: .up)

    let image = try renderer.render().cgImageDisplayP3

    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)

    let data = ImageTool.makeImageForJPEGOptimizedSharing(image: image)

    let result = UIImage(data: data as Data)!.cgImage

    XCTAssertEqual(result?.colorSpace, ColorSpaces.sRGB)
  }
}
