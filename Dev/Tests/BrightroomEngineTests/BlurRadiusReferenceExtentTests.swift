import CoreImage
import Foundation
import Testing
import UIKit

@testable import BrightroomParametric

/// Pins the source-extent invariant for diagonal-based radii: a value-form
/// Gaussian blur resolves its radius against the context's source reference
/// extent, NOT the (possibly cropped or zoomed) extent of the image it happens
/// to be applied to.
///
/// This is what keeps the masked blur a fixed fraction of the source across
/// crop changes and viewport zoom, so the CropView preview matches the
/// exported result. Before the fix, the live viewport re-resolved `value=40`
/// against the zoomed drawable extent, so zooming changed the visible blur.
struct BlurRadiusReferenceExtentTests {

  private static let context = CIContext()

  /// `value=40` with a source reference resolves to `diagonal(reference)/50`,
  /// independent of the small input image it is applied to.
  @Test func `value blur resolves radius against reference extent`() throws {
    // An 80×80 input that, in the viewport, is a zoomed slice of a larger
    // 800×800 source.
    let input = Self.stepEdge(side: 80)
    let sourceReference = CGRect(x: 0, y: 0, width: 800, height: 800)

    let viaValue = try GaussianBlurFeature(value: 40).apply(
      to: input,
      context: FeatureEvaluationContext(radiusReferenceExtent: sourceReference)
    )

    // The equivalent absolute radius (diagonal/50) applied to the same input.
    let referenceRadius = hypot(800.0, 800.0) / 50.0
    let viaAbsolute = try GaussianBlurFeature(radius: referenceRadius).apply(
      to: input,
      context: FeatureEvaluationContext()
    )
    #expect(
      Self.areNearlyEqual(viaValue, viaAbsolute, extent: input.extent, tolerance: 3),
      "value blur must resolve its radius from the reference extent"
    )

    // The bug it prevents: resolving against the input's own (small) extent
    // gives a ~10× smaller radius and a visibly sharper edge.
    let inputExtentRadius = hypot(80.0, 80.0) / 50.0
    let viaInputExtent = try GaussianBlurFeature(radius: inputExtentRadius).apply(
      to: input,
      context: FeatureEvaluationContext()
    )
    #expect(
      !Self.areNearlyEqual(viaValue, viaInputExtent, extent: input.extent, tolerance: 3),
      "value blur must NOT resolve its radius from the input extent"
    )
  }

  /// With `radiusReferenceExtent` nil, the radius falls back to the input
  /// extent — the contract the export and preview-composition paths rely on,
  /// where the input IS the full source at render scale.
  @Test func `nil reference falls back to input extent`() throws {
    let input = Self.stepEdge(side: 200)
    let viaNil = try GaussianBlurFeature(value: 40).apply(
      to: input,
      context: FeatureEvaluationContext()
    )
    let viaInputExtent = try GaussianBlurFeature(radius: hypot(200.0, 200.0) / 50.0).apply(
      to: input,
      context: FeatureEvaluationContext()
    )
    #expect(
      Self.areNearlyEqual(viaNil, viaInputExtent, extent: input.extent, tolerance: 3),
      "nil reference must fall back to the input extent"
    )
  }

  // MARK: - Helpers

  /// A vertical black/white step edge, so a Gaussian blur spreads measurably
  /// across the boundary.
  private static func stepEdge(side: Int) -> CIImage {
    let size = CGSize(width: side, height: side)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let cg = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor.white.setFill()
      UIRectFill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
      UIColor.black.setFill()
      UIRectFill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
    }.cgImage!
    return CIImage(cgImage: cg)
  }

  private static func areNearlyEqual(
    _ lhs: CIImage,
    _ rhs: CIImage,
    extent: CGRect,
    tolerance: Int
  ) -> Bool {
    guard
      let l = context.createCGImage(lhs, from: extent),
      let r = context.createCGImage(rhs, from: extent)
    else {
      return false
    }
    let lp = pixels(of: l)
    let rp = pixels(of: r)
    guard lp.count == rp.count else { return false }
    var maxDiff = 0
    for i in stride(from: 0, to: lp.count, by: 997) { // sparse sample
      maxDiff = max(maxDiff, abs(Int(lp[i]) - Int(rp[i])))
    }
    return maxDiff <= tolerance
  }

  private static func pixels(of image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(
      data: &data,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return data
  }
}
