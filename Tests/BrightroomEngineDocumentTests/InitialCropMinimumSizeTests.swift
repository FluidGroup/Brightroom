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

    let fitted = await EditingDocument(source: image, initialCrop: .aspectRatio(AspectRatio(width: 16, height: 9)))
    #expect(
      fitted.feature.crop
        == ImageEditorFeature(imageSize: imageSize).crop.fitted(to: AspectRatio(width: 16, height: 9), imageSize: imageSize)
    )
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
