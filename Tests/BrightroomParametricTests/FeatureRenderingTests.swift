import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import BrightroomParametric

/// Rendering of built-in and host features through the renderers, checked
/// against explicit Core Image recipes and invariants.
struct FeatureRenderingTests {

  @Test func customFeatureRendersLikeDefaultFeatures() throws {
    // Host features need no registration or Codable conformance to render.
    struct Document: Feature {
      var body: some Feature {
        TestRedBoostFeature(amount: 0.25)
        BrightnessFeature(value: 0.02)
      }
    }
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 32, height: 24)
    )
    let expected = input
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: 0.25, y: 0, z: 0, w: 0),
        ]
      )
      .cropped(to: input.extent)
      .applyingFilter(
        "CIColorControls",
        parameters: ["inputBrightness": 0.02]
      )
      .cropped(to: input.extent)

    let output = try Self.renderer.makeImage(from: input, feature: Document())

    try Self.assertImagesMatch(
      expected,
      output,
      tolerance: 2
    )
  }

  @Test func temperatureFeatureEvaluatesTintAxis() throws {
    let output = try Self.renderer.makeImage(
      from: Self.smallInput,
      feature: TemperatureFeature(value: 0, tint: 100)
    )
    let rendered = try Self.render(output)
    let pixel = Self.rgba(in: rendered, x: 4, y: 4)

    #expect(pixel.red > pixel.green)
    #expect(pixel.blue > pixel.green)
  }

  @Test func videoFrameRendererMatchesDocumentRendering() throws {
    struct Document: Feature {
      var body: some Feature {
        ExposureFeature(value: 0.4)
        BrightnessFeature(value: 0.04)
      }
    }
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 44, height: 30)
    )
    let expected = try Self.renderer.makeImage(from: input, feature: Document())
    let output = try ParametricVideoRenderer().makeFrameImage(
      from: input,
      feature: Document()
    )

    try Self.assertImagesMatch(
      expected,
      output,
      tolerance: 2
    )
  }

  @Test func videoFrameRendererPassesPresentationTimeToFeatureEvaluation() throws {
    let presentationTime = CMTime(value: 17, timescale: 30)

    _ = try ParametricVideoRenderer().makeFrameImage(
      from: Self.smallInput,
      feature: TestPresentationTimeFeature(expectedPresentationTime: presentationTime),
      presentationTime: presentationTime
    )
  }

  @Test func imageRendererDefaultsPresentationTimeToZero() throws {
    _ = try ParametricImageRenderer().makeImage(
      from: Self.smallInput,
      feature: TestPresentationTimeFeature(expectedPresentationTime: .zero)
    )
  }

  @Test func videoRendererResolvesCropOutputRenderSize() throws {
    let renderSize = try ParametricVideoRenderer().resolveRenderSize(
      sourceRenderSize: CGSize(width: 48, height: 36),
      feature: CropFeature(cropRect: CGRect(x: 8, y: 6, width: 24, height: 18)),
      mode: .featureOutput
    )

    #expect(renderSize == CGSize(width: 24, height: 18))
  }

  @Test func videoRendererCreatesVideoComposition() throws {
    let assetSize = CGSize(width: 48, height: 36)
    let asset = try Self.makeTestVideoAsset(size: assetSize)
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }

    let composition = try ParametricVideoRenderer().makeVideoComposition(
      for: asset,
      feature: BrightnessFeature(value: 0.03),
      renderSizeMode: .source
    )

    #expect(composition.renderSize == assetSize)
  }

  @Test func videoFrameRendererPlacesOutputInsideRenderExtent() throws {
    struct Document: Feature {
      var body: some Feature {
        CropFeature(cropRect: CGRect(x: 8, y: 6, width: 24, height: 18))
        BrightnessFeature(value: 0.05)
      }
    }
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 48, height: 36)
    )
    let renderExtent = CGRect(x: 0, y: 0, width: 48, height: 36)
    let featureOutput = try Self.renderer.makeImage(from: input, feature: Document())
    let expected = featureOutput
      .composited(
        over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
          .cropped(to: renderExtent)
      )
      .cropped(to: renderExtent)
    let output = try ParametricVideoRenderer().makeFrameImage(
      from: input,
      feature: Document(),
      renderExtent: renderExtent
    )

    #expect(output.extent == renderExtent)
    try Self.assertImagesMatch(
      expected,
      output,
      tolerance: 2
    )
  }

  @Test func multipleCropsEvaluateInCurrentDomain() throws {
    let first = CGRect(x: 10, y: 10, width: 80, height: 80)
    let second = CGRect(x: 20, y: 20, width: 25, height: 30)
    struct Document: Feature {
      var first: CropFeature
      var second: CropFeature

      var body: some Feature {
        first
        second
      }
    }
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 100, height: 100)
    )

    let output = try Self.renderer.makeImage(
      from: input,
      feature: Document(first: CropFeature(cropRect: first), second: CropFeature(cropRect: second))
    )

    #expect(output.extent == CGRect(x: 0, y: 0, width: 25, height: 30))

    // The second rectangle is relative to the first crop's output.
    let expected = input
      .cropped(to: first)
      .transformed(by: CGAffineTransform(translationX: -first.minX, y: -first.minY))
      .cropped(to: second)
      .transformed(by: CGAffineTransform(translationX: -second.minX, y: -second.minY))
    try Self.assertImagesMatch(expected, output, tolerance: 2)
  }

  @Test func imageEffectReceivesCurrentExtentAfterCrop() throws {
    struct Document: Feature {
      var body: some Feature {
        CropFeature(cropRect: CGRect(x: 10, y: 8, width: 40, height: 20))
        TestExtentProbeFeature()
      }
    }
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 80, height: 60)
    )

    let output = try Self.renderer.makeImage(from: input, feature: Document())

    #expect(output.extent == CGRect(x: 0, y: 0, width: 40, height: 20))
    let rendered = try Self.render(output)
    let pixel = Self.rgba(in: rendered, x: 20, y: 10)
    #expect(abs(Int(pixel.red) - 102) <= 2)
    #expect(abs(Int(pixel.green) - 51) <= 2)
  }

  @Test func vignetteUsesCurrentExtentAfterCrop() throws {
    let crop = CropFeature(cropRect: CGRect(x: 10, y: 8, width: 40, height: 20))
    let vignette = VignetteFeature(value: 0.5)
    struct CropThenVignette: Feature {
      var crop: CropFeature
      var vignette: VignetteFeature

      var body: some Feature {
        crop
        vignette
      }
    }
    struct VignetteThenCrop: Feature {
      var crop: CropFeature
      var vignette: VignetteFeature

      var body: some Feature {
        vignette
        crop
      }
    }
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 80, height: 60)
    )
    let cropped = input
      .cropped(to: CGRect(x: 10, y: 8, width: 40, height: 20))
      .transformed(by: CGAffineTransform(translationX: -10, y: -8))
    let expected = Self.vignetteEffectImage(value: 0.5, image: cropped)

    let output = try Self.renderer.makeImage(
      from: input,
      feature: CropThenVignette(crop: crop, vignette: vignette)
    )

    try Self.assertImagesMatch(expected, output, tolerance: 2)

    // The vignette centers on the domain it receives, so applying it before
    // the crop gives a different image.
    let vignetteBeforeCrop = try Self.renderer.makeImage(
      from: input,
      feature: VignetteThenCrop(crop: crop, vignette: vignette)
    )
    #expect(vignetteBeforeCrop.extent == output.extent)
    #expect(
      try Self.maximumChannelDifference(output, vignetteBeforeCrop) > 4,
      "a vignette before the crop must differ from one after it"
    )
  }

  @Test func localAdjustmentsAndGlobalEffectEvaluateInOrder() throws {
    struct Document: Feature {
      var body: some Feature {
        LocalAdjustment(
          maskTree: MaskTree(
            root: .brush(
              BrushMask(strokes: [
                BrushMaskStroke(
                  stamps: [CGPoint(x: 10, y: 10)],
                  brush: BrushMaskBrush(diameter: 16, hardness: 1, opacity: 1)
                ),
              ])
            )
          )
        ) {
          ExposureFeature(value: 1)
        }
        LocalAdjustment(
          maskTree: MaskTree(
            root: .brush(
              BrushMask(strokes: [
                BrushMaskStroke(
                  stamps: [CGPoint(x: 20, y: 10)],
                  brush: BrushMaskBrush(diameter: 18, hardness: 1, opacity: 1)
                ),
              ])
            )
          )
        ) {
          GaussianBlurFeature(radius: 5)
        }
        BrightnessFeature(value: 0.05)
      }
    }
    let input = CIImage.parametricVerticalStripeImage(
      extent: CGRect(x: 0, y: 0, width: 40, height: 20),
      backgroundWhite: 0.15,
      stripeWhite: 0.9,
      stripeRect: CGRect(x: 22, y: 0, width: 2, height: 20)
    )

    let output = try Self.renderer.makeImage(from: input, feature: Document())
    let renderedImage = try Self.render(output)
    let localPixel = Self.rgba(in: renderedImage, x: 10, y: 10)
    let outsidePixel = Self.rgba(in: renderedImage, x: 0, y: 10)
    let blurredNeighborPixel = Self.rgba(in: renderedImage, x: 19, y: 10)
    let stripePixel = Self.rgba(in: renderedImage, x: 22, y: 10)

    #expect(localPixel.red > outsidePixel.red)
    #expect(blurredNeighborPixel.red > outsidePixel.red)
    #expect(blurredNeighborPixel.red < stripePixel.red)
  }

  @Test func invertedMaskAppliesOutsideBrush() throws {
    let document = LocalAdjustment(
      maskTree: MaskTree(
        root: .invert(
          .brush(
            BrushMask(strokes: [
              BrushMaskStroke(
                stamps: [CGPoint(x: 10, y: 10)],
                brush: BrushMaskBrush(diameter: 12, hardness: 1, opacity: 1)
              ),
            ])
          )
        )
      )
    ) {
      ExposureFeature(value: 1)
    }
    let input = CIImage.parametricTestImage(
      white: 0.2,
      extent: CGRect(x: 0, y: 0, width: 20, height: 20)
    )

    let output = try Self.renderer.makeImage(from: input, feature: document)
    let renderedImage = try Self.render(output)
    let center = Self.rgba(in: renderedImage, x: 10, y: 10)
    let corner = Self.rgba(in: renderedImage, x: 1, y: 1)

    #expect(corner.red > center.red)
  }

  @Test func metalKernelRegistryCanCreateBrushStampRecipe() throws {
    let registry = ParametricKernelRegistry()

    let image = try registry.makeBrushStamp(
      extent: CGRect(x: 0, y: 0, width: 12, height: 12),
      center: CGPoint(x: 6, y: 6),
      radius: 4,
      hardness: 0.5,
      opacity: 1
    )

    #expect(image.extent == CGRect(x: 0, y: 0, width: 12, height: 12))
  }

  private static let renderer = ParametricImageRenderer()

  private static let smallInput = CIImage.parametricTestImage(
    white: 0.5,
    extent: CGRect(x: 0, y: 0, width: 8, height: 8)
  )

  private static let context = CIContext()

  private static func render(_ image: CIImage) throws -> CGImage {
    try #require(Self.context.createCGImage(image, from: image.extent))
  }

  private static func rgba(in image: CGImage, x: Int, y: Int) -> RGBA {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let index = (y * width + x) * 4
    return RGBA(
      red: pixels[index],
      green: pixels[index + 1],
      blue: pixels[index + 2],
      alpha: pixels[index + 3]
    )
  }

  /// The largest 8-bit color channel difference over every pixel of two
  /// images of the same extent.
  private static func maximumChannelDifference(_ lhs: CIImage, _ rhs: CIImage) throws -> Int {
    let lhsBytes = rgbaBytes(of: try render(lhs))
    let rhsBytes = rgbaBytes(of: try render(rhs))
    var result = 0
    for index in lhsBytes.indices where index % 4 != 3 {
      result = max(result, abs(Int(lhsBytes[index]) - Int(rhsBytes[index])))
    }
    return result
  }

  private static func rgbaBytes(of image: CGImage) -> [UInt8] {
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
    return pixels
  }

  private static func assertImagesMatch(
    _ lhs: CIImage,
    _ rhs: CIImage,
    tolerance: Int,
    sourceLocation: SourceLocation = SourceLocation(
      fileID: #fileID,
      filePath: #filePath,
      line: #line,
      column: #column
    )
  ) throws {
    #expect(lhs.extent == rhs.extent, sourceLocation: sourceLocation)

    let lhsImage = try render(lhs)
    let rhsImage = try render(rhs)
    #expect(lhsImage.width == rhsImage.width, sourceLocation: sourceLocation)
    #expect(lhsImage.height == rhsImage.height, sourceLocation: sourceLocation)

    let sampleXs = [4, lhsImage.width / 3, lhsImage.width / 2, max(lhsImage.width - 5, 0)]
    let sampleYs = [4, lhsImage.height / 3, lhsImage.height / 2, max(lhsImage.height - 5, 0)]

    for y in sampleYs {
      for x in sampleXs {
        let lhsPixel = rgba(in: lhsImage, x: x, y: y)
        let rhsPixel = rgba(in: rhsImage, x: x, y: y)
        #expect(
          abs(Int(lhsPixel.red) - Int(rhsPixel.red)) <= tolerance,
          "red mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
        )
        #expect(
          abs(Int(lhsPixel.green) - Int(rhsPixel.green)) <= tolerance,
          "green mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
        )
        #expect(
          abs(Int(lhsPixel.blue) - Int(rhsPixel.blue)) <= tolerance,
          "blue mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
        )
        #expect(
          abs(Int(lhsPixel.alpha) - Int(rhsPixel.alpha)) <= tolerance,
          "alpha mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
        )
      }
    }
  }

  private static func vignetteEffectImage(value: Double, image: CIImage) -> CIImage {
    let extent = image.extent
    let radius = max(extent.width, extent.height) * 0.5
    return image.applyingFilter(
      "CIVignetteEffect",
      parameters: [
        kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
        kCIInputRadiusKey: radius,
        kCIInputIntensityKey: value,
        "inputFalloff": 0.5,
      ]
    )
    .cropped(to: extent)
  }

  private static func makeTestVideoAsset(size: CGSize) throws -> AVURLAsset {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("brightroom-parametric-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
    )

    guard writer.canAdd(input) else {
      throw TestVideoAssetError.cannotAddInput
    }

    writer.add(input)

    guard writer.startWriting() else {
      throw writer.error ?? TestVideoAssetError.cannotStartWriting
    }

    writer.startSession(atSourceTime: .zero)

    let pixelBuffer = try makeTestPixelBuffer(
      width: Int(size.width),
      height: Int(size.height)
    )
    while !input.isReadyForMoreMediaData {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
      throw writer.error ?? TestVideoAssetError.cannotAppendFrame
    }

    input.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    semaphore.wait()

    guard writer.status == .completed else {
      throw writer.error ?? TestVideoAssetError.cannotFinishWriting(writer.status)
    }

    return AVURLAsset(url: url)
  }

  private static func makeTestPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ] as CFDictionary,
      &pixelBuffer
    )

    guard result == kCVReturnSuccess, let pixelBuffer else {
      throw TestVideoAssetError.cannotCreatePixelBuffer(result)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw TestVideoAssetError.missingPixelBufferBaseAddress
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    for y in 0..<height {
      let row = baseAddress
        .advanced(by: y * bytesPerRow)
        .assumingMemoryBound(to: UInt8.self)

      for x in 0..<width {
        let offset = x * 4
        row[offset] = UInt8(80 + (x % 24))
        row[offset + 1] = UInt8(100 + (y % 32))
        row[offset + 2] = UInt8(160)
        row[offset + 3] = UInt8(255)
      }
    }

    return pixelBuffer
  }

  private struct RGBA: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
  }

  private struct TestRedBoostFeature: ImageEffect, Equatable {

    var amount: Double

    func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      image.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: CGFloat(amount), y: 0, z: 0, w: 0),
        ]
      )
      .cropped(to: image.extent)
    }
  }

  private struct TestExtentProbeFeature: ImageEffect, Equatable {

    func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      CIImage(
        color: CIColor(
          red: min(image.extent.width / 100, 1),
          green: min(image.extent.height / 100, 1),
          blue: 0,
          alpha: 1
        )
      )
      .cropped(to: image.extent)
    }
  }

  /// Verifies that render-time values reach a host-defined effect without being
  /// stored as authored feature parameters.
  private struct TestPresentationTimeFeature: ImageEffect, Equatable {

    var expectedPresentationTime: CMTime

    func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      guard context.presentationTime == expectedPresentationTime else {
        throw TestPresentationTimeError.unexpectedTime(
          expected: expectedPresentationTime,
          actual: context.presentationTime
        )
      }
      return image
    }
  }

  private enum TestPresentationTimeError: Error {
    case unexpectedTime(expected: CMTime, actual: CMTime)
  }

  private enum TestVideoAssetError: Error {
    case cannotAddInput
    case cannotStartWriting
    case cannotAppendFrame
    case cannotFinishWriting(AVAssetWriter.Status)
    case cannotCreatePixelBuffer(CVReturn)
    case missingPixelBufferBaseAddress
  }
}

