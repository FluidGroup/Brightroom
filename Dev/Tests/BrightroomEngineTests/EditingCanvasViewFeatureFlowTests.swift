import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// `EditingCanvasView` takes a feature value and reports its own changes (value in,
/// changes out). These run without a window: the editing target is set before
/// `loadFeature()`, the order `makeUIView` uses, because leaving `.crop`
/// after loading records the crop from zero-size views.
@MainActor
struct EditingCanvasViewFeatureFlowTests {

  private let imageSize = CGSize(width: 400, height: 300)

  private func makeSource(size: CGSize) -> CIImage {
    let checkerboard = CIFilter(
      name: "CICheckerboardGenerator",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor.white,
        "inputColor1": CIColor.black,
        "inputWidth": 6,
        "inputSharpness": 1,
      ]
    )!.outputImage!
    return checkerboard.cropped(to: CGRect(origin: .zero, size: size))
  }

  private struct Harness {
    let canvasView: EditingCanvasView
    var snapshots: [ImageEditorCanvas.StateSnapshot] { box.snapshots }
    /// The owner's feature after each change EditingCanvasView reported.
    var emitted: [ImageEditorFeature] { box.emitted }
    let box: Box

    /// Plays the feature's owner: applies each change to its own latest
    /// feature.
    final class Box {
      var snapshots: [ImageEditorCanvas.StateSnapshot] = []
      var emitted: [ImageEditorFeature] = []
      var owned: ImageEditorFeature

      init(owned: ImageEditorFeature) {
        self.owned = owned
      }
    }
  }

  /// An EditingCanvasView over a checkerboard, with the handlers bound and the target
  /// set before loading, as `makeUIView` does.
  private func makeLoadedCanvasView(
    feature: ImageEditorFeature,
    target: ImageEditorCanvas.Target? = .localBlur
  ) -> Harness {
    let canvasView = EditingCanvasView(
      source: EditingCanvasSource(editingSourceImage: makeSource(size: imageSize), imageSize: imageSize),
      feature: feature
    )
    let box = Harness.Box(owned: feature)
    canvasView.setStateHandler { box.snapshots.append($0) }
    canvasView.setFeatureChangeHandler { change in
      change(&box.owned)
      box.emitted.append(box.owned)
    }
    canvasView.setEditingTarget(target)
    canvasView.loadFeature()
    return Harness(canvasView: canvasView, box: box)
  }

  private func makeAngledFeature(degrees: Double) -> ImageEditorFeature {
    var feature = ImageEditorFeature(imageSize: imageSize)
    var crop = CropEditingState(cropFeature: feature.crop, imageSize: imageSize)
    crop.adjustmentAngle = .init(degrees: degrees)
    feature.setCrop(crop)
    return feature
  }

  @Test func `Loading emits the first snapshot to the bound handler`() throws {
    let harness = makeLoadedCanvasView(feature: makeAngledFeature(degrees: 10))

    #expect(harness.emitted.isEmpty, "setting the target before loading commits nothing")
    let snapshot = try #require(harness.snapshots.last)
    let angle = try #require(snapshot.proposedCrop?.adjustmentAngle.degrees)
    #expect(abs(angle - 10) < 0.001)
  }

  @Test func `A committed stroke is stored in working space`() throws {
    let harness = makeLoadedCanvasView(feature: makeAngledFeature(degrees: 10))
    let proposed = try #require(harness.snapshots.last?.proposedCrop)
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: proposed))
    let record = EditingCanvasStrokeRecord(
      stamps: [CGPoint(x: 40, y: 30), CGPoint(x: 42, y: 31)],
      brush: .init(size: 12)
    )

    var completed = false
    harness.canvasView.commitCanvasStroke(record: record) { completed = true }

    #expect(completed)
    #expect(harness.emitted.count == 1)
    let expected = geometry.sourceRecord(fromOutputRecord: record)
      .workingSpaceStroke(domainHeight: imageSize.height)
    #expect(harness.emitted.last?.localBlurStrokes == [expected])
    #expect(harness.emitted.last?.localBlur?.content == ImageEditorFeature.defaultLocalBlurContent)
  }

  @Test func `Echo does not reload the crop`() throws {
    let harness = makeLoadedCanvasView(feature: makeAngledFeature(degrees: 10))
    harness.canvasView.commitCanvasStroke(
      record: .init(stamps: [CGPoint(x: 40, y: 30)], brush: .init(size: 12))
    ) {}
    let echoed = try #require(harness.emitted.last)
    let snapshotCount = harness.snapshots.count
    let proposed = harness.snapshots.last?.proposedCrop

    harness.canvasView.setFeature(echoed)

    #expect(harness.snapshots.count == snapshotCount)
    #expect(harness.snapshots.last?.proposedCrop == proposed)
    #expect(harness.emitted.count == 1, "an echo is not emitted again")
  }

  @Test func `An external crop change reloads the crop`() throws {
    let harness = makeLoadedCanvasView(feature: makeAngledFeature(degrees: 10))
    let snapshotCount = harness.snapshots.count

    // What an undo produces: a feature whose crop differs from the view's.
    var undone = makeAngledFeature(degrees: 10)
    var smaller = CropEditingState(cropFeature: undone.crop, imageSize: imageSize)
    smaller.adjustmentAngle = .zero
    smaller.updateCropExtent(CGRect(x: 20, y: 10, width: 200, height: 150))
    undone.setCrop(smaller)
    harness.canvasView.setFeature(undone)

    #expect(harness.snapshots.count > snapshotCount)
    let reloaded = try #require(harness.snapshots.last?.proposedCrop)
    #expect(reloaded.adjustmentAngle == .zero)
    #expect(reloaded.cropExtent == smaller.cropExtent)
    #expect(harness.emitted.isEmpty, "an external feature is not echoed back")
  }

  /// An owner-side change EditingCanvasView has not received yet (an effect set in the
  /// same turn as a crop commit) survives the commit.
  @Test func `A crop commit keeps owner changes EditingCanvasView has not received`() throws {
    let harness = makeLoadedCanvasView(
      feature: ImageEditorFeature(imageSize: imageSize),
      target: .crop
    )
    ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &harness.box.owned.effects)
    let exposure = harness.box.owned.effects.exposure

    harness.canvasView.setLockedAspectRatio(.square)
    harness.canvasView.applyPendingCrop()

    let committed = try #require(harness.emitted.last)
    #expect(committed.effects.exposure == exposure)
    let rect = committed.crop.topLeftRect(imageSize: imageSize)
    #expect(rect.width == rect.height)
  }

  /// A crop reloaded from outside (an undo) keeps the active aspect-ratio
  /// lock, so Done cannot commit a crop that breaks it.
  @Test func `A reloaded crop keeps the aspect-ratio lock`() throws {
    let initial = ImageEditorFeature(imageSize: imageSize)
    let harness = makeLoadedCanvasView(feature: initial, target: .crop)

    harness.canvasView.setLockedAspectRatio(.square)
    harness.canvasView.applyPendingCrop()
    #expect(harness.emitted.count == 1)

    // What an undo produces: the full-image crop, while the lock is active.
    harness.canvasView.setFeature(initial)
    harness.canvasView.setLockedAspectRatio(.square)

    let reloaded = try #require(harness.snapshots.last?.proposedCrop)
    #expect(abs(reloaded.cropExtent.width - reloaded.cropExtent.height) <= 1)
  }

  /// A lock describes the output, so an undo across a sideways turn turns it
  /// back with the output instead of refitting the undone crop to the turned
  /// lock; Done then keeps the undone crop.
  @Test func `A reloaded crop across a sideways turn turns the aspect-ratio lock`() throws {
    let initial = ImageEditorFeature(imageSize: imageSize)
    let harness = makeLoadedCanvasView(feature: initial, target: .crop)
    let landscape = AspectRatio(width: 4, height: 3)

    harness.canvasView.setLockedAspectRatio(landscape)
    harness.canvasView.applyPendingCrop()
    harness.canvasView.rotateCounterclockwise()
    harness.canvasView.applyPendingCrop()
    let turned = try #require(harness.emitted.last)
    #expect(turned.crop.quarterTurn.isSideways)
    #expect(harness.snapshots.last?.preferredAspectRatio == landscape.swapped())

    // What an undo of the turn produces.
    harness.canvasView.setFeature(initial)

    let snapshot = try #require(harness.snapshots.last)
    #expect(snapshot.preferredAspectRatio == landscape)
    let reloaded = try #require(snapshot.proposedCrop)
    #expect(reloaded.rotation.isSideways == false)
    #expect(reloaded.cropExtent == CGRect(origin: .zero, size: imageSize))

    let emittedCount = harness.emitted.count
    harness.canvasView.applyPendingCrop()
    #expect(harness.emitted.count == emittedCount)
  }

  @Test func `Switching between tool targets commits nothing`() {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize))

    harness.canvasView.setEditingTarget(nil)
    harness.canvasView.setEditingTarget(.localBlur)

    #expect(harness.emitted.isEmpty)
  }

  /// D2 end to end: a stroke painted at a display point through EditingCanvasView and
  /// exported with the feature changes the export at that point, and not at
  /// its vertical mirror.
  @Test func `A painted stroke exports at the painted display point`() throws {
    let size = CGSize(width: 240, height: 180)
    let source = makeSource(size: size)
    let plain = ImageEditorFeature(imageSize: size)
    let canvasView = EditingCanvasView(
      source: EditingCanvasSource(editingSourceImage: source, imageSize: size),
      feature: plain
    )
    var owned = plain
    var emitted: [ImageEditorFeature] = []
    canvasView.setFeatureChangeHandler { change in
      change(&owned)
      emitted.append(owned)
    }
    canvasView.setEditingTarget(.localBlur)
    canvasView.loadFeature()

    let display = CGPoint(x: 50, y: 40)
    canvasView.commitCanvasStroke(
      record: .init(stamps: [display], brush: .init(size: 30, hardness: 1))
    ) {}
    let painted = try #require(emitted.last)

    let renderer = FeatureRenderer()
    let exported = try pixels(renderer.makeImage(from: source, feature: painted), size: size)
    let reference = try pixels(renderer.makeImage(from: source, feature: plain), size: size)

    let mirror = CGPoint(x: display.x, y: size.height - display.y)
    #expect(meanDifference(exported, reference, width: Int(size.width), at: display) > 20)
    #expect(meanDifference(exported, reference, width: Int(size.width), at: mirror) < 1)
  }

  // MARK: - Helpers

  private func pixels(_ image: CIImage, size: CGSize) throws -> [UInt8] {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CIContext(options: [.workingColorSpace: sRGB])
    let cgImage = try #require(context.createCGImage(image, from: CGRect(origin: .zero, size: size)))
    let width = Int(size.width)
    let height = Int(size.height)
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let bitmap = try #require(
      CGContext(
        data: &buffer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }

  /// The mean red-channel difference in a small box around a display point
  /// (top-left origin, y-down).
  private func meanDifference(
    _ lhs: [UInt8],
    _ rhs: [UInt8],
    width: Int,
    at point: CGPoint,
    radius: Int = 4
  ) -> Double {
    var total = 0.0
    var count = 0.0
    for y in (Int(point.y) - radius)...(Int(point.y) + radius) {
      for x in (Int(point.x) - radius)...(Int(point.x) + radius) {
        let index = (y * width + x) * 4
        total += abs(Double(lhs[index]) - Double(rhs[index]))
        count += 1
      }
    }
    return total / count
  }
}

