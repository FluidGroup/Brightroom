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

import XCTest

@testable import BrightroomEngine

/// Direct coverage for the `CropGeometry` helper. `EditingCrop` delegates to it
/// today, but `EditingCrop` is removed later in the refactor, so these pin the
/// clamp / aspect-fit / bounding-box math independently of it.
final class CropGeometryTests: XCTestCase {

  private let imageSize = CGSize(width: 200, height: 100)

  func testFittingRectClampsToImageBounds() {
    let result = CropGeometry.fittingRect(
      rect: .init(x: -10, y: -10, width: 250, height: 150),
      in: imageSize,
      respectingAspectRatio: nil
    )
    XCTAssertEqual(result, .init(x: 0, y: 0, width: 200, height: 100))
  }

  func testFittingRectFitsCenteredAspectRatio() {
    // A full-image rect constrained to square: centered horizontally, 100×100.
    let result = CropGeometry.fittingRect(
      rect: .init(x: 0, y: 0, width: 200, height: 100),
      in: imageSize,
      respectingAspectRatio: .square
    )
    XCTAssertEqual(result, .init(x: 50, y: 0, width: 100, height: 100))
  }

  func testCropRectToFitAspectRatioIsMaximalAndCentered() {
    let result = CropGeometry.cropRect(toFitAspectRatio: .square, in: imageSize)
    XCTAssertEqual(result, .init(x: 50, y: 0, width: 100, height: 100))
  }

  func testCropRectToFitAspectRatioIsIdempotent() {
    let first = CropGeometry.cropRect(toFitAspectRatio: .init(width: 4, height: 5), in: imageSize)
    let second = CropGeometry.fittingRect(
      rect: first,
      in: imageSize,
      respectingAspectRatio: .init(width: 4, height: 5)
    )
    XCTAssertEqual(first, second)
  }

  func testCropRectToFitBoundingBoxFlipsVisionYUpToDisplayYDown() {
    // Vision's bottom-left quadrant (y-up, normalized) must land in the display
    // lower-left quadrant (y-down): y spans 50…100 in a 100-tall image.
    let result = CropGeometry.cropRect(
      toFitBoundingBox: .init(x: 0, y: 0, width: 0.5, height: 0.5),
      within: .init(x: 0, y: 0, width: 200, height: 100),
      in: imageSize,
      respectingAspectRatio: nil
    )
    XCTAssertEqual(result, .init(x: 0, y: 50, width: 100, height: 50))
  }
}
