import CoreImage
import CoreGraphics
import Foundation
import Observation
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

@MainActor
struct PhotosCropEditingModelTests {

  private let imageSize = CGSize(width: 40, height: 20)

  private let preset = PresetFeature(
    id: FeatureID(rawValue: "test-preset-feature"),
    name: "Test",
    identifier: "test",
    effects: [BrightnessFeature(value: 0.1)]
  )

  // MARK: - Initial document

  @Test func `A model resuming a document over a loaded stack is loaded synchronously`() {
    var initial = PhotosCropDocument(orientedImageSize: imageSize)
    PhotosCropAdjustmentParameter.exposure.apply(sliderValue: 30, to: &initial.effects)

    let model = PhotosCropEditingModel(editingStack: makeStack(), resuming: initial)

    #expect(model.isLoaded)
    #expect(model.document == initial)
    #expect(!model.isDirty)
    #expect(!model.canUndo)
  }

  @Test func `Model creates the full-image document with the identity modifier synchronously`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    #expect(model.isLoaded)
    #expect(model.document == PhotosCropDocument(orientedImageSize: imageSize))
    #expect(!model.isDirty)
  }

  @Test func `Model keeps the editing stack alive`() {
    weak var retainedStack: EditingStack?
    let model: PhotosCropEditingModel

    do {
      let stack = makeStack()
      retainedStack = stack
      model = PhotosCropEditingModel(editingStack: stack)
    }

    #expect(retainedStack != nil)
    #expect(model.isLoaded)
  }

  @Test func `Custom crop modifier sets the initial crop`() async throws {
    let model = PhotosCropEditingModel(
      editingStack: makeStack(),
      cropModifier: CropModifier { _, crop in
        var crop = crop
        crop.updateCropExtent(toFitAspectRatio: .square)
        return crop
      }
    )

    let document = try await waitForDocument(model)

    let rect = document.crop.displayCropRect(imageSize: imageSize)
    #expect(rect.width == rect.height)
    #expect(document.crop.id == PhotosCropDocument.MemberID.crop)
    #expect(!model.isDirty)
  }

  @Test func `The initial-document preparation runs once`() async throws {
    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private var value = 0
      func increment() { lock.withLock { value += 1 } }
      var count: Int { lock.withLock { value } }
    }
    let counter = Counter()

    let model = PhotosCropEditingModel(
      editingStack: makeStack(),
      cropModifier: CropModifier { _, crop in
        counter.increment()
        var crop = crop
        crop.updateCropExtent(toFitAspectRatio: .square)
        return crop
      }
    )

    let first = try await waitForDocument(model)
    // Let a second, erroneous preparation surface if there were one.
    try await Task.sleep(for: .milliseconds(200))

    #expect(counter.count == 1)
    #expect(model.document == first)
  }

  /// A face-detection modifier that finds no face (or whose request fails)
  /// installs its fallback crop instead of leaving the editor loading.
  @Test func `Face detection without a face falls back instead of hanging`() async throws {
    let model = PhotosCropEditingModel(
      editingStack: makeStack(),
      cropModifier: .faceDetection(aspectRatio: .square)
    )

    let document = try await waitForDocument(model)

    let rect = document.crop.displayCropRect(imageSize: imageSize)
    #expect(rect.width == rect.height)
  }

  @Test func `makeInitial applies the crop modifier to a full-image document`() async throws {
    let stack = makeStack()
    let loaded = try #require(stack.loadedState)

    let identity = await PhotosCropDocument.makeInitial(for: loaded)
    #expect(identity == PhotosCropDocument(orientedImageSize: imageSize))

    let squared = await PhotosCropDocument.makeInitial(
      for: loaded,
      cropModifier: CropModifier { _, crop in
        var crop = crop
        crop.updateCropExtent(toFitAspectRatio: .square)
        return crop
      }
    )
    let rect = squared.crop.displayCropRect(imageSize: imageSize)
    #expect(rect.width == rect.height)
    #expect(squared.effects == identity.effects)
    #expect(squared.blurMask == nil)
  }

  /// A host that renders the model's document before it is prepared gets an
  /// error, not the unedited image.
  @Test func `Rendering a document that is not prepared yet throws`() {
    let stack = makeStack()
    let pending: PhotosCropDocument? = nil

    #expect(throws: EditingStackError.documentUnavailable) {
      _ = try stack.makeRenderer(document: pending)
    }
  }

  @Test func `A restored document is normalized`() {
    let restored = PhotosCropDocument(
      effects: .init(),
      crop: CropFeature(displayCropRect: CGRect(origin: .zero, size: imageSize), imageSize: imageSize)
    )
    var raw = restored
    // Members assigned after construction bypass the rebuilding init.
    raw.effects.exposure = ExposureFeature(value: 0.9)
    raw.effects.vignette = VignetteFeature(isEnabled: false, value: 1)

    let model = PhotosCropEditingModel(editingStack: makeStack(), resuming: raw)

    #expect(model.document?.effects.exposure?.id == PhotosCropDocument.MemberID.exposure)
    #expect(model.document?.effects.vignette == nil)

    model.setAdjustmentValue(50, parameter: .exposure)
    model.commitIfNeeded()
    model.setAdjustmentValue(0, parameter: .exposure)
    model.setAdjustmentValue(50, parameter: .exposure)
    #expect(!model.hasUncommittedChanges)
  }

  // MARK: - Edits

  @Test func `Global effect edits go through the model`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    model.selectFilterPreset(preset)
    model.setAdjustmentValue(50, parameter: .exposure)

    #expect(model.document?.effects.preset?.identifier == "test")
    #expect(model.document?.effects.exposure?.value == 0.9)
    #expect(model.isDirty)
  }

  @Test func `Re-applying the same slider value adds no checkpoint`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    model.setAdjustmentValue(50, parameter: .exposure)
    model.commitIfNeeded()

    model.setAdjustmentValue(0, parameter: .exposure)
    model.setAdjustmentValue(50, parameter: .exposure)
    #expect(!model.hasUncommittedChanges)

    model.commitIfNeeded()

    // A single checkpoint: one undo returns to the initial document.
    model.undo()
    #expect(model.document?.effects.exposure == nil)
    #expect(!model.canUndo)
  }

  @Test func `Re-selecting the same preset adds no checkpoint`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    model.selectFilterPreset(preset)
    model.commitIfNeeded()
    model.selectFilterPreset(nil)
    model.selectFilterPreset(preset)

    #expect(!model.hasUncommittedChanges)
  }

  @Test func `Commits undo checkpoints at the tool boundary`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    model.selectFilterPreset(preset)
    model.commitIfNeeded()
    #expect(model.canUndo)

    model.undo()
    #expect(model.document?.effects.preset == nil)
    #expect(model.canRedo)

    model.redo()
    #expect(model.document?.effects.preset?.identifier == "test")
  }

  @Test func `Discarding uncommitted changes returns to the latest checkpoint`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    model.selectFilterPreset(preset)
    model.commitIfNeeded()
    model.setAdjustmentValue(50, parameter: .exposure)

    model.discardUncommittedChanges()

    #expect(model.document?.effects.preset?.identifier == "test")
    #expect(model.document?.effects.exposure == nil)
  }

  @Test func `Clear blur mask removes the blur mask only`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())
    var document = model.document!
    PhotosCropAdjustmentParameter.exposure.apply(sliderValue: 50, to: &document.effects)
    document.appendBlurMaskStroke(
      BrushMaskStroke(stamps: [CGPoint(x: 10, y: 10)], brush: .init(diameter: 4, hardness: 1, opacity: 1))
    )
    var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 0, y: 0, width: 20, height: 20))
    document.setCrop(crop)
    model.updateDocument { $0 = document }

    model.clearBlurMask()

    #expect(model.document?.blurMask == nil)
    #expect(model.document?.effects == document.effects)
    #expect(model.document?.crop == document.crop)
  }

  @Test func `An update that leaves the document equal is a no-op`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())
    let document = model.document!

    model.updateDocument { $0 = document }

    #expect(!model.hasUncommittedChanges)
    #expect(!model.isDirty)
    #expect(!model.canUndo)
  }

  @Test func `History operations with nothing to do notify no observers`() {
    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private var value = 0
      func increment() { lock.withLock { value += 1 } }
      var count: Int { lock.withLock { value } }
    }
    let model = PhotosCropEditingModel(editingStack: makeStack())
    let counter = Counter()

    func observeOnce(_ operation: () -> Void) {
      withObservationTracking {
        _ = model.document
      } onChange: {
        counter.increment()
      }
      operation()
    }

    observeOnce { model.commitIfNeeded() }
    observeOnce { model.undo() }
    observeOnce { model.redo() }
    observeOnce { model.discardUncommittedChanges() }
    #expect(counter.count == 0)

    // A real change still notifies (every registration above is pending).
    observeOnce { model.setAdjustmentValue(50, parameter: .exposure) }
    #expect(counter.count > 0)
  }

  @Test func `Editing target mapping`() {
    #expect(PhotosCropEditingMode.crop.cropViewEditingTarget == .crop)
    #expect(PhotosCropEditingMode.blurMasking.cropViewEditingTarget == .blurMask)
    #expect(PhotosCropEditingMode.filters.cropViewEditingTarget == nil)
    #expect(PhotosCropEditingMode.adjustments.cropViewEditingTarget == nil)
  }

  // MARK: - Helpers

  private func makeStack() -> EditingStack {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let cgImage = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
      UIColor.white.setFill()
      UIRectFill(CGRect(origin: .zero, size: imageSize))
    }.cgImage!
    return EditingStack.test(cgImage: cgImage)
  }

  private func waitForDocument(
    _ model: PhotosCropEditingModel,
    timeout: Duration = .seconds(10)
  ) async throws -> PhotosCropDocument {
    let deadline = ContinuousClock.now + timeout
    while model.document == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(model.document)
  }
}