private extension CIImage {

  static func parametricTestImage(white: CGFloat, extent: CGRect) -> CIImage {
    CIImage(color: CIColor(red: white, green: white, blue: white, alpha: 1))
      .cropped(to: extent)
  }

  static func parametricVerticalStripeImage(
    extent: CGRect,
    backgroundWhite: CGFloat,
    stripeWhite: CGFloat,
    stripeRect: CGRect
  ) -> CIImage {
    let background = CIImage.parametricTestImage(
      white: backgroundWhite,
      extent: extent
    )
    let stripe = CIImage.parametricTestImage(white: stripeWhite, extent: stripeRect)

    return stripe.applyingFilter(
      "CISourceOverCompositing",
      parameters: [kCIInputBackgroundImageKey: background]
    )
    .cropped(to: extent)
  }

  static func parametricColorPatchImage(extent: CGRect) -> CIImage {
    let background = CIImage(color: CIColor(red: 0.18, green: 0.32, blue: 0.52, alpha: 1))
      .cropped(to: extent)
    let warmPatch = CIImage(color: CIColor(red: 0.86, green: 0.26, blue: 0.18, alpha: 0.82))
      .cropped(
        to: CGRect(
          x: extent.minX + extent.width * 0.18,
          y: extent.minY,
          width: extent.width * 0.22,
          height: extent.height
        )
      )
    let coolPatch = CIImage(color: CIColor(red: 0.16, green: 0.45, blue: 0.92, alpha: 0.78))
      .cropped(
        to: CGRect(
          x: extent.minX + extent.width * 0.56,
          y: extent.minY,
          width: extent.width * 0.28,
          height: extent.height
        )
      )
    let brightPatch = CIImage(color: CIColor(red: 0.95, green: 0.92, blue: 0.76, alpha: 0.65))
      .cropped(
        to: CGRect(
          x: extent.minX,
          y: extent.minY + extent.height * 0.2,
          width: extent.width,
          height: extent.height * 0.3
        )
      )

    return [warmPatch, coolPatch, brightPatch].reduce(background) { image, patch in
      patch.applyingFilter(
        "CISourceOverCompositing",
        parameters: [kCIInputBackgroundImageKey: image]
      )
    }
    .cropped(to: extent)
  }
}
