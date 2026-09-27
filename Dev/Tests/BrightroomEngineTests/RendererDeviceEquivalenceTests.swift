import Testing
import Foundation
import CoreGraphics
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Verifies the GPU-backed CIContext path produces output equivalent to the
/// software renderer that exports historically used (#105, #169), so that
/// `ExportRenderer.Device.automatic` can safely default to GPU rendering.
struct RendererDeviceEquivalenceTests {

  private enum ColorSpaces {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
  }

  @Test func `Equivalence display P3 input no effects`() async throws {
    let image = Asset.instaLogo.image
    #expect(image.decodedCGImageForTesting.colorSpace == ColorSpaces.displayP3)

    try await assertDeviceEquivalence(
      image: image,
      options: .init(outputColorSpace: ColorSpaces.displayP3),
      makeDocument: { size in RendererTestDocument(crop: CropFeature.test(imageSize: size)) }
    )
  }

  @Test func `Equivalence sRGB input effects crop`() async throws {
    try await assertDeviceEquivalence(
      image: Asset.unsplash2.image,
      options: .init(outputColorSpace: ColorSpaces.displayP3),
      makeDocument: { size in
        let crop = CropFeature.test(
          imageSize: size,
          cropRect: CropGeometry.cropRect(toFitAspectRatio: .square, in: size)
        )

        return RendererTestDocument(
          effects: [AnyImageEffect(ExposureFeature(value: 0.72))],
          crop: crop
        )
      }
    )
  }

  @Test func `Equivalence display P3 input effects`() async throws {
    try await assertDeviceEquivalence(
      image: Asset.instaLogo.image,
      options: .init(outputColorSpace: ColorSpaces.displayP3),
      makeDocument: { size in
        RendererTestDocument(
          effects: [AnyImageEffect(ExposureFeature(value: -0.5))],
          crop: CropFeature.test(imageSize: size)
        )
      }
    )
  }

  @Test func `Equivalence sRGB input intrinsic color space effects`() async throws {
    // outputColorSpace nil: rendering uses the source's intrinsic color space.
    try await assertDeviceEquivalence(
      image: Asset.unsplash3.image,
      options: .init(),
      makeDocument: { size in
        RendererTestDocument(
          effects: [AnyImageEffect(ExposureFeature(value: 0.72))],
          crop: CropFeature.test(imageSize: size)
        )
      }
    )
  }

  // MARK: - Helpers

  private func assertDeviceEquivalence(
    image: UIImage,
    options: ExportRenderer.Options,
    makeDocument: (_ imageSize: CGSize) -> RendererTestDocument,
    maxChannelDifference: Int = 3,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
  ) async throws {
    let gpuRendered = try await render(image: image, device: .gpu, options: options, makeDocument: makeDocument)
    let cpuRendered = try await render(image: image, device: .software, options: options, makeDocument: makeDocument)

    let gpuImage = try gpuRendered.cgImage
    let cpuImage = try cpuRendered.cgImage

    #expect(gpuImage.width == cpuImage.width, sourceLocation: sourceLocation)
    #expect(gpuImage.height == cpuImage.height, sourceLocation: sourceLocation)
    #expect(gpuImage.colorSpace == cpuImage.colorSpace, sourceLocation: sourceLocation)

    let gpuPixels = try rgba8Data(of: gpuImage)
    let cpuPixels = try rgba8Data(of: cpuImage)

    #expect(gpuPixels.count == cpuPixels.count, sourceLocation: sourceLocation)

    var maxDifference = 0
    var totalDifference = 0

    for index in 0..<min(gpuPixels.count, cpuPixels.count) {
      let difference = abs(Int(gpuPixels[index]) - Int(cpuPixels[index]))
      maxDifference = Swift.max(maxDifference, difference)
      totalDifference += difference
    }

    let meanDifference = Double(totalDifference) / Double(gpuPixels.count)

    print("GPU/CPU difference - max: \(maxDifference), mean: \(meanDifference)")

    #expect(
      maxDifference <= maxChannelDifference,
      "GPU and software renderer output diverged beyond tolerance (mean: \(meanDifference)).",
      sourceLocation: sourceLocation
    )
  }

  private func render(
    image: UIImage,
    device: ExportRenderer.Device,
    options: ExportRenderer.Options,
    makeDocument: (_ imageSize: CGSize) -> RendererTestDocument
  ) async throws -> RenderedImage {
    let source = SourceImage.test(image)
    return try EditingDocument(image: source, feature: makeDocument(source.pixelSize))
      .renderForTesting(options: options, device: device)
  }

  private func rgba8Data(of image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = try #require(image.colorSpace)

    try data.withUnsafeMutableBytes { buffer in
      let context = try #require(
        CGContext(
          data: buffer.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      context.draw(image, in: .init(origin: .zero, size: .init(width: width, height: height)))
    }

    return data
  }
}
