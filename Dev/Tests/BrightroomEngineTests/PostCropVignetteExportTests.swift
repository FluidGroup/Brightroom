import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import CoreGraphics
import Testing
import UIKit

/// Public API only: plays a host that exports an `ImageEditorFeature`.
///
/// `ImageEditorFeature.vignette` is evaluated after the final crop, so it is
/// centred on the crop output and its radius is half the output's longer
/// side. The numbers are sRGB levels of a uniform sRGB 128 grey at 1200×800
/// with vignette 1.
struct PostCropVignetteExportTests {

  private static let imageSize = CGSize(width: 1200, height: 800)
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  @Test func `A left-half crop centres the vignette on the crop output`() async throws {
    let output = try await Self.export(
      crop: CropFeature(topLeftRect: CGRect(x: 0, y: 0, width: 600, height: 800), imageSize: Self.imageSize)
    )
    #expect(output.width == 600)
    #expect(output.height == 800)

    // Before the crop the row read [61, 91, 114, 126, 128]: the darkening
    // was centred on the source, at the output's right edge.
    let centreRow = [0, 150, 300, 450, 599].map { output.level(x: $0, y: 400) }
    for (level, expected) in zip(centreRow, [91, 121, 128, 121, 91]) {
      #expect(abs(level - expected) <= 2, "centre row \(centreRow)")
    }

    // Before the crop the corners read [36, 100, 36, 100].
    let corners = [(0, 0), (599, 0), (0, 799), (599, 799)].map { output.level(x: $0.0, y: $0.1) }
    for level in corners {
      #expect(abs(level - 31) <= 2, "corners \(corners)")
    }
  }

  @Test func `A centred half crop darkens its own corners`() async throws {
    let output = try await Self.export(
      crop: CropFeature(topLeftRect: CGRect(x: 300, y: 200, width: 600, height: 400), imageSize: Self.imageSize)
    )

    // Before the crop the corners read 106: the source's vignette barely
    // reached them.
    let corners = [(0, 0), (599, 0), (0, 399), (599, 399)].map { output.level(x: $0.0, y: $0.1) }
    for level in corners {
      #expect(abs(level - 36) <= 2, "corners \(corners)")
    }
    #expect(abs(output.level(x: 300, y: 200) - 128) <= 2)
  }

  enum UnchangedCrop: CaseIterable, Sendable {
    /// The whole source turned a quarter.
    case fullCounterclockwise90
    /// The whole source straightened about its centre, at its full size.
    case fullStraightened

    var crop: CropFeature {
      switch self {
      case .fullCounterclockwise90:
        CropFeature(
          topLeftRect: CGRect(origin: .zero, size: PostCropVignetteExportTests.imageSize),
          imageSize: PostCropVignetteExportTests.imageSize,
          quarterTurn: .counterclockwise90
        )
      case .fullStraightened:
        CropFeature(
          rect: CGRect(origin: .zero, size: PostCropVignetteExportTests.imageSize),
          quarterTurn: .zero,
          straightenRadians: 0.2
        )
      }
    }
  }

  /// A crop that keeps the source's centre and longer side keeps the
  /// vignette's centre and radius, so it looks as it did before the crop.
  @Test(arguments: UnchangedCrop.allCases)
  func `Crops that keep the centre and the size are unchanged`(crop: UnchangedCrop) async throws {
    struct VignetteBeforeCrop: Feature, Equatable {
      var vignette: VignetteFeature
      var crop: CropFeature
      var body: some Feature {
        vignette
        crop
      }
    }

    let after = try await Self.export(crop: crop.crop)
    let before = try await Self.render(
      VignetteBeforeCrop(vignette: VignetteFeature(value: 1), crop: crop.crop)
    )
    #expect(after.width == before.width)
    #expect(after.height == before.height)

    var largest = 0
    var opaque = 0
    for y in 0..<after.height {
      for x in 0..<after.width where after.alpha(x: x, y: y) == 255 && before.alpha(x: x, y: y) == 255 {
        opaque += 1
        largest = max(largest, abs(after.level(x: x, y: y) - before.level(x: x, y: y)))
      }
    }
    #expect(opaque > after.width * after.height / 2)
    #expect(largest <= 2)
  }

  // MARK: - Helpers

  struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// The red level (the image is grey) at a top-left-origin pixel.
    func level(x: Int, y: Int) -> Int {
      Int(bytes[(y * width + x) * 4])
    }

    func alpha(x: Int, y: Int) -> Int {
      Int(bytes[(y * width + x) * 4 + 3])
    }
  }

  private static func export(crop: CropFeature) async throws -> Pixels {
    try await render(ImageEditorFeature(crop: crop, vignette: VignetteFeature(value: 1)))
  }

  private static func render<Content: Feature & Equatable>(_ feature: Content) async throws -> Pixels {
    let document = EditingDocument(source: SourceImage(cgImage: makeGrey()), feature: feature)
    let image = try await document.render(options: .init(outputColorSpace: sRGB)).cgImage
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(
      data: &bytes,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: sRGB,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Pixels(width: image.width, height: image.height, bytes: bytes)
  }

  /// A uniform sRGB 128 grey.
  private static func makeGrey() -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
      UIColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: imageSize))
    }.cgImage!
  }
}
