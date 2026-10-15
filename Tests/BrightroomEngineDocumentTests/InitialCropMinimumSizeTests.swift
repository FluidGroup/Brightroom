import CoreGraphics
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// An initial crop below ImageEditor's minimum crop size (128 pixels on the
/// shorter output side, or the image's shorter side when the image is
/// smaller) grows about its center to that size, keeping its ratio.
struct InitialCropMinimumSizeTests {

  typealias Fixtures = DocumentTestFixtures

  private let imageSize = CGSize(width: 1200, height: 900)

  private func makeImage() throws -> SourceImage {
    SourceImage(cgImage: try Fixtures.makeCGImage(width: 1200, height: 900))
  }

  @Test func `A small crop a custom policy returns grows to the minimum with its own ratio`() async throws {
    let image = try makeImage()
    let small = CropFeature(topLeftRect: CGRect(x: 242, y: 68, width: 105, height: 104), imageSize: imageSize)
    let document = await EditingDocument(source: image, initialCrop: InitialCrop { _ in small })

    let crop = document.feature.crop
    // 105:104 has terms above 32: the shorter side is 128 and the longer
    // the nearest whole pixel (129.2 → 129), about the center (294.5, 120).
    #expect(crop.topLeftRect(imageSize: imageSize) == CGRect(x: 230, y: 56, width: 129, height: 128))
    #expect(crop == crop.pixelAligned(imageSize: imageSize))
    #expect(!document.canUndo)
  }

  @Test func `A crop that reaches the minimum is kept`() async throws {
    let image = try makeImage()
    let requested = CropFeature(topLeftRect: CGRect(x: 100, y: 100, width: 300, height: 128), imageSize: imageSize)
    let document = await EditingDocument(source: image, initialCrop: InitialCrop { _ in requested })
    #expect(document.feature.crop == requested)

    // 75 × (16, 9), centered: 112.5 rounds to 113.
    let fitted = await EditingDocument(source: image, initialCrop: .aspectRatio(AspectRatio(width: 16, height: 9)))
    #expect(fitted.feature.crop.topLeftRect(imageSize: imageSize) == CGRect(x: 0, y: 113, width: 1200, height: 675))
  }

  /// A face framed with `.square` that the inward snap left a pixel off
  /// square grows to exactly 128 × 128, centered on the framing.
  @Test func `A small face framing grows to the minimum with the policy's ratio`() throws {
    let framed = CropFeature.framingFace(
      CGRect(x: 0.2501, y: 0.7003, width: 0.0301, height: 0.0401),
      imageSize: imageSize,
      paddingBias: 0.5,
      aspectRatio: .square
    )
    try #require(framed.rect.width < 128 && framed.rect.height < 128, "\(framed.rect)")

    #expect(InitialCrop.faceDetection(aspectRatio: .square).framingAspectRatio == .square)
    #expect(InitialCrop.faceDetection().framingAspectRatio == nil)
    #expect(InitialCrop.aspectRatio(AspectRatio(width: 4, height: 5)).framingAspectRatio == AspectRatio(width: 4, height: 5))
    #expect(InitialCrop.fullImage.framingAspectRatio == nil)

    let grown = framed.enlargedToEditorMinimum(imageSize: imageSize, aspectRatio: .square)
    #expect(grown.rect.size == CGSize(width: 128, height: 128))
    #expect(abs(grown.rect.midX - framed.rect.midX) <= 0.5)
    #expect(abs(grown.rect.midY - framed.rect.midY) <= 0.5)
    #expect(grown == grown.pixelAligned(imageSize: imageSize))
  }

  @Test func `A small crop with a ratio grows to the smallest exact multiple`() {
    // 16:9 reaches 128 at 15 × (16, 9) = 240 × 135.
    let small = CropFeature(topLeftRect: CGRect(x: 500, y: 400, width: 160, height: 90), imageSize: imageSize)
    let grown = small.enlargedToEditorMinimum(imageSize: imageSize, aspectRatio: AspectRatio(width: 16, height: 9))
    #expect(grown.topLeftRect(imageSize: imageSize) == CGRect(x: 460, y: 378, width: 240, height: 135))

    // The ratio describes the output; a sideways turn exchanges it for the
    // selection.
    let sideways = CropFeature(
      topLeftRect: CGRect(x: 500, y: 400, width: 90, height: 160),
      imageSize: imageSize,
      quarterTurn: .counterclockwise90
    )
    let grownSideways = sideways.enlargedToEditorMinimum(
      imageSize: imageSize,
      aspectRatio: AspectRatio(width: 16, height: 9)
    )
    #expect(grownSideways.rect.size == CGSize(width: 135, height: 240))
    #expect(grownSideways.outputGeometry(in: .zero).outputBounds.size == CGSize(width: 240, height: 135))
    #expect(grownSideways.quarterTurn == .counterclockwise90)
  }

  @Test func `A small crop near the edge grows inside the image`() {
    let small = CropFeature(topLeftRect: CGRect(x: 1180, y: 0, width: 20, height: 20), imageSize: imageSize)
    let grown = small.enlargedToEditorMinimum(imageSize: imageSize, aspectRatio: nil)
    #expect(grown.topLeftRect(imageSize: imageSize) == CGRect(x: 1072, y: 0, width: 128, height: 128))
  }

