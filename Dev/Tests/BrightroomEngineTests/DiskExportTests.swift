import ImageIO
import XCTest
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Exercises `render(options:)` with `Output.file` — the direct-to-disk export
/// that renders through `CIContext.write{JPEG,HEIF,PNG}Representation` instead of
/// materializing a full-resolution `CGImage`. Core Image renders in tiles and
/// streams into the encoder, so this path is the memory-bounded export for very
/// large images.
///
/// The OOM/peak-memory behavior itself cannot be asserted in a unit test (it is a
/// device memory-watermark concern); these tests pin CORRECTNESS of the new path:
/// the file is written, it is full resolution, the local adjustment is applied,
/// and `Resolution.resize` caps the output — all without a `CGImage`/`CGImageDestination`.
final class DiskExportTests: XCTestCase {

  private static let side = 2048

  private var scratchURLs: [URL] = []

  override func tearDownWithError() throws {
    for url in scratchURLs {
      try? FileManager.default.removeItem(at: url)
    }
    scratchURLs.removeAll()
  }

  func testDiskExportWritesFullResolutionMaskedImage() async throws {
    let url = makeScratchURL(ext: "jpg")
    let side = Self.side
    let size = CGSize(width: side, height: side)

    _ = try await makeMaskedRenderer(size: size).render(
      options: .init(
        workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: .jpeg(quality: 0.9))
      )
    )

    // The file exists and is non-empty.
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = try XCTUnwrap(attributes[.size] as? Int)
    XCTAssertGreaterThan(fileSize, 0, "Export must write a non-empty file")

    // It decodes back at full source resolution.
    let exported = try loadCGImage(url)
    XCTAssertEqual(exported.width, side)
    XCTAssertEqual(exported.height, side)

