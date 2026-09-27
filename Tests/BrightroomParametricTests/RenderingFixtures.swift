//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import CoreImage
import CoreMedia
import Foundation
import Testing

/// Shared sources, masks, and pixel comparison for the rendering tests.
enum RenderingFixtures {

  /// The source extent. Its origin is not zero, so chain-entry normalization
  /// takes part in every comparison.
  static let sourceExtent = CGRect(x: 23, y: 17, width: 320, height: 240)

  /// The chain-entry extent after normalization.
  static let entryExtent = CGRect(origin: .zero, size: sourceExtent.size)

  /// The color space pixels are compared in.
  static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

  /// The largest channel difference accepted as equal.
  ///
  /// Equivalent documents build the same Core Image graph, so any real
  /// difference is several orders of magnitude larger.
  static let tolerance: Float = 0.000_1

  /// The smallest channel difference that counts as a visible edit.
  static let visibleDifference: Float = 0.01

  static let renderer = FeatureRenderer()

  static let context = CIContext(options: [
    .workingFormat: CIFormat.RGBAf,
    .workingColorSpace: workingColorSpace,
    .cacheIntermediates: false,
  ])

  /// A deterministic source with a color ramp, hard checker edges for blur
  /// and sharpen, saturated patches for the color mixer, and near-white and
  /// near-black patches for tone features.
  static func makeSource() throws -> CIImage {
    let extent = sourceExtent
    let ramp = try #require(
      CIFilter(
        name: "CILinearGradient",
        parameters: [
          "inputPoint0": CIVector(x: extent.minX, y: extent.minY),
          "inputPoint1": CIVector(x: extent.maxX, y: extent.maxY),
          "inputColor0": CIColor(red: 0.86, green: 0.24, blue: 0.12),
          "inputColor1": CIColor(red: 0.08, green: 0.36, blue: 0.92),
        ]
      )?
      .outputImage
    )
    let checkerboard = try #require(
      CIFilter(
        name: "CICheckerboardGenerator",
        parameters: [
          "inputCenter": CIVector(x: extent.minX, y: extent.minY),
          "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.35),
          "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
          "inputWidth": 12,
          "inputSharpness": 1,
        ]
      )?
      .outputImage
    )
    let patches: [(unitRect: CGRect, color: CIColor)] = [
      (CGRect(x: 0.08, y: 0.62, width: 0.22, height: 0.26), CIColor(red: 0.12, green: 0.78, blue: 0.2)),
      (CGRect(x: 0.40, y: 0.66, width: 0.18, height: 0.22), CIColor(red: 0.95, green: 0.86, blue: 0.1)),
      (CGRect(x: 0.70, y: 0.58, width: 0.22, height: 0.30), CIColor(red: 0.82, green: 0.1, blue: 0.7)),
      (CGRect(x: 0.56, y: 0.08, width: 0.18, height: 0.20), CIColor(red: 0.98, green: 0.97, blue: 0.95)),
      (CGRect(x: 0.80, y: 0.08, width: 0.14, height: 0.20), CIColor(red: 0.03, green: 0.03, blue: 0.04)),
    ]

    var image = checkerboard.composited(over: ramp)
    for patch in patches {
      let rect = CGRect(
        x: extent.minX + patch.unitRect.minX * extent.width,
        y: extent.minY + patch.unitRect.minY * extent.height,
        width: patch.unitRect.width * extent.width,
        height: patch.unitRect.height * extent.height
      )
      .integral
      image = CIImage(color: patch.color).cropped(to: rect).composited(over: image)
    }
    return image.cropped(to: extent)
  }

  /// The source as every document receives it at chain entry.
  static func normalizedSource() throws -> CIImage {
    try renderer.makeImage(from: makeSource(), feature: EmptyFeature())
  }

  // MARK: Oracles

  /// Blends `adjusted` over `base` through `mask` with the raw Core Image
  /// filter, independent of `LocalAdjustment`.
  static func explicitBlend(adjusted: CIImage, base: CIImage, mask: CIImage) -> CIImage {
    adjusted.applyingFilter(
      "CIBlendWithAlphaMask",
      parameters: [
        kCIInputBackgroundImageKey: base,
        kCIInputMaskImageKey: mask,
      ]
    )
    .cropped(to: base.extent)
  }

  /// A value-form Gaussian blur rebuilt from raw filters: the radius is
  /// `diagonal(basis) × value / 2000`, and the input is clamped before the
  /// blur and cropped after it, as the built-in recipe does.
  static func explicitValueBlur(_ image: CIImage, value: Double, basis: CGRect) -> CIImage {
    let radius = hypot(basis.width, basis.height) * value / 2_000
    return image
      .clamped(to: image.extent)
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: image.extent)
  }

  /// Translates an image so its extent starts at zero.
  static func removingOffset(_ image: CIImage) -> CIImage {
    image.transformed(
      by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
    )
  }

  /// The alpha channel of a mask image, one float per pixel.
  static func alpha(of mask: CIImage) -> [Float] {
    pixels(of: mask).enumerated().compactMap { index, component in
      index % 4 == 3 ? component : nil
    }
  }

  /// The largest per-pixel difference between two alpha fields.
  static func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    precondition(lhs.count == rhs.count)
    return zip(lhs, rhs).reduce(0) { result, pair in
      let difference = abs(pair.0 - pair.1)
      return difference.isNaN ? .infinity : max(result, difference)
    }
  }

  // MARK: Masks

  /// A soft stroke in the lower-left of the entry domain (y-up).
  static let lowerLeftStroke = BrushMaskStroke(
    stamps: [
      CGPoint(x: 50, y: 50),
      CGPoint(x: 70, y: 56),
      CGPoint(x: 90, y: 62),
      CGPoint(x: 110, y: 66),
    ],
    brush: BrushMaskBrush(diameter: 44, hardness: 0.4, opacity: 0.9)
  )

  /// A hard stroke that crosses `lowerLeftStroke`.
  static let crossingStroke = BrushMaskStroke(
    stamps: [
      CGPoint(x: 80, y: 36),
      CGPoint(x: 84, y: 60),
      CGPoint(x: 88, y: 84),
    ],
    brush: BrushMaskBrush(diameter: 30, hardness: 1, opacity: 1)
  )

  /// A hard stroke in the upper-right of the entry domain.
  static let upperRightStroke = BrushMaskStroke(
    stamps: [
      CGPoint(x: 230, y: 170),
      CGPoint(x: 250, y: 180),
    ],
    brush: BrushMaskBrush(diameter: 60, hardness: 0.8, opacity: 1)
  )

  /// A feathered brush united with a hard brush.
  static func featheredBrushMaskTree() -> MaskTree {
    MaskTree(
      root: .union([
        .feather(
          MaskFeather(
            input: .brush(BrushMask(strokes: [lowerLeftStroke])),
            radius: 6
          )
        ),
        .brush(BrushMask(strokes: [upperRightStroke])),
      ])
    )
  }

  // MARK: Color features

  /// A non-neutral curve on the luminance and red channels.
  static func makeToneCurve() -> ToneCurveFeature {
    var y = ToneCurve()
    y.movePoint(at: 0, input: 0, output: 0.03)
    y.insertPoint(input: 0.3, output: 0.22)
    y.insertPoint(input: 0.72, output: 0.84)
    var red = ToneCurve()
    red.insertPoint(input: 0.5, output: 0.58)
    return ToneCurveFeature(value: ToneCurveEditorValue(y: y, red: red))
  }

  /// A small cross-processing lookup table.
  static func makeColorCube() -> ColorCubeFeature {
    let dimension = 8
    let scale = Float(dimension - 1)
    var values: [Float] = []
    values.reserveCapacity(dimension * dimension * dimension * 4)
    for blueIndex in 0..<dimension {
      for greenIndex in 0..<dimension {
        for redIndex in 0..<dimension {
          let red = Float(redIndex) / scale
          let green = Float(greenIndex) / scale
          let blue = Float(blueIndex) / scale
          values += [
            min(red * 0.85 + green * 0.15 + 0.04, 1),
            pow(green, 0.8),
            blue * 0.7 + 0.1,
            1,
          ]
        }
      }
    }
    return ColorCubeFeature(
      name: "Cross Process",
      identifier: "composition-tests.cross-process",
      amount: 0.85,
      dimension: dimension,
      cubeData: values.withUnsafeBufferPointer { Data(buffer: $0) }
    )
  }

  // MARK: Video

  /// Writes an H.264 movie of `image`, which must have a zero origin, with
  /// one frame per second for `frameCount` seconds.
  static func makeVideoAsset(from image: CIImage, frameCount: Int = 1) async throws -> AVURLAsset {
    let width = Int(image.extent.width)
    let height = Int(image.extent.height)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("composition-tests-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: nil
    )
    try #require(writer.canAdd(input))
    writer.add(input)
    try #require(writer.startWriting(), "\(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
      &pixelBuffer
    )
    let frame = try #require(pixelBuffer, "CVPixelBufferCreate failed: \(status)")
    context.render(
      image,
      to: frame,
      bounds: image.extent,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )

    for index in 0..<frameCount {
      while input.isReadyForMoreMediaData == false {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(
        adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 1)),
        "\(String(describing: writer.error))"
      )
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: 1))
    await writer.finishWriting()
    try #require(writer.status == .completed, "\(String(describing: writer.error))")

    return AVURLAsset(url: url)
  }

  /// Decodes the frame at time zero through a video composition.
  static func firstFrame(
    of asset: AVAsset,
    composition: AVVideoComposition
  ) async throws -> CGImage {
    try await frame(of: asset, composition: composition, at: .zero)
  }

  /// Decodes the frame at `time` through a video composition.
  static func frame(
    of asset: AVAsset,
    composition: AVVideoComposition,
    at time: CMTime
  ) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.videoComposition = composition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: time).image
  }

  // MARK: Pixels

  /// Renders an image into RGBA float components in the working color space.
  static func pixels(of image: CIImage) -> [Float] {
    let extent = image.extent
    let width = Int(extent.width)
    let height = Int(extent.height)
    var components = [Float](repeating: 0, count: width * height * 4)
    components.withUnsafeMutableBytes { bytes in
      context.render(
        image,
        toBitmap: bytes.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: extent,
        format: .RGBAf,
        colorSpace: workingColorSpace
      )
    }
    return components
  }

  /// The largest channel difference between two images of the same extent.
  static func maximumDifference(_ lhs: CIImage, _ rhs: CIImage) -> Float {
    zip(pixels(of: lhs), pixels(of: rhs)).reduce(0) { result, pair in
      let difference = abs(pair.0 - pair.1)
      return difference.isNaN ? .infinity : max(result, difference)
    }
  }

  /// Expects two images to have the same extent and the same pixels within
  /// `tolerance` (the fixture's same-pipeline tolerance by default).
  static func expectPixelsMatch(
    _ expected: CIImage,
    _ actual: CIImage,
    tolerance: Float = RenderingFixtures.tolerance,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(expected.extent == actual.extent, sourceLocation: sourceLocation)
    #expect(
      expected.extent.integral == expected.extent && expected.extent.isEmpty == false,
      "compared extents must be non-empty whole pixels: \(expected.extent)",
      sourceLocation: sourceLocation
    )
    guard expected.extent == actual.extent, expected.extent.integral == expected.extent else {
      return
    }
    let difference = maximumDifference(expected, actual)
    #expect(
      difference <= tolerance,
      "max channel difference \(difference)",
      sourceLocation: sourceLocation
    )
  }

  /// Expects two images to differ visibly: in extent, or by at least
  /// `visibleDifference` in some channel.
  static func expectVisiblyDifferent(
    _ lhs: CIImage,
    _ rhs: CIImage,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard lhs.extent == rhs.extent else {
      return
    }
    let difference = maximumDifference(lhs, rhs)
    #expect(
      difference >= visibleDifference,
      "expected a visible difference, max channel difference \(difference)",
      sourceLocation: sourceLocation
    )
  }
}

/// A test-only primitive that applies its steps in order.
///
/// The fold oracle for order tests: it shares no code with `FeatureBuilder`,
/// `TupleFeature`, `Optional`, `EitherFeature`, `Array`, or composite `body`
/// evaluation, as long as every step is a primitive leaf. Expand a preset into
/// `preset.effects.map(\.base)` before listing it.
struct SequentialFeatures: Feature {

  var steps: [any Feature]

  init(_ steps: [any Feature]) {
    self.steps = steps
  }

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try steps.reduce(image) { image, step in
      try step.apply(to: image, context: context)
    }
  }
}
