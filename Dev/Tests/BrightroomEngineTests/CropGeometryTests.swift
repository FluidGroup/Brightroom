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

/// Direct coverage for the `CropGeometry` helper. `EditingCrop` delegates to it
/// today, but `EditingCrop` is removed later in the refactor, so these pin the
/// clamp / aspect-fit / bounding-box math independently of it.
struct CropGeometryTests {

  private let imageSize = CGSize(width: 200, height: 100)

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

  @Test func `Fitting a quarter-turned rect clamps its footprint`() {
    // The full image turned a quarter is already inside: nothing clamps.
    let turnedFull = CGRect(x: 50, y: -50, width: 100, height: 200)
    #expect(
      CropGeometry.fittingRect(rect: turnedFull, in: imageSize, rotation: .quarterCW, respectingAspectRatio: nil)
        == turnedFull
    )
    // Past the image: only the footprint's overhang goes.
    #expect(
      CropGeometry.fittingRect(
        rect: .init(x: 50, y: -60, width: 100, height: 220),
        in: imageSize,
        rotation: .quarterCW,
        respectingAspectRatio: nil
      ) == turnedFull
    )
    // Unrotated behavior is unchanged.
    #expect(
      CropGeometry.fittingRect(rect: turnedFull, in: imageSize, rotation: .zero, respectingAspectRatio: nil)
        == CropGeometry.fittingRect(rect: turnedFull, in: imageSize, respectingAspectRatio: nil)
    )
  }

  @Test func `Aspect fit after a quarter turn uses the turned image`() {
    // 1:2 in the output orientation of a quarter-turned 200×100 image is the
    // whole image.
    #expect(
      CropGeometry.cropRect(toFitAspectRatio: .init(width: 1, height: 2), in: imageSize, rotation: .quarterCW)
        == .init(x: 50, y: -50, width: 100, height: 200)
    )
    #expect(
      CropGeometry.cropRect(toFitAspectRatio: .square, in: imageSize, rotation: .quarterCW)
        == CropGeometry.cropRect(toFitAspectRatio: .square, in: imageSize)
    )
  }
}
