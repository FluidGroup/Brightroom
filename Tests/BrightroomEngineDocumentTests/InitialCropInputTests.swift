import CoreGraphics
import CoreImage
import Testing

// Public API only: this file plays the role of a host app that unit-tests
// its own initial-crop policy. It must not need `@testable` access to the
// library (the test-only image fixture is the test target's own).
import BrightroomEngine
import BrightroomParametric
import BrightroomUI

/// A host's initial crop: the largest centered square, or the crop it is
/// given when the preview has nothing to look at.
private enum CenteredSquareCrop {

  static let decide: @Sendable (InitialCrop.Input) async -> CropFeature = { input in
    guard input.image.extent.isEmpty == false else {
      return input.crop
    }
    let side = min(input.imageSize.width, input.imageSize.height)
    return CropFeature(
      rect: CGRect(
        x: (input.imageSize.width - side) / 2,
        y: (input.imageSize.height - side) / 2,
        width: side,
        height: side
      )
    )
  }

  static let initialCrop = InitialCrop(decide)
}

/// A host can build `InitialCrop.Input` to unit-test its `decide` closure.
struct InitialCropInputTests {

  private let imageSize = CGSize(width: 1200, height: 900)

  /// The input the document passes: an image covering `imageSize` at a zero
  /// origin and a crop of the whole image.
  private func makeInput(image: CIImage? = nil) -> InitialCrop.Input {
    InitialCrop.Input(
      image: image ?? CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize)),
      imageSize: imageSize,
      crop: CropFeature(rect: CGRect(origin: .zero, size: imageSize))
    )
  }

  @Test func `An input keeps the values it is created with`() {
    let input = makeInput()
    #expect(input.image.extent == CGRect(origin: .zero, size: imageSize))
    #expect(input.imageSize == imageSize)
    #expect(input.crop == CropFeature(rect: CGRect(origin: .zero, size: imageSize)))
  }

  @Test func `A decide closure runs on an input the host builds`() async {
    let decided = await CenteredSquareCrop.decide(makeInput())
    #expect(decided == CropFeature(rect: CGRect(x: 150, y: 0, width: 900, height: 900)))

    let fallback = await CenteredSquareCrop.decide(makeInput(image: CIImage.empty()))
    #expect(fallback == CropFeature(rect: CGRect(origin: .zero, size: imageSize)))
  }

  /// The closure's result on the host-built input is the crop a document
  /// starts from, since it is already whole-pixel and above the editor's
  /// minimum size.
  @Test func `A document starts from the crop the closure returns for that input`() async throws {
    let source = SourceImage(cgImage: try DocumentTestFixtures.makeCGImage(width: 1200, height: 900))
    let document = await ImageEditorDocument(source: source, initialCrop: CenteredSquareCrop.initialCrop)

    let decided = await CenteredSquareCrop.decide(makeInput())
    #expect(document.feature.crop == decided)
  }
}
