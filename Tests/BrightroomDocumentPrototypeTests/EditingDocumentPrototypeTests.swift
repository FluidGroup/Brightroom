import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Runtime checks of the engine-centric document prototype.
@MainActor
struct EditingDocumentPrototypeTests {

  // MARK: - Fixtures

  /// A 40 x 20 JPEG whose EXIF orientation turns it sideways (`.right`).
  static func makeRotatedJPEG() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil,
        width: 40,
        height: 20,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    context.setFillColor(UIColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let cgImage = try #require(context.makeImage())

    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(
      destination,
      cgImage,
      [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary
    )
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  static func makeImage() throws -> SourceImage {
    try SourceImage(data: makeRotatedJPEG())
  }

  static func exposure(_ value: Double) -> PhotosCropFeature {
    var feature = PhotosCropFeature(imageSize: CGSize(width: 20, height: 40))
    feature.effects.exposure = ExposureFeature(value: value)
    return feature
  }

  // MARK: - SourceImage

  @Test func `A source image knows its oriented size at creation`() throws {
    let image = try Self.makeImage()
    #expect(image.pixelSize == CGSize(width: 20, height: 40))

    let full = image.makeCIImage()
    #expect(full.extent == CGRect(x: 0, y: 0, width: 20, height: 40))

    let small = image.makeCIImage(maxPixelSize: 10)
    #expect(max(small.extent.width, small.extent.height) <= 10)
    #expect(small.extent.origin == .zero)
    // Portrait stays portrait.
    #expect(small.extent.height > small.extent.width)
  }

  @Test func `Source images compare by load`() throws {
    let data = try Self.makeRotatedJPEG()
    let image = try SourceImage(data: data)
    let copy = image
    let reloaded = try SourceImage(data: data)

    #expect(image == copy)
    #expect(image != reloaded)
    #expect(Set([image, copy, reloaded]).count == 2)
  }

  @Test func `A UIImage keeps its orientation`() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    let cgImage = try #require(context.makeImage())
    let image = SourceImage(image: UIImage(cgImage: cgImage, scale: 1, orientation: .left))
    #expect(image.pixelSize == CGSize(width: 20, height: 40))
    #expect(image.makeCIImage().extent.size == CGSize(width: 20, height: 40))
  }

  @Test func `A remote URL is not a file`() {
    #expect(throws: SourceImageError.self) {
      try SourceImage(fileURL: URL(string: "https://example.com/a.jpg")!)
    }
  }

  // MARK: - History

  @Test func `Changes record nothing until committed`() throws {
    var document = EditingDocument(image: try Self.makeImage(), feature: Self.exposure(0))
    #expect(!document.canUndo)

    document.feature = Self.exposure(1)
    #expect(document.hasUncommittedChanges)
    #expect(document.history.undoStack.isEmpty)

    document.commit()
    #expect(!document.hasUncommittedChanges)
    #expect(document.history.undoStack == [Self.exposure(0)])

    // Committing without a change adds nothing.
    document.commit()
    #expect(document.history.undoStack.count == 1)
  }

  @Test func `Undo and redo walk commits`() throws {
    var document = EditingDocument(image: try Self.makeImage(), feature: Self.exposure(0))
    document.feature = Self.exposure(1)
    document.commit()
    document.feature = Self.exposure(2)
    document.commit()

    document.undo()
    #expect(document.feature == Self.exposure(1))
    document.undo()
    #expect(document.feature == Self.exposure(0))
    #expect(!document.canUndo)

    document.redo()
    document.redo()
    #expect(document.feature == Self.exposure(2))
    #expect(!document.canRedo)
  }

  @Test func `Undo commits pending changes so redo brings them back`() throws {
    var document = EditingDocument(image: try Self.makeImage(), feature: Self.exposure(0))
    document.feature = Self.exposure(1)
    #expect(document.canUndo)

    document.undo()
    #expect(document.feature == Self.exposure(0))
    #expect(document.canRedo)

    document.redo()
    #expect(document.feature == Self.exposure(1))
  }

  @Test func `Uncommitted changes block redo until discarded`() throws {
    var document = EditingDocument(image: try Self.makeImage(), feature: Self.exposure(0))
    document.feature = Self.exposure(1)
    document.commit()
    document.undo()

    document.feature = Self.exposure(5)
    #expect(!document.canRedo)
    document.redo()
    #expect(document.feature == Self.exposure(5))

    document.discardUncommittedChanges()
    #expect(document.canRedo)
    document.redo()
    #expect(document.feature == Self.exposure(1))
  }

