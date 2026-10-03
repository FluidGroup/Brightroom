//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import Testing

import BrightroomParametric

/// Public API only. `GaussianBlurFeature`, `SharpenFeature`, and
/// `UnsharpMaskFeature` share `EffectRadius`, and each one passes the
/// resolved radius to Core Image. These tests pin that radius on a
/// 4000×3000 chain entry, whose diagonal is 5000 px, so `.proportional(100)`
/// is 250 px and `.proportional(1)` is 2.5 px. A change to the scale would
/// silently change the look of every stored value.
@Suite("EffectRadius resolves to the Core Image radius")
struct EffectRadiusRecipeTests {

  enum Case: String, CaseIterable, CustomTestStringConvertible {
    case sharpenProportional
    case sharpenAbsolute
    case unsharpMaskProportional
    case unsharpMaskAbsolute
    case gaussianBlurProportional
    case gaussianBlurAbsolute

    var testDescription: String { rawValue }

    var radius: EffectRadius {
      switch self {
      case .sharpenProportional: .proportional(1)
      case .unsharpMaskProportional, .gaussianBlurProportional: .proportional(100)
      case .sharpenAbsolute, .unsharpMaskAbsolute, .gaussianBlurAbsolute: .absolute(3)
      }
    }

    /// The `inputRadius` the feature must pass to Core Image.
    var expectedPixels: Double {
      switch self {
      case .sharpenProportional: 2.5
      case .unsharpMaskProportional, .gaussianBlurProportional: 250
      case .sharpenAbsolute, .unsharpMaskAbsolute, .gaussianBlurAbsolute: 3
      }
    }

    /// The radius the feature would pass if it read the number in the
    /// other unit: a proportional value as pixels, or pixels as a
    /// proportional value. The recipe must not match it, which shows the
    /// comparison can tell the units apart.
    var otherUnitPixels: Double {
      switch radius {
      case let .proportional(value): value
      case let .absolute(pixels): pixels * 2.5
      }
    }

    var feature: AnyImageEffect {
      switch self {
      case .sharpenProportional, .sharpenAbsolute:
        AnyImageEffect(SharpenFeature(intensity: 0.8, radius: radius))
      case .unsharpMaskProportional, .unsharpMaskAbsolute:
        AnyImageEffect(UnsharpMaskFeature(intensity: 0.6, radius: radius))
      case .gaussianBlurProportional, .gaussianBlurAbsolute:
        AnyImageEffect(GaussianBlurFeature(radius: radius))
      }
    }

    /// The explicit Core Image recipe with a radius in pixels.
    func reference(_ source: CIImage, pixels: Double) -> CIImage {
      switch self {
      case .sharpenProportional, .sharpenAbsolute:
        source
          .applyingFilter(
            "CISharpenLuminance",
            parameters: ["inputRadius": pixels, "inputSharpness": 0.8]
          )
          .cropped(to: source.extent)
      case .unsharpMaskProportional, .unsharpMaskAbsolute:
        source
          .applyingFilter(
            "CIUnsharpMask",
            parameters: ["inputRadius": pixels, "inputIntensity": 0.6]
          )
          .cropped(to: source.extent)
      case .gaussianBlurProportional, .gaussianBlurAbsolute:
        source
          .clamped(to: source.extent)
          .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: pixels])
          .cropped(to: source.extent)
      }
    }
  }

  @Test(arguments: Case.allCases)
  func `radius on a 4000 × 3000 chain entry`(testCase: Case) throws {
    let source = Self.source
    let rendered = Self.pixels(
      of: try FeatureRenderer().makeImage(from: source, feature: testCase.feature)
    )

    let expected = Self.pixels(of: testCase.reference(source, pixels: testCase.expectedPixels))
    let expectedDifference = Self.maxDifference(rendered, expected)
    #expect(
      expectedDifference <= Self.tolerance,
      "\(testCase.radius) must resolve to \(testCase.expectedPixels) px; max difference \(expectedDifference)"
    )

    let otherUnit = Self.pixels(of: testCase.reference(source, pixels: testCase.otherUnitPixels))
    let otherUnitDifference = Self.maxDifference(rendered, otherUnit)
    #expect(
      otherUnitDifference > 0.01,
      "\(testCase.radius) must not resolve to \(testCase.otherUnitPixels) px; max difference \(otherUnitDifference)"
    )
  }

  // MARK: - Helpers

  /// The same recipe rendered twice gives the same floats.
  private static let tolerance: Float = 0.0001

  private static let context = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .workingFormat: CIFormat.RGBAf,
  ])

  /// A 4000×3000 checkerboard with 400 px squares: large enough that a
  /// 250 px blur keeps its edges, so every radius renders differently.
  private static let source: CIImage = {
    let filter = CIFilter(name: "CICheckerboardGenerator")!
    filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
    filter.setValue(CIColor(red: 0.2, green: 0.3, blue: 0.45), forKey: "inputColor0")
    filter.setValue(CIColor(red: 0.85, green: 0.7, blue: 0.55), forKey: "inputColor1")
    filter.setValue(400, forKey: kCIInputWidthKey)
    filter.setValue(1, forKey: kCIInputSharpnessKey)
    return filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 4000, height: 3000))
  }()

  /// The rendered region: a 400 × 400 window around the corner where four
  /// squares meet at (2000, 1600).
  private static let region = CGRect(x: 1800, y: 1400, width: 400, height: 400)

  private static func pixels(of image: CIImage) -> [Float] {
    let width = Int(region.width)
    let height = Int(region.height)
    var data = [Float](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { buffer in
      context.render(
        image,
        toBitmap: buffer.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: region,
        format: .RGBAf,
        colorSpace: nil
      )
    }
    return data
  }

  private static func maxDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
  }
}
