//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import Testing

import BrightroomParametric

/// Public API only. A host that draws part of an edit evaluates the feature
/// over the whole source and crops the output: the recipe stays lazy, and
/// the pixels are exactly that region of the whole render. The source is the
/// chain entry, so a part or a downscaled copy of it is a different chain
/// entry and evaluates to a different image.
@Suite("Drawing part of a render")
struct PartialRenderTests {

  /// A crop, a blur whose radius resolves against the chain entry, and a
  /// vignette centred on the crop output: each one depends on where the
  /// output region sits in the whole image.
  private struct Edit: Feature {
    var body: some Feature {
      CropFeature(rect: CGRect(x: 100, y: 60, width: 560, height: 420))
      GaussianBlurFeature(radius: .proportional(20))
      VignetteFeature(value: 1)
    }
  }

  /// Regions of the 560 × 420 output: one inside, one on its bottom-left
  /// corner, and one across its top edge.
  private static let regions: [CGRect] = [
    CGRect(x: 200, y: 150, width: 120, height: 90),
    CGRect(x: 0, y: 0, width: 100, height: 80),
    CGRect(x: 300, y: 380, width: 140, height: 40),
  ]

  @Test(arguments: regions)
  func `the whole render cropped to a region equals that region of the whole render`(
    region: CGRect
  ) throws {
    let whole = try FeatureRenderer().makeImage(from: Self.source, feature: Edit())
    #expect(whole.extent == CGRect(x: 0, y: 0, width: 560, height: 420))

    let wholePixels = Self.pixels(of: whole, in: whole.extent)
    let expected = Self.pixels(wholePixels, wholeExtent: whole.extent, region: region)
    let cropped = Self.pixels(of: whole.cropped(to: region), in: region)

    let difference = Self.maxDifference(cropped, expected)
    #expect(difference <= Self.tolerance, "max difference \(difference)")

    // The edit is visible in the region, so a render that skipped it could
    // not match by accident.
    let unedited = Self.pixels(
      of: Self.source.cropped(to: CGRect(x: 100, y: 60, width: 560, height: 420))
        .transformed(by: CGAffineTransform(translationX: -100, y: -60)),
      in: region
    )
    #expect(Self.maxDifference(cropped, unedited) > 0.05)
  }

  @Test
  func `a downscaled source is a different chain entry`() throws {
    let whole = try FeatureRenderer().makeImage(from: Self.source, feature: Edit())

    // The crop rect is in source pixels, so over a half-size source it
    // selects another part of the image, partly outside it.
    let halfSize = Self.source.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
    let fromHalfSize = try FeatureRenderer().makeImage(from: halfSize, feature: Edit())
      .transformed(by: CGAffineTransform(scaleX: 2, y: 2))

    let region = Self.regions[0]
    let difference = Self.maxDifference(
      Self.pixels(of: fromHalfSize, in: region),
      Self.pixels(of: whole, in: region)
    )
    #expect(difference > 0.05, "max difference \(difference)")
  }

  // MARK: - Helpers

  /// The same recipe rendered twice gives the same floats.
  private static let tolerance: Float = 0.0001

  private static let context = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .workingFormat: CIFormat.RGBAf,
  ])

  /// An 800 × 600 checkerboard with 40 px squares.
  private static let source: CIImage = {
    let filter = CIFilter(name: "CICheckerboardGenerator")!
    filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
    filter.setValue(CIColor(red: 0.2, green: 0.3, blue: 0.45), forKey: "inputColor0")
    filter.setValue(CIColor(red: 0.85, green: 0.7, blue: 0.55), forKey: "inputColor1")
    filter.setValue(40, forKey: kCIInputWidthKey)
    filter.setValue(1, forKey: kCIInputSharpnessKey)
    return filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
  }()

  /// RGBA floats of `bounds`, top row first.
  private static func pixels(of image: CIImage, in bounds: CGRect) -> [Float] {
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    var data = [Float](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { buffer in
      context.render(
        image,
        toBitmap: buffer.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: bounds,
        format: .RGBAf,
        colorSpace: nil
      )
    }
    return data
  }

  /// The pixels of `region` taken from a bitmap of `wholeExtent`, both top
  /// row first.
  private static func pixels(_ whole: [Float], wholeExtent: CGRect, region: CGRect) -> [Float] {
    let wholeWidth = Int(wholeExtent.width)
    let firstRow = Int(wholeExtent.maxY - region.maxY)
    let firstColumn = Int(region.minX - wholeExtent.minX)
    var result: [Float] = []
    result.reserveCapacity(Int(region.width) * Int(region.height) * 4)
    for row in firstRow..<(firstRow + Int(region.height)) {
      let start = (row * wholeWidth + firstColumn) * 4
      result.append(contentsOf: whole[start..<(start + Int(region.width) * 4)])
    }
    return result
  }

  private static func maxDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    precondition(lhs.count == rhs.count)
    return zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
  }
}
