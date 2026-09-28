import CoreGraphics
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

/// `EditingStack` prepares one image for the editors; it holds no edit and no
/// history. Rendering belongs to the document.
struct EditingStackTests {

  private func makeImage(size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor.orange.setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }
  }

  @Test func `Loading publishes a state without an edit`() async throws {
    let size = CGSize(width: 40, height: 20)
    let image = SourceImage(image: makeImage(size: size))
    let stack = EditingStack(source: image)
    #expect(stack.isLoading)

    stack.start()
    let deadline = ContinuousClock.now + .seconds(10)
    while stack.loadedState == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }

    let loaded = try #require(stack.loadedState)
    #expect(loaded.source == image)
    #expect(loaded.imageSize == size)
    #expect(loaded.thumbnailImage.extent.isEmpty == false)
    #expect(loaded.editingSourceImage.extent.size == size)
    #expect(loaded.editingSourceCGImage.width == Int(size.width))
  }

  @Test func `A document renders over its stack's image`() async throws {
    let size = CGSize(width: 40, height: 20)
    let cgImage = try #require(makeImage(size: size).cgImage)
    let stack = EditingStack.test(cgImage: cgImage)

    let crop = CropFeature.test(imageSize: size, topLeftRect: CGRect(x: 4, y: 2, width: 16, height: 12))
    let rendered = try await EditingDocument(source: stack.source, feature: crop).render()

    let image = try rendered.cgImage
    #expect(image.width == 16)
    #expect(image.height == 12)
  }
}
