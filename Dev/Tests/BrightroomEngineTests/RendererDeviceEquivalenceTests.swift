import Testing
import Foundation
import CoreGraphics
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Verifies the GPU-backed CIContext path produces output equivalent to the
/// software renderer that exports historically used (#105, #169), so that
/// `RenderingDevice.automatic` can safely default to GPU rendering.
struct RendererDeviceEquivalenceTests {

  private enum ColorSpaces {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
  }

  @Test func `Equivalence display P3 input no effects`() async throws {
    let image = Asset.instaLogo.image
    #expect(ImageSource(image: image).loadOriginalCGImage().colorSpace == ColorSpaces.displayP3)

    try await assertDeviceEquivalence(
      image: image,
      options: .init(workingColorSpace: ColorSpaces.displayP3),
      configure: { _ in }
    )
  }

  @Test func `Equivalence sRGB input effects crop`() async throws {
    try await assertDeviceEquivalence(
      image: Asset.unsplash2.image,
      options: .init(workingColorSpace: ColorSpaces.displayP3),
      configure: { renderer in
        let effects = EffectPipeline(effects: [ExposureFeature(value: 0.72)])

        let size = renderer.source.readImageSize()
        let crop = CropFeature.test(
          imageSize: size,
          cropRect: CropGeometry.cropRect(toFitAspectRatio: .square, in: size)
        )

        renderer.edit = .make(crop: crop, orientedImageSize: size, effects: effects)
      }
    )
  }

  @Test func `Equivalence display P3 input effects`() async throws {
    try await assertDeviceEquivalence(
      image: Asset.instaLogo.image,
      options: .init(workingColorSpace: ColorSpaces.displayP3),
      configure: { renderer in
        renderer.edit = .make(
          crop: CropFeature.test(imageSize: renderer.source.readImageSize()),
          orientedImageSize: renderer.source.readImageSize(),
          effects: EffectPipeline(effects: [ExposureFeature(value: -0.5)])
        )
      }
    )
  }

  @Test func `Equivalence sRGB input intrinsic color space effects`() async throws {
    // workingColorSpace nil: rendering uses the source's intrinsic color space.
    try await assertDeviceEquivalence(
      image: Asset.unsplash3.image,
      options: .init(),
      configure: { renderer in
        renderer.edit = .make(
          crop: CropFeature.test(imageSize: renderer.source.readImageSize()),
          orientedImageSize: renderer.source.readImageSize(),
          effects: EffectPipeline(effects: [ExposureFeature(value: 0.72)])
        )
      }
    )
  }

  // MARK: - Helpers

  private func assertDeviceEquivalence(
    image: UIImage,
    options: BrightRoomImageRenderer.Options,
    configure: (BrightRoomImageRenderer) -> Void,
    maxChannelDifference: Int = 3,
    sourceLocation: SourceLocation = SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
  ) async throws {
    let gpuRendered = try await render(image: image, device: .gpu, options: options, configure: configure)
    let cpuRendered = try await render(image: image, device: .software, options: options, configure: configure)

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
    device: BrightRoomImageRenderer.RenderingDevice,
    options: BrightRoomImageRenderer.Options,
    configure: (BrightRoomImageRenderer) -> Void
  ) async throws -> BrightRoomImageRenderer.Rendered {
    let renderer = BrightRoomImageRenderer(source: ImageSource(image: image), orientation: .up)
    renderer.renderingDevice = device
    configure(renderer)
    return try await renderer.render(options: options)
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
