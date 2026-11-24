import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// A filter swatch: one preset over the centre square of a preview source's
/// thumbnail, at the size a filter strip shows it.
///
/// The thumbnails are 160 × 120 and the same in every row, so the centre
/// square is columns 20 through 139.
struct FilterSwatchTests {

  /// A colour that 8-bit Display P3 keeps exactly.
  private static let color: [UInt8] = [64, 128, 192]

  /// A blur with an absolute radius, so the render scale shows in the
  /// pixels, and an exposure, which goes through the adjustment
  /// implementations.
  private static let soften = FilterFeature(
    name: "Soften",
    id: "soften",
    effects: [
      AnyImageEffect(GaussianBlurFeature(radius: .absolute(6))),
      AnyImageEffect(ExposureFeature(ev: 0.5)),
    ]
  )

  private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

  @Test func `A swatch is the point size times the display scale, at most the thumbnail's shorter side`() async throws {
    let previewSource = try Self.previewSource(thumbnail: Self.thumbnail { _ in Self.color })

    let swatch = try #require(await FilterSwatch.render(nil, over: previewSource, pointSize: 30, displayScale: 2))
    #expect(swatch.width == 60)
    #expect(swatch.height == 60)

    let capped = try #require(await FilterSwatch.render(nil, over: previewSource, pointSize: 60, displayScale: 3))
    #expect(capped.width == 120)
    #expect(capped.height == 120)
  }

  @Test func `A nil preset gives the thumbnail's centre square`() async throws {
    // Black 20-pixel bands at the sides, outside the centre square.
    let thumbnail = try Self.thumbnail { column in
      (20..<140).contains(column) ? Self.color : [0, 0, 0]
    }
    let previewSource = try Self.previewSource(thumbnail: thumbnail)

    let swatch = try #require(await FilterSwatch.render(nil, over: previewSource, pointSize: 120, displayScale: 1))
    let pixels = try Self.rgba(swatch)
    let expected = Self.color + [255]
    let worst = pixels.indices.map { abs(Int(pixels[$0]) - Int(expected[$0 % 4])) }.max() ?? 0

    #expect(pixels.count == 120 * 120 * 4)
    #expect(worst <= 1, "Every pixel should be RGBA \(expected); one channel is off by \(worst)")
  }