  /// An aspect-ratio crop as large as a small or thin image holds is under
  /// the minimum but cannot grow; the document keeps the largest crop of
  /// exactly the ratio the image holds rather than shrinking it further.
  @Test(arguments: [
    (CGSize(width: 100, height: 100), AspectRatio(width: 16, height: 9)),
    (CGSize(width: 3000, height: 200), AspectRatio(width: 9, height: 16)),
    (CGSize(width: 1000, height: 120), AspectRatio(width: 9, height: 16)),
    (CGSize(width: 4000, height: 220), AspectRatio(width: 9, height: 16)),
  ])
  func `An aspect-ratio crop as large as the image holds is not shrunk`(size: CGSize, ratio: AspectRatio) async throws {
    let image = SourceImage(cgImage: try Fixtures.makeCGImage(width: Int(size.width), height: Int(size.height)))
    let document = await EditingDocument(source: image, initialCrop: .aspectRatio(ratio))

    let fitted = CropFeature(
      topLeftRect: CropGeometry.cropRect(toFitAspectRatio: ratio, in: size, straightenRadians: 0),
      imageSize: size,
      aspectRatio: ratio
    )
    #expect(document.feature.crop == fitted)
  }

  // MARK: - Exact ratios

  /// `.aspectRatio(_:)` aligns its crop to exactly the ratio, as a crop
  /// recorded under ImageEditor's locked ratio is, so a `.fixed` editor
  /// opened on it exports that ratio. Snapping each edge on its own gave
  /// 2418 × 3024 for 4:5 of a 4032 × 3024 photo.
  @Test(arguments: [
    (CGSize(width: 4032, height: 3024), AspectRatio(width: 4, height: 5), CGSize(width: 2416, height: 3020)),
    (CGSize(width: 1001, height: 667), AspectRatio(width: 4, height: 5), CGSize(width: 532, height: 665)),
    (CGSize(width: 3024, height: 4032), AspectRatio(width: 16, height: 9), CGSize(width: 3024, height: 1701)),
    (CGSize(width: 4032, height: 3024), AspectRatio(width: 9, height: 16), CGSize(width: 1701, height: 3024)),
    (CGSize(width: 1001, height: 667), AspectRatio.square, CGSize(width: 667, height: 667)),
  ])
  func `An aspect-ratio crop has exactly the ratio`(size: CGSize, ratio: AspectRatio, expected: CGSize) async throws {
    let image = SourceImage(cgImage: try Fixtures.makeCGImage(width: Int(size.width), height: Int(size.height)))
    let document = await EditingDocument(source: image, initialCrop: .aspectRatio(ratio))

    let crop = document.feature.crop
    let rect = crop.topLeftRect(imageSize: size)
    #expect(rect.size == expected, "\(rect)")
    // Centered within half a pixel, at whole pixels.
    #expect(abs(rect.midX - size.width / 2) <= 0.5 && abs(rect.midY - size.height / 2) <= 0.5, "\(rect)")
    #expect(crop == crop.pixelAligned(imageSize: size))
  }

  /// Face detection that finds no face falls back to the ratio, exactly too.
  @Test func `Face detection without a face falls back to exactly the ratio`() async throws {
    let size = CGSize(width: 1001, height: 667)
    let image = SourceImage(cgImage: try Fixtures.makeCGImage(width: Int(size.width), height: Int(size.height)))
    let document = await EditingDocument(
      source: image,
      initialCrop: .faceDetection(aspectRatio: AspectRatio(width: 4, height: 5))
    )
    #expect(document.feature.crop.topLeftRect(imageSize: size).size == CGSize(width: 532, height: 665))
  }

  /// A face framed with a ratio is aligned to exactly the ratio, about the
  /// framing's center; without a ratio, as `framingFace` aligns it.
  @Test func `A face framing with a ratio aligns to exactly the ratio`() throws {
    let size = CGSize(width: 4000, height: 3000)
    let face = CGRect(x: 0.4123, y: 0.5531, width: 0.0731, height: 0.0977)
    for ratio in [AspectRatio.square, AspectRatio(width: 4, height: 5), AspectRatio(width: 16, height: 9)] {
      let selection = CropFeature.framingFaceSelection(face, imageSize: size, paddingBias: 1.3, aspectRatio: ratio)
      let aligned = CropFeature(rect: selection).pixelAligned(imageSize: size, aspectRatio: ratio)
      let terms = try #require(PixelAlignedCrop.exactTerms(of: ratio))
      let multiple = aligned.rect.width / CGFloat(terms.width)
      #expect(multiple == multiple.rounded() && aligned.rect.height == multiple * CGFloat(terms.height), "\(aligned.rect)")
      #expect(abs(aligned.rect.midX - selection.midX) <= 0.5 && abs(aligned.rect.midY - selection.midY) <= 0.5, "\(aligned.rect)")
      #expect(selection.width - aligned.rect.width < CGFloat(terms.width) + 1, "\(aligned.rect) in \(selection)")
    }
    let unlocked = CropFeature.framingFaceSelection(face, imageSize: size, paddingBias: 1.3, aspectRatio: nil)
    #expect(
      CropFeature(rect: unlocked).pixelAligned(imageSize: size, aspectRatio: nil)
        == CropFeature.framingFace(face, imageSize: size, paddingBias: 1.3, aspectRatio: nil)
    )
  }

  /// On an image smaller than 128 pixels on a side, the minimum is the
  /// image's shorter side.
  @Test func `On a small image the minimum is the image's shorter side`() async throws {
    let image = try Fixtures.makeImage()
    try #require(image.pixelSize == CGSize(width: 20, height: 40))
    let document = await EditingDocument(
      source: image,
      initialCrop: InitialCrop { _ in CropFeature(rect: CGRect(x: 5, y: 10, width: 8, height: 8)) }
    )
    // A square of the image's width, about (9, 14), moved inside.
    #expect(document.feature.crop.rect == CGRect(x: 0, y: 4, width: 20, height: 20))
  }
}