  @Test func `A new commit clears redo`() throws {
    var document = EditingDocument(image: try Self.makeImage(), feature: Self.exposure(0))
    document.feature = Self.exposure(1)
    document.commit()
    document.undo()
    document.feature = Self.exposure(3)
    document.commit()
    #expect(!document.canRedo)
    #expect(document.history.redoStack.isEmpty)
  }

  @Test func `The limit keeps the newest undo steps`() throws {
    var document = EditingDocument(
      image: try Self.makeImage(),
      feature: Self.exposure(0),
      history: .init(limit: 2)
    )
    for value in 1...4 {
      document.feature = Self.exposure(Double(value))
      document.commit()
    }
    #expect(document.history.undoStack == [Self.exposure(2), Self.exposure(3)])

    document.history.limit = 1
    #expect(document.history.undoStack == [Self.exposure(3)])
  }

  @Test func `Dropping and restoring history`() throws {
    var document = EditingDocument(image: try Self.makeImage(), feature: Self.exposure(0))
    document.feature = Self.exposure(1)
    document.commit()

    // An app that saves history reads the stacks and restores them.
    let saved = document.history
    var restored = EditingDocument(
      image: document.image,
      feature: document.feature,
      history: .init(undoStack: saved.undoStack, redoStack: saved.redoStack, limit: saved.limit)
    )
    #expect(restored == document)
    restored.undo()
    #expect(restored.feature == Self.exposure(0))

    // Dropping it keeps the feature.
    document.history.removeAll()
    #expect(!document.canUndo)
    #expect(document.feature == Self.exposure(1))
  }

  // MARK: - PhotosCrop documents

  @Test func `A new PhotosCrop document crops the whole image`() throws {
    let image = try Self.makeImage()
    let document = EditingDocument(image: image)
    #expect(document.feature == PhotosCropFeature(imageSize: image.pixelSize))
    #expect(document.feature.crop.cropRect == CGRect(origin: .zero, size: image.pixelSize))
  }

  @Test func `A crop modifier decides the committed initial crop`() async throws {
    let image = try Self.makeImage()
    let document = await EditingDocument(
      image: image,
      cropModifier: CropModifier { input, crop in
        // The modifier sees the image in the document's domain.
        #expect(input.extent.size == image.pixelSize)
        var crop = crop
        crop.updateCropExtent(toFitAspectRatio: .square)
        return crop
      }
    )
    #expect(document.feature.crop.cropRect.width == document.feature.crop.cropRect.height)
    #expect(!document.canUndo)
  }

  // MARK: - Rendering

  @Test func `Rendering a document renders its feature over its image`() async throws {
    var document = EditingDocument(image: try Self.makeImage())
    document.feature.crop = CropFeature(cropRect: CGRect(x: 0, y: 0, width: 20, height: 10))
    let rendered = try await document.render()
    let cgImage = try rendered.cgImage
    #expect(cgImage.width == 20)
    #expect(cgImage.height == 10)
  }

  @Test func `An editing stack prepares the document's image`() async throws {
    let image = try Self.makeImage()
    let stack = EditingStack(image: image)
    await withCheckedContinuation { continuation in
      stack.start {
        continuation.resume()
      }
    }
    let loaded = try #require(stack.loadedState)
    #expect(loaded.image == image)
    #expect(loaded.imageSize == image.pixelSize)
    #expect(loaded.editingSourceImage.extent.size == image.pixelSize)
  }

  // MARK: - Binding

  @Test func `A canvas change of another image is dropped`() throws {
    final class Box {
      var document: EditingDocument<PhotosCropFeature>
      init(_ document: EditingDocument<PhotosCropFeature>) { self.document = document }
    }
    let data = try Self.makeRotatedJPEG()
    let shown = try SourceImage(data: data)
    let replaced = try SourceImage(data: data)
    let box = Box(EditingDocument(image: replaced))
    let binding = Binding(get: { box.document }, set: { box.document = $0 })

    // A change queued by the canvas that showed `shown`.
    SwiftUICropView.apply({ $0.blurMask = nil; $0.effects.exposure = .init(value: 1) }, preparedFor: shown, to: binding)
    #expect(box.document.feature.effects.exposure == nil)

    SwiftUICropView.apply({ $0.effects.exposure = .init(value: 1) }, preparedFor: replaced, to: binding)
    #expect(box.document.feature.effects.exposure == ExposureFeature(value: 1))
  }
}
