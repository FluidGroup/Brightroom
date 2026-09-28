import CoreImage
import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// ImageEditor's document operations and the values its editor writes.
///
/// Replaces the tests of the removed `ImageEditor.Model`: the document
/// (`ImageEditorDocument`) now holds the feature and its
/// history, and `ImageEditorSession` decides what the editor writes.
@MainActor
struct ImageEditorFeatureEditingTests {

  private let imageSize = CGSize(width: 40, height: 20)

  private let preset = FilterFeature(
    name: "Test",
    id: "test",
    effects: [AnyImageEffect(BrightnessFeature(value: 0.1))]
  )

  // MARK: - Initial document

  @Test func `A resumed feature is installed unchanged`() {
    var restored = ImageEditorFeature(
      effects: .init(),
      crop: CropFeature(topLeftRect: CGRect(origin: .zero, size: imageSize), imageSize: imageSize)
    )
    // Members assigned after construction are ordinary values too.
    restored.effects.exposure = ExposureFeature(ev: 0.9)
    restored.effects.vignette = VignetteFeature(value: 1)

    var document = EditingDocument(source: makeImage(), feature: restored)
    #expect(document.feature == restored)
    #expect(!document.canUndo)

    // A slider write of the same value is not an edit: the resumed member and
    // the slider-made one are equal.
    document.setAdjustmentValue(50, parameter: .exposure)
    #expect(!document.hasUncommittedChanges)
    #expect(document.feature == restored)

    // A round trip through neutral returns to the resumed value.
    document.setAdjustmentValue(0, parameter: .exposure)
    document.setAdjustmentValue(50, parameter: .exposure)
    #expect(!document.hasUncommittedChanges)
  }

  @Test func `The identity modifier creates the full-image document`() async {
    let image = makeImage()
    let document = await EditingDocument(source: image, cropModifier: .identity)

    #expect(document.feature == ImageEditorFeature(imageSize: imageSize))
    #expect(document == EditingDocument(source: image))
    #expect(!document.canUndo)
  }

  @Test func `A custom crop modifier sets the initial crop`() async {
    let document = await EditingDocument(
      source: makeImage(),
      cropModifier: CropModifier { _, crop in
        var crop = crop
        crop.updateCropExtent(toFitAspectRatio: .square)
        return crop
      }
    )

    let rect = document.feature.crop.topLeftRect(imageSize: imageSize)
    #expect(rect.width == rect.height)
    #expect(!document.canUndo)
  }

  @Test func `The crop modifier runs once per document`() async {
    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private var value = 0
      func increment() { lock.withLock { value += 1 } }
      var count: Int { lock.withLock { value } }
    }
    let counter = Counter()

    let document = await EditingDocument(
      source: makeImage(),
      cropModifier: CropModifier { _, crop in
        counter.increment()
        return crop
      }
    )
    // Copies, commits, and undo never run it again.
    var copy = document
    copy.feature.effects.exposure = ExposureFeature(ev: 1)
    copy.commit()
    copy.undo()

