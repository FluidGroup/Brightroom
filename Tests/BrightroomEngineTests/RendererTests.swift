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

import XCTest
import Verge

@testable import BrightroomEngine

final class RendererTests: XCTestCase {
  
  enum ColorSpaces {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  }
  
  func testCropping() {
    
    let imageSource = ImageSource(image: Asset.l1000069.image)
    
    let renderer = ImageRenderer(source: imageSource, orientation: .up)
    
    var crop = EditingCrop(imageSize: imageSource.readImageSize())
    crop.updateCropExtent(by: .square)

    renderer.edit = .init(
      croppingRect: crop,
      modifiers: [],
      drawer: []
    )
    
    let image = renderer.render()
    print(image)
  }
  
  func testV2_InputDisplayP3_no_effects() throws {
    
    let imageSource = ImageSource(image: Asset.instaLogo.image)
    
    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.displayP3)
    
    let renderer = ImageRenderer(source: imageSource, orientation: .up)
    
    let image = try renderer.renderRevison2()
    
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }
  
  func testV2_InputSRGB_no_effects() throws {
    
    let imageSource = ImageSource(image: Asset.unsplash2.image)
    
    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.sRGB)
    
    let renderer = ImageRenderer(source: imageSource, orientation: .up)
    
    let image = try renderer.renderRevison2()
    
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }
  
  func testV2_InputSRGB_effects() throws {
    
    let imageSource = ImageSource(image: Asset.unsplash2.image)
    
    let inputCGImage = imageSource.loadOriginalCGImage()
    XCTAssertEqual(inputCGImage.colorSpace, ColorSpaces.sRGB)
    
    let renderer = ImageRenderer(source: imageSource, orientation: .up)
    
    var filter = FilterBrightness()
    filter.value = 0.1
    
    renderer.edit.modifiers = [filter]
    
    let image = try renderer.renderRevison2()
    
    XCTAssertEqual(image.colorSpace, ColorSpaces.displayP3)
  }
    
}
