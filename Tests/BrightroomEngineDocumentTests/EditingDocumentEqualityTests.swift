import CoreGraphics
import Foundation
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Image identity, document equality, and what render caches key on.
struct EditingDocumentEqualityTests {

  typealias Fixtures = DocumentTestFixtures

  @Test func `Source images compare by load, not by content`() throws {
    let data = try Fixtures.makeRotatedJPEG()
    let image = try SourceImage(data: data)
    let copy = image
    let reloaded = try SourceImage(data: data)

    #expect(image == copy)
    #expect(image.hashValue == copy.hashValue)
    #expect(image != reloaded)
    #expect(Set([image, copy, reloaded]).count == 2)
  }

  @Test func `Source image equality does not read pixels`() throws {
    // Two bitmaps with the same pixels are two images; equality is storage
    // identity, so it costs the same for any image size.
    let cgImage = try Fixtures.makeCGImage(width: 4000, height: 3000)
    let first = SourceImage(cgImage: cgImage)
    let second = SourceImage(cgImage: cgImage)
    #expect(first != second)
    #expect(first == first)
  }

  @Test func `Documents differing only in history are not equal`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    let uncommitted = document
    document.commit()

    #expect(document.feature == uncommitted.feature)
    #expect(document != uncommitted)

    var dropped = document
    dropped.history.removeAll()
    #expect(dropped.feature == document.feature)
    #expect(dropped != document)
  }

  @Test func `Documents of different images are not equal`() throws {
    let data = try Fixtures.makeRotatedJPEG()
    let first = EditingDocument(image: try SourceImage(data: data))
    let second = EditingDocument(image: try SourceImage(data: data))
    #expect(first.feature == second.feature)
    #expect(first != second)
  }

  @Test func `Render keys come from the feature, so a commit keeps them`() throws {
    // A preview cache keyed on the feature (or on image and feature) is not
    // invalidated by a commit, which changes the document but no pixel.
    struct RenderKey: Equatable {
      let image: SourceImage
      let feature: ImageEditorFeature
    }
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    let before = RenderKey(image: document.image, feature: document.feature)
    let documentBefore = document

    document.commit()
    #expect(RenderKey(image: document.image, feature: document.feature) == before)
    #expect(document != documentBefore)

    document.undo()
    #expect(RenderKey(image: document.image, feature: document.feature) != before)
  }

  @Test func `Features built from the same values are equal`() throws {
    var built = ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)
    built.effects.exposure = ExposureFeature(ev: 1)

    let rebuilt = ImageEditorFeature(
      effects: .init(exposure: ExposureFeature(ev: 1)),
      crop: CropFeature(
        topLeftRect: CGRect(origin: .zero, size: Fixtures.rotatedJPEGSize),
        imageSize: Fixtures.rotatedJPEGSize
      )
    )
    #expect(built == rebuilt)
  }
}
