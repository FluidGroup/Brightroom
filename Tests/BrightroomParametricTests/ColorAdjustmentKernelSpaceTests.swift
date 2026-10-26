//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import Testing

@testable import BrightroomParametric

/// The Tone Curve and Color Mixer recipes match their input into
/// extended-linear Display-P3 around the kernel. The export, canvas, and
/// swatch contexts already work in that space, so there the match must leave
/// every pixel exactly as the bare kernel renders it.
@Suite("Color adjustment kernel space", .serialized)
struct ColorAdjustmentKernelSpaceTests {

  enum Effect: String, CaseIterable, CustomTestStringConvertible {
    case toneCurve
    case colorMixer

    var testDescription: String { rawValue }

    /// The feature as hosts render it, through the matched recipe.
    func feature() -> AnyImageEffect {
      switch self {
      case .toneCurve: AnyImageEffect(RenderingFixtures.makeToneCurve())
      case .colorMixer: AnyImageEffect(ColorAdjustmentKernelSpaceTests.mixer)
      }
    }

    /// The same plan through the bare kernel, with no match.
    func unmatchedFeature() -> UnmatchedKernel {
      UnmatchedKernel(effect: self)
    }
  }

  @Test(arguments: Effect.allCases)
  func `the export renders exactly what the bare kernel renders`(effect: Effect) throws {
    let source = try RenderingFixtures.normalizedSource()
    let options = ExportRenderer.Options(
      outputFormat: .RGBAf,
      outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    )

    let matched = try ExportRenderer().render(from: source, feature: effect.feature(), options: options)
    let unmatched = try ExportRenderer().render(
      from: source, feature: effect.unmatchedFeature(), options: options)

    let matchedBytes = try Self.bytes(of: matched.cgImage)
    let unmatchedBytes = try Self.bytes(of: unmatched.cgImage)
    #expect(matchedBytes.isEmpty == false)
    #expect(matchedBytes == unmatchedBytes)

    let unedited = try ExportRenderer().render(from: source, feature: EmptyFeature(), options: options)
    #expect(try Self.bytes(of: unedited.cgImage) != matchedBytes)
  }

  @Test(arguments: Effect.allCases)
  func `the canvas context renders exactly what the bare kernel renders`(effect: Effect) throws {
    // `EditingCanvasImageProcessing` (BrightroomUI) configures the canvas and
    // filter swatch contexts this way.
    let context = CIContext(options: [
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
      .workingFormat: CIFormat.RGBAh,
      .cacheIntermediates: false,
    ])
    let source = try RenderingFixtures.normalizedSource()

    let matched = try FeatureRenderer().makeImage(from: source, feature: effect.feature())
    let unmatched = try FeatureRenderer().makeImage(from: source, feature: effect.unmatchedFeature())

    let difference = Self.maximumDifference(
      Self.components(of: matched, context: context, colorSpace: Self.linearDisplayP3),
      Self.components(of: unmatched, context: context, colorSpace: Self.linearDisplayP3)
    )
    #expect(difference == 0)
  }

  @Test(arguments: Effect.allCases)
  func `a context without color management runs the kernel on its values as they are`(
    effect: Effect
  ) throws {
    let context = CIContext(options: [
      .workingColorSpace: NSNull(),
      .workingFormat: CIFormat.RGBAf,
      .cacheIntermediates: false,
    ])
    let source = try RenderingFixtures.normalizedSource()

    let matched = try FeatureRenderer().makeImage(from: source, feature: effect.feature())
    let unmatched = try FeatureRenderer().makeImage(from: source, feature: effect.unmatchedFeature())

    let difference = Self.maximumDifference(
      Self.components(of: matched, context: context, colorSpace: nil),
      Self.components(of: unmatched, context: context, colorSpace: nil)
    )
    #expect(difference == 0)
  }

  // MARK: - Fixtures

  static let mixer = ColorMixerFeature(
    bands: .init(
      orange: .init(hue: 30, saturation: 40, luminance: -20),
      blue: .init(saturation: -50)
    )
  )

  static let linearDisplayP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

  static func components(of image: CIImage, context: CIContext, colorSpace: CGColorSpace?) -> [Float] {
    let width = Int(image.extent.width)
    let height = Int(image.extent.height)
    var components = [Float](repeating: 0, count: width * height * 4)
    components.withUnsafeMutableBytes { bytes in
      context.render(
        image,
        toBitmap: bytes.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: image.extent,
        format: .RGBAf,
        colorSpace: colorSpace
      )
    }
    return components
  }

  static func bytes(of image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data as Data?)
    return [UInt8](data)
  }

  static func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
  }
}

/// Runs an effect's kernel over its input with no color-space match.
struct UnmatchedKernel: ImageEffect, Equatable {

  var effect: ColorAdjustmentKernelSpaceTests.Effect

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    switch effect {
    case .toneCurve:
      let curves = RenderingFixtures.makeToneCurve().curves
      let plan = try #require(ToneCurveRenderPlan(curves: curves))
      return try ToneCurveRecipe.applyKernel(to: image, plan: plan)
    case .colorMixer:
      let bands = ColorAdjustmentKernelSpaceTests.mixer.bands
      let plan = try #require(ColorMixerRenderPlan(bands: bands))
      return try ColorMixerRecipe.applyKernel(to: image, plan: plan)
    }
  }
}