  @Test func `Absolute radii are pixels of the source image and scale down to the swatch`() async throws {
    let thumbnail = try Self.edgeThumbnail()
    // A 60-pixel swatch evaluates the thumbnail at half size: an 80 × 60
    // chain entry, whose diagonal (100) is a quarter of a 320 × 240
    // source's (400).
    let previewSource = try Self.previewSource(thumbnail: thumbnail, pixelSize: CGSize(width: 320, height: 240))
    let swatch = try #require(await FilterSwatch.render(Self.soften, over: previewSource, pointSize: 60, displayScale: 1))
    let recipe = try Self.recipe(thumbnail: thumbnail, preset: Self.soften, pixels: 60, renderScale: 0.25)
    let differenceFromRecipe = try Self.difference(swatch, recipe)
    #expect(differenceFromRecipe <= 1)

    // Over an 80 × 60 source, the chain entry is at full resolution.
    let fullResolution = try Self.previewSource(thumbnail: thumbnail, pixelSize: CGSize(width: 80, height: 60))
    let unscaled = try #require(
      await FilterSwatch.render(Self.soften, over: fullResolution, pointSize: 60, displayScale: 1)
    )
    let unscaledRecipe = try Self.recipe(thumbnail: thumbnail, preset: Self.soften, pixels: 60, renderScale: 1)
    let differenceFromUnscaledRecipe = try Self.difference(unscaled, unscaledRecipe)
    #expect(differenceFromUnscaledRecipe <= 1)
    let differenceFromUnscaled = try Self.difference(swatch, unscaled)
    #expect(differenceFromUnscaled > 16)
  }

  @Test func `The preset's adjustments use the rendering passed`() async throws {
    let thumbnail = try Self.edgeThumbnail()
    let previewSource = try Self.previewSource(thumbnail: thumbnail, pixelSize: CGSize(width: 320, height: 240))

    let swatch = try #require(
      await FilterSwatch.render(
        Self.soften,
        over: previewSource,
        pointSize: 60,
        displayScale: 1,
        adjustmentRendering: Self.exposureIgnored
      )
    )
    let recipe = try Self.recipe(
      thumbnail: thumbnail,
      preset: Self.soften,
      pixels: 60,
      renderScale: 0.25,
      adjustmentRendering: Self.exposureIgnored
    )
    let differenceFromRecipe = try Self.difference(swatch, recipe)
    #expect(differenceFromRecipe <= 1)

    let standard = try #require(await FilterSwatch.render(Self.soften, over: previewSource, pointSize: 60, displayScale: 1))
    let differenceFromStandard = try Self.difference(swatch, standard)
    #expect(differenceFromStandard > 16)
  }

  // MARK: - Fixtures

  /// A preview source whose thumbnail is `thumbnail`, of a source image of
  /// `pixelSize` (the thumbnail's own size by default).
  private static func previewSource(thumbnail: CIImage, pixelSize: CGSize? = nil) throws -> PreviewSource {
    let size = pixelSize ?? thumbnail.extent.size
    let source = SourceImage(
      cgImage: try DocumentTestFixtures.makeCGImage(width: Int(size.width), height: Int(size.height))
    )
    return PreviewSource(source: source, thumbnail: thumbnail, image: thumbnail)
  }

  /// A rendering whose exposure leaves the image as it is.
  private static let exposureIgnored: AdjustmentRendering = {
    var setup = AdjustmentRendering.Setup()
    setup.replace(
      ExposureFeature.self,
      with: .init(identity: .init(implementation: "test.exposure-ignored", version: "1", configuration: "")) { _, image, _ in
        image
      }
    )
    return setup.makeRendering()
  }()

  /// A 160 × 120 Display P3 thumbnail whose columns are `color(column)`.
  private static func thumbnail(color: (Int) -> [UInt8]) throws -> CIImage {
    let width = 160
    let height = 120
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for row in 0..<height {
      for column in 0..<width {
        let offset = (row * width + column) * 4
        bytes.replaceSubrange(offset..<offset + 3, with: color(column))
      }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: displayP3,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
    return CIImage(cgImage: image)
  }

  /// Dark gray on the left half and light gray on the right, so a blur's
  /// radius shows at the edge between them.
  private static func edgeThumbnail() throws -> CIImage {
    try thumbnail { column in
      column < 80 ? [40, 40, 40] : [200, 200, 200]
    }
  }

  /// The swatch recipe written out: the thumbnail's centre square scaled to
  /// `pixels`, the preset evaluated with the whole thumbnail at that scale as
  /// its chain entry, and 8-bit Display P3 read back through a context with
  /// the canvas's working space.
  private static func recipe(
    thumbnail: CIImage,
    preset: FilterFeature,
    pixels: CGFloat,
    renderScale: Double,
    adjustmentRendering: AdjustmentRendering = .standard
  ) throws -> CGImage {
    let extent = thumbnail.extent
    let side = min(extent.width, extent.height)
    let scale = pixels / side
    let square = thumbnail.cropped(
      to: CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
    )
    let input = square
      .transformed(by: CGAffineTransform(translationX: -square.extent.minX, y: -square.extent.minY))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let output = try preset.apply(
      to: input,
      context: FeatureEvaluationContext(
        chainEntryExtent: CGRect(x: 0, y: 0, width: extent.width * scale, height: extent.height * scale),
        renderScale: renderScale,
        adjustmentRendering: adjustmentRendering
      )
    )

    let options: [CIContextOption: Any] = [
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
      .cacheIntermediates: false,
    ]
    let context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) }
      ?? CIContext(options: options)
    return try #require(
      context.createCGImage(
        output,
        from: CGRect(x: 0, y: 0, width: pixels, height: pixels),
        format: .RGBA8,
        colorSpace: EditingCanvasImageProcessing.drawableColorSpace
      )
    )
  }

  /// The image's pixels as 8-bit RGBA in Display P3, row by row.
  private static func rgba(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try #require(
        CGContext(
          data: buffer.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: displayP3,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  /// The largest difference of one channel between two images of one size.
  private static func difference(_ first: CGImage, _ second: CGImage) throws -> Int {
    try #require(first.width == second.width && first.height == second.height)
    let firstPixels = try rgba(first)
    let secondPixels = try rgba(second)
    return zip(firstPixels, secondPixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
  }
}
