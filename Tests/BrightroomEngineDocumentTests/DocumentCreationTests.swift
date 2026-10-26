import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UIKit

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Creating images and documents: an image first, then a document over it.
struct DocumentCreationTests {

  typealias Fixtures = DocumentTestFixtures

  // MARK: - SourceImage

  @Test func `Encoded data knows its oriented size at creation`() throws {
    let image = try SourceImage(data: Fixtures.makeRotatedJPEG())
    #expect(image.pixelSize == Fixtures.rotatedJPEGSize)
    #expect(image.makeCIImage().extent == CGRect(origin: .zero, size: Fixtures.rotatedJPEGSize))
  }

  @Test func `A file reads the same as its data`() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("jpg")
    try Fixtures.makeRotatedJPEG().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try SourceImage(contentsOf: url)
    #expect(image.pixelSize == Fixtures.rotatedJPEGSize)
    #expect(image.makeCIImage().extent.size == Fixtures.rotatedJPEGSize)
  }

  @Test func `A UIImage keeps its orientation`() throws {
    let cgImage = try Fixtures.makeCGImage()
    let image = SourceImage(image: UIImage(cgImage: cgImage, scale: 1, orientation: .right))
    #expect(image.pixelSize == CGSize(width: 20, height: 40))
    #expect(image.makeCIImage().extent == CGRect(x: 0, y: 0, width: 20, height: 40))

    let upright = SourceImage(image: UIImage(cgImage: cgImage))
    #expect(upright.pixelSize == CGSize(width: 40, height: 20))
  }

  @Test func `A CGImage takes an explicit orientation`() throws {
    let cgImage = try Fixtures.makeCGImage()
    #expect(SourceImage(cgImage: cgImage).pixelSize == CGSize(width: 40, height: 20))
    #expect(SourceImage(cgImage: cgImage, orientation: .left).pixelSize == CGSize(width: 20, height: 40))
    #expect(SourceImage(cgImage: cgImage, orientation: .downMirrored).pixelSize == CGSize(width: 40, height: 20))
  }

  @Test func `A remote URL is not a file`() {
    #expect(throws: SourceImageError.self) {
      try SourceImage(contentsOf: URL(string: "https://example.com/a.jpg")!)
    }
    #expect(throws: SourceImageError.self) {
      try SourceImage(rawContentsOf: URL(string: "https://example.com/a.dng")!)
    }
  }

  @Test func `Unreadable data and missing files throw`() {
    #expect(throws: SourceImageError.self) {
      try SourceImage(data: Data("not an image".utf8))
    }
    #expect(throws: SourceImageError.self) {
      try SourceImage(contentsOf: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg"))
    }
    #expect(throws: SourceImageError.self) {
      try SourceImage(rawData: Data("not a raw file".utf8))
    }
  }

  @Test func `A downsampled image fits the size and starts at zero`() throws {
    let image = try SourceImage(data: Fixtures.makeRotatedJPEG())
    let small = image.makeCIImage(maxPixelSize: 10)
    #expect(max(small.extent.width, small.extent.height) <= 10)
    #expect(small.extent.origin == .zero)
    #expect(small.extent.height > small.extent.width, "Portrait stays portrait.")

    // Never upsampled.
    #expect(image.makeCIImage(maxPixelSize: 1000).extent.size == Fixtures.rotatedJPEGSize)

    let bitmap = SourceImage(cgImage: try Fixtures.makeCGImage(), orientation: .left)
    let smallBitmap = bitmap.makeCIImage(maxPixelSize: 10)
    #expect(smallBitmap.extent.origin == .zero)
    #expect(abs(smallBitmap.extent.height - 10) < 0.5)
    #expect(abs(smallBitmap.extent.width - 5) < 0.5)
  }

  // MARK: - ImageEditorDocument

  @Test func `A new image editor document crops the whole image`() throws {
    let image = try Fixtures.makeImage()
    let document = EditingDocument(source: image)
    #expect(document.source == image)
    #expect(document.feature == ImageEditorFeature(imageSize: image.pixelSize))
    #expect(document.feature.crop.rect == CGRect(origin: .zero, size: image.pixelSize))
    #expect(document.feature.effects == .init())
    #expect(document.feature.localBlur == nil)
    #expect(!document.canUndo)
  }

  @Test func `The full-image initial crop keeps the whole image`() async throws {
    let image = try Fixtures.makeImage()
    let document = await EditingDocument(source: image, initialCrop: .fullImage)
    #expect(document == EditingDocument(source: image, history: document.history))
    #expect(document.feature.crop.rect == CGRect(origin: .zero, size: image.pixelSize))
  }

  @Test func `An initial crop decides the committed initial crop`() async throws {
    let image = try Fixtures.makeImage()
    let document = await EditingDocument(
      source: image,
      initialCrop: InitialCrop { input in
        // The policy sees the image in the document's domain.
        #expect(input.image.extent == CGRect(origin: .zero, size: image.pixelSize))
        #expect(input.imageSize == image.pixelSize)
        #expect(input.crop == ImageEditorFeature(imageSize: image.pixelSize).crop)
        return input.crop.fitted(to: .square, imageSize: input.imageSize)
      }
    )
    let cropRect = document.feature.crop.rect
    #expect(cropRect.width == cropRect.height)
    #expect(!document.canUndo, "The initial crop is the starting point, not an undo step.")
    #expect(!document.hasUncommittedChanges)
  }

  @Test func `The document pixel-aligns the crop an initial crop returns`() async throws {
    let image = try Fixtures.makeImage()
    // At least as wide as the 20 x 40 image, so ImageEditor's minimum crop
    // size (the image's shorter side here) leaves it as aligned.
    let requested = CropFeature(
      rect: CGRect(x: -3.5, y: 2.25, width: 25, height: 30),
      quarterTurn: .counterclockwise90
    )
    let document = await EditingDocument(
      source: image,
      initialCrop: InitialCrop { _ in requested }
    )
    // x -3.5...21.5 clipped to 20 → 0...20, y 2.25...32.25 → 3...32.
    #expect(document.feature.crop == requested.pixelAligned(imageSize: image.pixelSize))
    #expect(document.feature.crop.rect == CGRect(x: 0, y: 3, width: 20, height: 29))
    #expect(document.feature.crop.quarterTurn == .counterclockwise90)
  }

  @Test func `An aspect-ratio initial crop fits the image`() async throws {
    let image = try Fixtures.makeImage()
    let document = await EditingDocument(source: image, initialCrop: .aspectRatio(.square))
    let full = ImageEditorFeature(imageSize: image.pixelSize).crop
    #expect(document.feature.crop == full.fitted(to: .square, imageSize: image.pixelSize))
    // The 20 x 40 image fits a centered 20 x 20 square.
    #expect(document.feature.crop.rect == CGRect(x: 0, y: 10, width: 20, height: 20))
    #expect(!document.canUndo)
  }

  @Test func `A document can carry a restored history and limit`() throws {
    let image = try Fixtures.makeImage()
    let document = EditingDocument(
      source: image,
      history: .init(undoStack: [Fixtures.exposure(3)], redoStack: [], limit: 5)
    )
    #expect(document.history.limit == 5)
    #expect(document.canUndo)
  }

  @Test func `An edit moves to another image only explicitly`() throws {
    let data = try Fixtures.makeRotatedJPEG()
    var original = EditingDocument(source: try SourceImage(data: data))
    original.feature.effects.exposure = ExposureFeature(ev: 1)
    original.commit()

    let other = try SourceImage(data: data)
    let moved = EditingDocument(source: other, feature: original.feature)
    #expect(moved.source == other)
    #expect(moved.feature == original.feature)
    #expect(!moved.canUndo, "History stays with the original document.")
  }

  // MARK: - Rendering

  @Test func `Rendering a document renders its feature over its source image`() async throws {
    var document = EditingDocument(source: try Fixtures.makeImage())
    document.feature.crop = CropFeature(rect: CGRect(x: 0, y: 0, width: 20, height: 10))
    let rendered = try await document.render()
    let cgImage = try rendered.cgImage
    #expect(cgImage.width == 20)
    #expect(cgImage.height == 10)
  }

  @Test func `A grayscale image renders to memory and to a file`() async throws {
    var document = EditingDocument(source: try SourceImage(data: Fixtures.makeGrayscaleJPEG()))
    document.feature.effects.exposure = ExposureFeature(ev: 0.5)

    let memory = try await document.render()
    #expect(try memory.cgImage.colorSpace?.model == .rgb)
    #expect(try memory.cgImage.width == 40)

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try await document.render(
      options: .init(output: .file(url: url, fileType: .jpeg(quality: 0.9)))
    )
    #expect(try file.cgImage.width == 40)
    #expect(try file.cgImage.height == 20)
  }

  @MainActor
  @Test func `A preview source loader prepares the document's source image`() async throws {
    let image = try Fixtures.makeImage()
    let loader = PreviewSourceLoader(source: image)
    await loader.load()
    let previewSource = try #require(loader.previewSource)
    #expect(previewSource.source == image)
    #expect(previewSource.image.extent.size == image.pixelSize)
  }
}