    #expect(counter.count == 1)
    #expect(copy.feature == document.feature)
  }

  /// A face-detection modifier that finds no face (or whose request fails)
  /// installs its fallback crop instead of hanging.
  @Test func `Face detection without a face falls back instead of hanging`() async {
    let document = await EditingDocument(
      source: makeImage(),
      cropModifier: .faceDetection(aspectRatio: .square)
    )

    let rect = document.feature.crop.topLeftRect(imageSize: imageSize)
    #expect(rect.width == rect.height)
  }

  // MARK: - Edits

  @Test func `Global effect edits change the feature`() {
    var document = EditingDocument(source: makeImage())

    document.selectFilterPreset(preset)
    document.setAdjustmentValue(50, parameter: .exposure)

    #expect(document.feature.effects.preset?.id == "test")
    #expect(document.feature.effects.exposure?.ev == 0.9)
    #expect(document.hasUncommittedChanges)
  }

  @Test func `Re-applying the same slider value adds no step`() {
    var document = EditingDocument(source: makeImage())

    document.setAdjustmentValue(50, parameter: .exposure)
    document.commit()

    document.setAdjustmentValue(0, parameter: .exposure)
    document.setAdjustmentValue(50, parameter: .exposure)
    #expect(!document.hasUncommittedChanges)

    document.commit()

    // A single step: one undo returns to the initial document.
    document.undo()
    #expect(document.feature.effects.exposure == nil)
    #expect(!document.canUndo)
  }

  @Test func `Re-selecting the same preset adds no step`() {
    var document = EditingDocument(source: makeImage())

    document.selectFilterPreset(preset)
    document.commit()
    document.selectFilterPreset(nil)
    document.selectFilterPreset(preset)

    #expect(!document.hasUncommittedChanges)
  }

  @Test func `A tool visit is one step`() {
    let opened = EditingDocument(source: makeImage())
    var session = ImageEditorSession(documentAtStart: opened)

    // A filter tap writes without committing.
    let tapped = session.document(after: opened) { $0.selectFilterPreset(preset) }
    var document = tapped!
    #expect(document.hasUncommittedChanges)

    // Leaving the tool writes nothing; the next visit's first write commits.
    let left = session.endToolVisit(of: document)
    #expect(left == nil)
    document = session.document(after: document) { $0.setAdjustmentValue(50, parameter: .exposure) }!
    #expect(document.history.undoStack.count == 1)
    #expect(document.canUndo)

    document.undo()
    #expect(document.feature.effects.exposure == nil)
    #expect(document.feature.effects.preset?.id == "test")

    document.undo()
    #expect(document.feature.effects.preset == nil)
    #expect(document.canRedo)

    document.redo()
    #expect(document.feature.effects.preset?.id == "test")
  }

  @Test func `Discarding uncommitted changes returns to the latest commit`() {
    var document = EditingDocument(source: makeImage())

    document.selectFilterPreset(preset)
    document.commit()
    document.setAdjustmentValue(50, parameter: .exposure)

    document.discardUncommittedChanges()

    #expect(document.feature.effects.preset?.id == "test")
    #expect(document.feature.effects.exposure == nil)
  }

  @Test func `Clear blur mask removes the blur mask only`() {
    var document = EditingDocument(source: makeImage())
    ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &document.feature.effects)
    document.feature.appendLocalBlurStroke(
      BrushMask.Stroke(stampCenters: [CGPoint(x: 10, y: 10)], brush: .init(diameter: 4, hardness: 1, opacity: 1))
    )
    var crop = CropEditingState(cropFeature: document.feature.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 0, y: 0, width: 20, height: 20))
    document.feature.setCrop(crop)
    let before = document.feature

    document.clearLocalBlur()

    #expect(document.feature.localBlur == nil)
    #expect(document.feature.effects == before.effects)
    #expect(document.feature.crop == before.crop)
  }

  @Test func `An operation that leaves the document equal writes nothing`() {
    let document = EditingDocument(source: makeImage())
    var session = ImageEditorSession(documentAtStart: document)
    let feature = document.feature

    let written = session.document(after: document) { $0.feature = feature }
    #expect(written == nil)
  }

  @Test func `Crop changes are measured against the whole image`() {
    var document = EditingDocument(source: makeImage())
    #expect(!document.hasCropChanges())

    var crop = CropEditingState(cropFeature: document.feature.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 0, y: 0, width: 20, height: 20))
    document.feature.setCrop(crop)
    #expect(document.hasCropChanges())

    // Effects are not crop changes.
    var effectsOnly = EditingDocument(source: makeImage())
    effectsOnly.setAdjustmentValue(50, parameter: .exposure)
    #expect(!effectsOnly.hasCropChanges())
  }

  @Test func `Editing target mapping`() {
    #expect(ImageEditor.Mode.crop.canvasTarget == .crop)
    #expect(ImageEditor.Mode.localBlur.canvasTarget == .localBlur)
    #expect(ImageEditor.Mode.filters.canvasTarget == nil)
    #expect(ImageEditor.Mode.adjust.canvasTarget == nil)
  }

  // MARK: - Helpers

  private func makeImage() -> SourceImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let cgImage = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
      UIColor.white.setFill()
      UIRectFill(CGRect(origin: .zero, size: imageSize))
    }.cgImage!
    return SourceImage(cgImage: cgImage)
  }
}
