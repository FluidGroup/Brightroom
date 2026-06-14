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

import CoreImage
import Metal
import XCTest

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Proves the **live** Metal brush rasterizer (`BrushMaskMetalRasterizer`, the
/// pipeline `_EditingCanvasMTKView` drives for low-latency painting) matches the
/// **parametric** Core Image CIKernel rasterizer
/// (`FeatureGraphCompiler.renderMask`, the export/preview path) for the same
/// stamps and canvas.
///
/// Both rasterizers prepend the shared `BrushStampSharedSource.falloffFunctionMSL`
/// (`brushStampAlpha`) and accumulate stamps with a `max` blend
/// (`MTLBlendOperation.max` / `CIBlendKernel.componentMax`), so they should
/// agree by construction. This test pins that they actually do — including
/// orientation, which is the historically fragile part: the live shader places
/// stamps y-down while the kernel works y-up, and `BrushMaskMetalRasterizer`
/// bakes in a compensating vertical flip so identical stamp coordinates land in
/// the same place. A flip regression would move alpha by the full canvas
/// height — tens to hundreds of levels at the sampled points — far outside the
/// anti-aliasing tolerance.
final class BrushMaskRasterizerParityTests: XCTestCase {

  private static let context = CIContext(options: [.workingColorSpace: NSNull()])

  // 128x128 canvas, stamps placed asymmetrically (top-heavy, off-center) so a
  // vertical or horizontal flip cannot accidentally pass.
  private let canvas = 128
  private let radius: CGFloat = 24
  private let hardness: Float = 0
  private let opacity: Float = 1

  /// The stamp centers, expressed in the parametric kernel's extent coordinates
  /// (which `BrushMaskMetalRasterizer.rasterize` matches after its flip).
  private var stampCenters: [CGPoint] {
    [
      CGPoint(x: 40, y: 30),   // upper-left-ish
      CGPoint(x: 96, y: 64),   // right of center
      CGPoint(x: 64, y: 100),  // lower-center
    ]
  }

  func testLiveMetalRasterizerMatchesParametricKernel() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("No Metal device available; skipping live-rasterizer parity test.")
    }
    let rasterizer = try XCTUnwrap(
      BrushMaskMetalRasterizer(device: device),
      "Failed to build the live brush-mask Metal pipeline."
    )

    let extent = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    // Path A — live Metal rasterizer (the in-flight-stroke shader, standalone).
    let maskA = try XCTUnwrap(
      rasterizer.rasterize(
        stamps: stampCenters.map {
          BrushMaskMetalRasterizer.Stamp(
            center: $0,
            pixelRadius: radius,
            hardness: hardness,
            opacity: opacity
          )
        },
        canvasPixelSize: CGSize(width: canvas, height: canvas)
      ),
      "Live rasterizer returned no image."
    )

    // Path B — parametric Core Image CIKernel rasterizer (export/preview path).
    let maskB = try FeatureGraphCompiler().renderMask(
      MaskTree(
        root: .brush(
          BrushMask(
            strokes: [
              BrushMaskStroke(
                stamps: stampCenters,
                brush: BrushMaskBrush(
                  diameter: Double(2 * radius),
                  hardness: Double(hardness),
                  opacity: Double(opacity)
                )
              )
            ]
          )
        )
      ),
      extent: extent
    )

    let cgA = try render(maskA, extent: extent)
    let cgB = try render(maskB, extent: extent)

    // Sample at stamp centers (should be ~full alpha), a few edge/outside points
    // (should be partial / zero). Coordinates below are display coordinates
    // (top-left origin, y-down) — `alpha(in:atX:y:)` reads CGImage rows
    // directly. A parametric stamp authored at extent-y `cy` lands at display
    // row `height - cy`, and `BrushMaskMetalRasterizer` matches that.
    //
    // For each: convert the extent-coordinate stamp center to its display row.
    let h = canvas
    let samplePoints: [(x: Int, y: Int, label: String)] = [
      // Centers (display row = height - extentY).
      (40, h - 30, "center-0"),
      (96, h - 64, "center-1"),
      (64, h - 100, "center-2"),
      // Far outside every stamp -> ~0 in both.
      (4, 4, "corner-empty"),
      (124, 4, "corner-empty-2"),
      // Mid-falloff near the first stamp: ~radius*0.7 away horizontally.
      (40 + 17, h - 30, "mid-falloff-0"),
    ]

    for point in samplePoints {
      let a = Self.alpha(in: cgA, atX: point.x, y: point.y)
      let b = Self.alpha(in: cgB, atX: point.x, y: point.y)
      XCTAssertEqual(
        Int(a), Int(b),
        accuracy: 20,
        "live vs parametric diverged at \(point.label) (\(point.x),\(point.y)): live=\(a) parametric=\(b)"
      )
    }

    // Sanity floor/ceiling so the test cannot pass on two all-zero images: the
    // stamp centers must be near full alpha in BOTH paths, and the corner must
    // be empty in BOTH paths. This also catches a flip — a flip would empty the
    // (top-heavy) authored rows and fill their mirrors.
    XCTAssertGreaterThan(Int(Self.alpha(in: cgA, atX: 40, y: h - 30)), 220, "live center-0 not painted")
    XCTAssertGreaterThan(Int(Self.alpha(in: cgB, atX: 40, y: h - 30)), 220, "parametric center-0 not painted")
    XCTAssertLessThan(Int(Self.alpha(in: cgA, atX: 4, y: 4)), 20, "live corner not empty")
    XCTAssertLessThan(Int(Self.alpha(in: cgB, atX: 4, y: 4)), 20, "parametric corner not empty")
  }

  // MARK: - Helpers

  private func render(_ image: CIImage, extent: CGRect) throws -> CGImage {
    try XCTUnwrap(Self.context.createCGImage(image, from: extent))
  }

  /// Reads the alpha at a CGImage pixel (top-left origin, y-down). Both
  /// rasterizers write `float4(a, a, a, a)`, so alpha == any channel; we read
  /// the alpha channel via `premultipliedLast`.
  private static func alpha(in image: CGImage, atX x: Int, y: Int) -> UInt8 {
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

    let clampedX = min(max(x, 0), width - 1)
    let clampedY = min(max(y, 0), height - 1)
    let offset = (clampedY * width + clampedX) * 4
    return pixels[offset + 3]
  }
}