    // The centered exposure lift is present: center is brighter than a corner
    // far outside the mask. (JPEG is lossy, so compare regions, not exact values.)
    let center = Self.rgba(in: exported, x: side / 2, y: side / 2)
    let corner = Self.rgba(in: exported, x: 4, y: 4)
    XCTAssertGreaterThan(
      Int(center.red),
      Int(corner.red) + 20,
      "Masked center should be clearly brighter than the unmasked corner"
    )
  }

  func testDiskExportPNGIsFullResolutionAndMasked() async throws {
    let url = makeScratchURL(ext: "png")
    let side = Self.side
    let size = CGSize(width: side, height: side)

    _ = try await makeMaskedRenderer(size: size).render(
      options: .init(
        workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: .png)
      )
    )

    let exported = try loadCGImage(url)
    XCTAssertEqual(exported.width, side)
    XCTAssertEqual(exported.height, side)

    let center = Self.rgba(in: exported, x: side / 2, y: side / 2)
    let corner = Self.rgba(in: exported, x: 4, y: 4)
    XCTAssertGreaterThan(Int(center.red), Int(corner.red) + 20)
  }

  func testDiskExportResizeCapsLongestSide() async throws {
    let url = makeScratchURL(ext: "jpg")
    let side = Self.side
    let size = CGSize(width: side, height: side)
    let cap: CGFloat = 512

    _ = try await makeMaskedRenderer(size: size).render(
      options: .init(
        resolution: .resize(maxPixelSize: cap),
        workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: .jpeg(quality: 0.9))
      )
    )

    let exported = try loadCGImage(url)
    XCTAssertEqual(CGFloat(max(exported.width, exported.height)), cap, accuracy: 1)
    // Still masked after the CI-side downscale.
    let center = Self.rgba(in: exported, x: exported.width / 2, y: exported.height / 2)
    let corner = Self.rgba(in: exported, x: 2, y: 2)
    XCTAssertGreaterThan(Int(center.red), Int(corner.red) + 20)
  }

  /// Guards the streaming writer's y-mapping: a top-white / bottom-black source
  /// must come back top-white through `Output.file` (no vertical flip in the
  /// strip loop).
  func testDiskExportPreservesVerticalOrientation() async throws {
    let url = makeScratchURL(ext: "png")
    let side = 256
    let size = CGSize(width: side, height: side)
    let source = Self.makeTopWhiteBottomBlack(side: side)

    let renderer = BrightRoomImageRenderer(source: ImageSource(cgImage: source), orientation: .up)
    renderer.edit = .make(crop: CropFeature.test(imageSize: size), orientedImageSize: size)
    _ = try await renderer.render(
      options: .init(
        workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: .png)
      )
    )

    let exported = try loadCGImage(url)
    let topMid = Self.rgba(in: exported, x: side / 2, y: side / 8)
    let bottomMid = Self.rgba(in: exported, x: side / 2, y: side * 7 / 8)
    XCTAssertGreaterThan(Int(topMid.red), 200, "top should be white — no vertical flip")
    XCTAssertLessThan(Int(bottomMid.red), 64, "bottom should be black")
  }

  /// Guards the writer's pixel format: a distinct R>G>B source must keep its
  /// channel order (catches an RGBA/BGRA byte-order mistake). PNG = lossless, so
  /// only a small color-management tolerance is needed.
  func testDiskExportPreservesChannelOrder() async throws {
    let url = makeScratchURL(ext: "png")
    let side = 128
    let size = CGSize(width: side, height: side)
    let source = Self.makeSolidColorImage(side: side, red: 200, green: 100, blue: 30)

    let renderer = BrightRoomImageRenderer(source: ImageSource(cgImage: source), orientation: .up)
    renderer.edit = .make(crop: CropFeature.test(imageSize: size), orientedImageSize: size)
    _ = try await renderer.render(
      options: .init(
        workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: .png)
      )
    )

    let px = Self.rgba(in: try loadCGImage(url), x: side / 2, y: side / 2)
    XCTAssertEqual(Double(px.red), 200, accuracy: 20)
    XCTAssertEqual(Double(px.green), 100, accuracy: 20)
    XCTAssertEqual(Double(px.blue), 30, accuracy: 20)
    XCTAssertGreaterThan(Int(px.red), Int(px.green), "R>G channel order preserved")
    XCTAssertGreaterThan(Int(px.green), Int(px.blue), "G>B channel order preserved")
  }

  // MARK: - Fixtures

  /// A renderer over a solid mid-grey source with a strong, fully-opaque,
  /// hard-edged exposure lift painted across the central quarter (mirrors
  /// `LargeMaskedExportTests`).
  private func makeMaskedRenderer(size: CGSize) -> BrightRoomImageRenderer {
    let side = Int(size.width)
    let source = Self.makeSolidImage(width: side, height: Int(size.height), white: 0.25)
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let diameter = Double(size.width) / 4

    let layer = LocalAdjustmentFeature(
      maskTree: MaskTree(
        root: .brush(
          BrushMask(
            strokes: [
              BrushMaskStroke(
                stamps: [center],
                brush: BrushMaskBrush(diameter: diameter, hardness: 1, opacity: 1)
              )
            ]
          )
        )
      ),
      effectPipeline: EffectPipeline(effects: [ExposureFeature(value: 2)])
    )

    let renderer = BrightRoomImageRenderer(
      source: ImageSource(cgImage: source),
      orientation: .up
    )
    renderer.edit = .make(
      crop: CropFeature.test(imageSize: size),
      orientedImageSize: size,
      localAdjustments: [layer]
    )
    return renderer
  }

  private func makeScratchURL(ext: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("brightroom-disk-export-\(UUID().uuidString)")
      .appendingPathExtension(ext)
    scratchURLs.append(url)
    return url
  }

  private func loadCGImage(_ url: URL) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "exported file should be a decodable image")
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  private static func makeSolidImage(width: Int, height: Int, white: CGFloat) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: white, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
  }

  /// Top half white, bottom half black (UIKit y-down: y=0 is the top).
  private static func makeTopWhiteBottomBlack(side: Int) -> CGImage {
    let size = CGSize(width: side, height: side)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor.black.setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
      UIColor.white.setFill()
      UIRectFill(CGRect(x: 0, y: 0, width: side, height: side / 2))
    }.cgImage!
  }

  private static func makeSolidColorImage(side: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let size = CGSize(width: side, height: side)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
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

    let clampedX = min(max(x, 0), width - 1)
    let clampedY = min(max(y, 0), height - 1)
    let offset = (clampedY * width + clampedX) * 4
    return RGBA(
      red: pixels[offset],
      green: pixels[offset + 1],
      blue: pixels[offset + 2],
      alpha: pixels[offset + 3]
    )
  }

  private struct RGBA: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
  }
}
