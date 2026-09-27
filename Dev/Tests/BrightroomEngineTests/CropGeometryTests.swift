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

import Testing
import Foundation
import CoreGraphics

@testable import BrightroomEngine
import BrightroomParametric

/// Verifies the crop geometry shared by engine canonicalization and UI editing,
/// including bounds, aspect fitting, and display-coordinate conversion.
struct CropGeometryTests {

  private let imageSize = CGSize(width: 200, height: 100)

  @Test func `Straightened crop fitting preserves a valid thin selection`() {
    let sourceSize = CGSize(width: 300, height: 200)
    // Its sampled source area fits even though the selected rectangle extends
    // above and below the image before applying the straighten angle.
    let selectedRect = CGRect(x: 132, y: -5, width: 36, height: 210)
    let fitted = CropGeometry.fittingRect(
      rect: selectedRect,
      in: sourceSize,
      straightenRadians: .pi / 6,
      respectingAspectRatio: nil
    )
    #expect(fitted == selectedRect)
  }

  @Test func `Straightened fitting constrains the sampled source area`() {
    let fitted = CropGeometry.fittingStraightenedRect(
      rect: CGRect(x: -20, y: 10, width: 300, height: 200),
      in: CGSize(width: 300, height: 200),
      straightenRadians: .pi / 6
    )
    let sampledBounds = fitted
      .offsetBy(dx: -fitted.midX, dy: -fitted.midY)
      .applying(CGAffineTransform(rotationAngle: .pi / 6))
      .offsetBy(dx: fitted.midX, dy: fitted.midY)

    #expect(sampledBounds.minX >= -1e-8)
    #expect(sampledBounds.minY >= -1e-8)
    #expect(sampledBounds.maxX <= 300 + 1e-8)
    #expect(sampledBounds.maxY <= 200 + 1e-8)
    #expect(abs(fitted.width / fitted.height - 1.5) < 1e-8)
  }

  @Test func `Fitting rect clamps to image bounds`() {
    let result = CropGeometry.fittingRect(
      rect: .init(x: -10, y: -10, width: 250, height: 150),
      in: imageSize,
      respectingAspectRatio: nil
    )
    #expect(result == .init(x: 0, y: 0, width: 200, height: 100))
  }

  @Test func `Fitting rect fits centered aspect ratio`() {
    // A full-image rect constrained to square: centered horizontally, 100×100.
    let result = CropGeometry.fittingRect(
      rect: .init(x: 0, y: 0, width: 200, height: 100),
      in: imageSize,
      respectingAspectRatio: .square
    )
    #expect(result == .init(x: 50, y: 0, width: 100, height: 100))
  }

  @Test func `Crop rect to fit aspect ratio is maximal and centered`() {
    let result = CropGeometry.cropRect(toFitAspectRatio: .square, in: imageSize)
    #expect(result == .init(x: 50, y: 0, width: 100, height: 100))
  }

  @Test func `Crop rect to fit aspect ratio is idempotent`() {
    let first = CropGeometry.cropRect(toFitAspectRatio: .init(width: 4, height: 5), in: imageSize)
    let second = CropGeometry.fittingRect(
      rect: first,
      in: imageSize,
      respectingAspectRatio: .init(width: 4, height: 5)
    )
    #expect(first == second)
  }

  @Test func `Crop rect to fit bounding box flips vision y up to display y down`() {
    // Vision's bottom-left quadrant (y-up, normalized) must land in the display
    // lower-left quadrant (y-down): y spans 50…100 in a 100-tall image.
    let result = CropGeometry.cropRect(
      toFitBoundingBox: .init(x: 0, y: 0, width: 0.5, height: 0.5),
      within: .init(x: 0, y: 0, width: 200, height: 100),
      in: imageSize,
      respectingAspectRatio: nil
    )
    #expect(result == .init(x: 0, y: 50, width: 100, height: 50))
  }

  @Test func `Quarter turn swaps a rect about its center`() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
    #expect(CropGeometry.rect(rect, turnedBy: .quarterCW) == .init(x: 50, y: -50, width: 100, height: 200))
    #expect(CropGeometry.rect(rect, turnedBy: .quarterCCW) == .init(x: 50, y: -50, width: 100, height: 200))
    #expect(CropGeometry.rect(rect, turnedBy: .half) == rect)
    #expect(CropGeometry.rect(rect, turnedBy: .zero) == rect)
  }

  @Test func `Zero straighten uses the source rectangle clamp`() {
    let requested = CGRect(x: -10, y: -10, width: 250, height: 150)
    #expect(
      CropGeometry.fittingRect(
        rect: requested,
        in: imageSize,
        straightenRadians: 0,
        respectingAspectRatio: nil
      ) == CGRect(origin: .zero, size: imageSize)
    )
  }
}
