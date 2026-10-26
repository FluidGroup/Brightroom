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

import CoreImage
import Foundation
import Testing

@testable import BrightroomEngine

/// A `SourceImage` reads its orientation and oriented size when it is
/// created, before any pixels are decoded.
struct LoadingTests {

  @Test(arguments: [
    ("orientation_right", CGImagePropertyOrientation.right),
    ("orientation_down", .down),
    ("orientation_left", .left),
    ("orientation_up", .up),
    ("orientation_left_mirrored", .leftMirrored),
    ("orientation_down_mirrored", .downMirrored),
    ("orientation_right_mirrored", .rightMirrored),
    ("orientation_up_mirrored", .upMirrored),
  ])
  func orientation(resource: String, expected: CGImagePropertyOrientation) throws {
    let url = _url(forResource: resource, ofType: "HEIC")
    let image = try SourceImage(contentsOf: url)
    #expect(image.storage.orientation == expected)

    // The oriented size swaps the stored width and height for the quarter
    // turns, and the full-resolution image starts at zero with that size.
    let imageSource = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    )
    let stored = CGSize(
      width: try #require(properties[kCGImagePropertyPixelWidth] as? CGFloat),
      height: try #require(properties[kCGImagePropertyPixelHeight] as? CGFloat)
    )
    let swapsAxes = [.left, .right, .leftMirrored, .rightMirrored].contains(expected)
    let expectedSize = swapsAxes ? CGSize(width: stored.height, height: stored.width) : stored
    #expect(image.pixelSize == expectedSize)
    #expect(image.makeCIImage().extent == CGRect(origin: .zero, size: expectedSize))
  }

  @Test func `Data and the same file read the same`() throws {
    let url = _url(forResource: "orientation_right", ofType: "HEIC")
    let fromFile = try SourceImage(contentsOf: url)
    let fromData = try SourceImage(data: Data(contentsOf: url))
    #expect(fromFile.pixelSize == fromData.pixelSize)
    #expect(fromFile.storage.orientation == fromData.storage.orientation)
    #expect(fromFile != fromData, "Two loads are two images.")
  }
}

func _url(forResource: String, ofType: String) -> URL {
  _pixelengine_bundle.path(
    forResource: forResource,
    ofType: ofType
  ).map {
    URL(fileURLWithPath: $0)
  }!
}

let _pixelengine_bundle = Bundle.init(for: Dummy.self)

fileprivate final class Dummy {}
