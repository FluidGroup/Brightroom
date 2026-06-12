import XCTest

@testable import BrightroomEngine

/// Verifies the GPU-backed CIContext path produces output equivalent to the
/// software renderer that exports historically used (#105, #169), so that
/// `RenderingDevice.automatic` can safely default to GPU rendering.
final class RendererDeviceEquivalenceTests: XCTestCase {

  private enum ColorSpaces {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
  }

  func testEquivalence_displayP3Input_noEffects() throws {
    let image = Asset.instaLogo.image
    XCTAssertEqual(ImageSource(image: image).loadOriginalCGImage().colorSpace, ColorSpaces.displayP3)

    try assertDeviceEquivalence(
      image: image,
      options: .init(workingColorSpace: ColorSpaces.displayP3),
      configure: { _ in }
    )
  }

  func testEquivalence_sRGBInput_effects_crop() throws {
    try assertDeviceEquivalence(
      image: Asset.unsplash2.image,
      options: .init(workingColorSpace: ColorSpaces.displayP3),
      configure: { renderer in
        var filter = FilterExposure()
        filter.value = 0.72

        var crop = EditingCrop(imageSize: renderer.source.readImageSize())
        crop.updateCropExtent(toFitAspectRatio: .square)

        renderer.edit = .init(
          croppingRect: crop,
          modifiers: [filter.asAny()],
          drawer: []
        )
      }
    )
  }

  func testEquivalence_displayP3Input_effects() throws {
    try assertDeviceEquivalence(
      image: Asset.instaLogo.image,
      options: .init(workingColorSpace: ColorSpaces.displayP3),
      configure: { renderer in
        var filter = FilterExposure()
        filter.value = -0.5

        renderer.edit.modifiers = [filter.asAny()]
      }
    )
  }

  func testEquivalence_sRGBInput_intrinsicColorSpace_effects() throws {
    // workingColorSpace nil: rendering uses the source's intrinsic color space.
    try assertDeviceEquivalence(
      image: Asset.unsplash3.image,
      options: .init(),
      configure: { renderer in
        var filter = FilterExposure()
        filter.value = 0.72

        renderer.edit.modifiers = [filter.asAny()]
      }
    )
  }

  // MARK: - Helpers

  private func assertDeviceEquivalence(
    image: UIImage,
    options: BrightRoomImageRenderer.Options,
    configure: (BrightRoomImageRenderer) -> Void,
    maxChannelDifference: Int = 3,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let gpuRendered = try render(image: image, device: .gpu, options: options, configure: configure)
    let cpuRendered = try render(image: image, device: .software, options: options, configure: configure)

    XCTAssertEqual(gpuRendered.engine, .combined, file: file, line: line)
    XCTAssertEqual(cpuRendered.engine, .combined, file: file, line: line)

    let gpuImage = gpuRendered.cgImage
    let cpuImage = cpuRendered.cgImage

    XCTAssertEqual(gpuImage.width, cpuImage.width, file: file, line: line)
    XCTAssertEqual(gpuImage.height, cpuImage.height, file: file, line: line)
    XCTAssertEqual(gpuImage.colorSpace, cpuImage.colorSpace, file: file, line: line)

    let gpuPixels = try rgba8Data(of: gpuImage)
    let cpuPixels = try rgba8Data(of: cpuImage)

    XCTAssertEqual(gpuPixels.count, cpuPixels.count, file: file, line: line)

    var maxDifference = 0
    var totalDifference = 0

    for index in 0..<min(gpuPixels.count, cpuPixels.count) {
      let difference = abs(Int(gpuPixels[index]) - Int(cpuPixels[index]))
      maxDifference = Swift.max(maxDifference, difference)
      totalDifference += difference
    }

    let meanDifference = Double(totalDifference) / Double(gpuPixels.count)

    print("GPU/CPU difference - max: \(maxDifference), mean: \(meanDifference)")

    XCTAssertLessThanOrEqual(
      maxDifference,
      maxChannelDifference,
      "GPU and software renderer output diverged beyond tolerance (mean: \(meanDifference)).",
      file: file,
      line: line
    )
  }

  private func render(
    image: UIImage,
    device: BrightRoomImageRenderer.RenderingDevice,
    options: BrightRoomImageRenderer.Options,
    configure: (BrightRoomImageRenderer) -> Void
  ) throws -> BrightRoomImageRenderer.Rendered {
    let renderer = BrightRoomImageRenderer(source: ImageSource(image: image), orientation: .up)
    renderer.renderingDevice = device
    configure(renderer)
    return try renderer.render(options: options)
  }

  private func rgba8Data(of image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = try XCTUnwrap(image.colorSpace)

    try data.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(
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
