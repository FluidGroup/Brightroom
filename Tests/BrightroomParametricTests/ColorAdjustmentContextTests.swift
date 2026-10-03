//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreImage
import Foundation
import Testing

import BrightroomParametric

/// Public API only. A host renders a `ToneCurveFeature` or a
/// `ColorMixerFeature` with whatever `CIContext` it has. Both kernels compute
/// in extended-linear Display-P3, so the colors must not depend on the
/// context's working color space: a default `CIContext()`, a linear or
/// gamma-encoded sRGB working space, and `VideoRenderer`'s default (`nil`)
/// video context all render what `ExportRenderer` renders.
@Suite("Tone Curve and Color Mixer through any context", .serialized)
struct ColorAdjustmentContextTests {

  enum Effect: String, CaseIterable, CustomTestStringConvertible {
    case toneCurve
    case colorMixer

    var testDescription: String { rawValue }

    func feature() -> AnyImageEffect {
      switch self {
      case .toneCurve: AnyImageEffect(RenderingFixtures.makeToneCurve())
      case .colorMixer: AnyImageEffect(ColorAdjustmentContextTests.mixer)
      }
    }
  }

  enum WorkingSpace: String, CaseIterable, CustomTestStringConvertible {
    case extendedLinearDisplayP3
    case extendedLinearSRGB
    case sRGB
    case defaultContext

    var testDescription: String { rawValue }

    var context: CIContext {
      switch self {
      case .extendedLinearDisplayP3:
        ColorAdjustmentContextTests.referenceContext
      case .extendedLinearSRGB:
        ColorAdjustmentContextTests.context(
          workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
      case .sRGB:
        ColorAdjustmentContextTests.context(
          workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
      case .defaultContext:
        CIContext()
      }
    }
  }

  /// The configuration of the export, canvas, and swatch contexts:
  /// extended-linear Display-P3 with half-float pixels.
  static let referenceContext = context(
    workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)

  /// The export and a host's half-float context round differently by about
  /// 0.0005. Without the match around the kernels, a linear sRGB context
  /// moves Color Mixer channels by about 0.009 and Tone Curve channels by
  /// about 0.09.
  static let tolerance: Float = 0.002

  @Test(arguments: Effect.allCases, WorkingSpace.allCases)
  func `a still renders the same as the export`(
    effect: Effect,
    workingSpace: WorkingSpace
  ) throws {
    let source = Self.patches(scale: 1)
    let exported = try ExportRenderer().render(
      from: source,
      feature: effect.feature(),
      options: .init(
        outputFormat: .RGBAf,
        outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
      )
    )
    let reference = Self.linearDisplayP3Components(
      of: CIImage(cgImage: try exported.cgImage),
      context: Self.referenceContext
    )

    let image = try FeatureRenderer().makeImage(from: source, feature: effect.feature())
    let actual = Self.linearDisplayP3Components(of: image, context: workingSpace.context)

    // The effect must be visible, or matching contexts proves nothing.
    let unedited = Self.linearDisplayP3Components(of: source, context: Self.referenceContext)
    #expect(Self.maximumDifference(reference, unedited) > 0.05)

    let difference = Self.maximumDifference(actual, reference)
    #expect(difference <= Self.tolerance, "max channel difference \(difference)")
  }

  @Test(arguments: Effect.allCases)
  func `a video frame through the default context renders the same as through a linear Display-P3 context`(
    effect: Effect
  ) async throws {
    let scale = 16
    let asset = try await RenderingFixtures.makeVideoAsset(from: Self.patches(scale: scale))
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }
    let renderer = VideoRenderer()

    let defaultFrame = try await RenderingFixtures.firstFrame(
      of: asset,
      composition: renderer.makeVideoComposition(for: asset, feature: effect.feature())
    )
    let referenceFrame = try await RenderingFixtures.firstFrame(
      of: asset,
      composition: renderer.makeVideoComposition(
        for: asset,
        feature: effect.feature(),
        ciContext: Self.referenceContext
      )
    )
    let uneditedFrame = try await RenderingFixtures.firstFrame(
      of: asset,
      composition: renderer.makeVideoComposition(for: asset, feature: EmptyFeature())
    )

    let actual = Self.sRGBLevels(of: defaultFrame, scale: scale)
    let reference = Self.sRGBLevels(of: referenceFrame, scale: scale)
    let unedited = Self.sRGBLevels(of: uneditedFrame, scale: scale)
    #expect(Self.maximumDifference(reference, unedited) > 10)

    // The frames are 8-bit, so allow rounding by a level or two. Without the
    // match the default context is off by 4 (Color Mixer) and 19 (Tone Curve).
    let difference = Self.maximumDifference(actual, reference)
    #expect(difference <= 2, "max 8-bit level difference \(difference): \(actual) vs \(reference)")
  }

  // MARK: - Fixtures

  /// Bands that move orange and blue, the colors the patches include.
  static let mixer = ColorMixerFeature(
    bands: .init(
      orange: .init(hue: 30, saturation: 40, luminance: -20),
      blue: .init(saturation: -50)
    )
  )

  /// sRGB 8-bit patches: orange, skin, gray, blue, dark, and green.
  static let patchColors: [[UInt8]] = [
    [230, 120, 40], [200, 150, 120], [128, 128, 128], [30, 60, 200], [40, 30, 20], [60, 170, 60],
  ]

  /// One square of `scale` pixels per patch, in a row, tagged sRGB.
  static func patches(scale: Int) -> CIImage {
    let width = patchColors.count * scale
    var bytes = [UInt8](repeating: 255, count: width * scale * 4)
    for y in 0..<scale {
      for x in 0..<width {
        let color = patchColors[x / scale]
        let offset = (y * width + x) * 4
        bytes[offset] = color[0]
        bytes[offset + 1] = color[1]
        bytes[offset + 2] = color[2]
      }
    }
    return CIImage(
      bitmapData: Data(bytes),
      bytesPerRow: width * 4,
      size: CGSize(width: width, height: scale),
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
  }

  static func context(workingColorSpace: CGColorSpace) -> CIContext {
    CIContext(options: [
      .workingColorSpace: workingColorSpace,
      .workingFormat: CIFormat.RGBAh,
      .cacheIntermediates: false,
    ])
  }

  /// Renders `image` through `context` and reads RGBA float components in
  /// extended-linear Display-P3.
  static func linearDisplayP3Components(of image: CIImage, context: CIContext) -> [Float] {
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
        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
      )
    }
    return components
  }

  /// The sRGB 8-bit RGB levels at the center of each patch of a frame.
  static func sRGBLevels(of frame: CGImage, scale: Int) -> [Float] {
    let image = CIImage(cgImage: frame)
    let width = Int(image.extent.width)
    let height = Int(image.extent.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    referenceContext.render(
      image,
      toBitmap: &bytes,
      rowBytes: width * 4,
      bounds: image.extent,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
    let row = height / 2
    return patchColors.indices.flatMap { index in
      let offset = (row * width + index * scale + scale / 2) * 4
      return (0..<3).map { Float(bytes[offset + $0]) }
    }
  }

  static func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
  }
}