/// The SwiftUI coordinator defers a feature change that EditingCanvasView emits while
/// SwiftUI inputs are being applied (a state write during a view update), and
/// shows the pending changes applied to the stale owner feature until they
/// are delivered.
@MainActor
struct EditingCanvasRepresentableCoordinatorTests {

  @Test func `A change emitted while applying inputs is delivered later`() async throws {
    let size = CGSize(width: 80, height: 60)
    let feature = ImageEditorFeature(imageSize: size)
    let canvasView = EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)),
        imageSize: size
      ),
      feature: feature
    )
    let stroke = BrushMask.Stroke(
      stampCenters: [CGPoint(x: 10, y: 10)],
      brush: .init(diameter: 4, hardness: 1, opacity: 1)
    )
    var changed = feature
    changed.appendLocalBlurStroke(stroke)

    let coordinator = EditingCanvasRepresentable.Coordinator()
    var owned = feature
    var deliveries = 0
    coordinator.bindFeatureChangeHandler(to: canvasView) { change in
      change(&owned)
      deliveries += 1
    }

    coordinator.applySwiftUIInputs {
      coordinator.deliverFeatureChange { $0.appendLocalBlurStroke(stroke) }
    }

    #expect(deliveries == 0, "not delivered during the view update")
    #expect(
      coordinator.applyingPendingFeatureChanges(to: feature) == changed,
      "the pending change is shown over the stale owner feature"
    )

    for _ in 0..<10 where deliveries == 0 {
      await Task.yield()
    }
    #expect(deliveries == 1)
    #expect(owned == changed)
    #expect(coordinator.applyingPendingFeatureChanges(to: feature) == feature)

    // Outside input application a change is delivered at once.
    coordinator.deliverFeatureChange { $0.localBlur = nil }
    #expect(deliveries == 2)
    #expect(owned == feature)
  }
}
