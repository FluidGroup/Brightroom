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
    var guides: [ImageEditorCanvas.CropGuide] { box.guides }
    /// The owner's feature after each change EditingCanvasView reported.
    var emitted: [ImageEditorFeature] { box.emitted }
    let box: Box

    /// Plays the feature's owner: applies each change to its own latest
    /// feature.
    final class Box {
      var guides: [ImageEditorCanvas.CropGuide] = []
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
    canvasView.setCropGuideHandler { box.guides.append($0) }
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
    var crop = CropGuideState(cropFeature: feature.crop, imageSize: imageSize)
    crop.adjustmentAngle = .init(degrees: degrees)
    feature.crop = crop.makeCropFeature()
    return feature
  }

  @Test func `Loading reports the first crop guide to the bound handler`() throws {
    let harness = makeLoadedCanvasView(feature: makeAngledFeature(degrees: 10))

    #expect(harness.emitted.isEmpty, "setting the target before loading commits nothing")
    let guide = try #require(harness.guides.last)
    let radians = try #require(guide.pendingCrop?.straightenRadians)
    #expect(abs(radians * 180 / .pi - 10) < 0.001)
  }

  @Test func `A committed stroke is stored in working space`() throws {
    let harness = makeLoadedCanvasView(feature: makeAngledFeature(degrees: 10))
    let proposed = try #require(harness.canvasView.proposedCrop)
    #expect(harness.guides.last?.pendingCrop == proposed.makeCropFeature())
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
    let guideCount = harness.guides.count
    let pending = harness.guides.last?.pendingCrop

    harness.canvasView.setFeature(echoed)

    #expect(harness.guides.count == guideCount)
    #expect(harness.guides.last?.pendingCrop == pending)
    #expect(harness.emitted.count == 1, "an echo is not emitted again")
  }

  @Test func `An external crop change reloads the crop`() throws {
    let harness = makeLoadedCanvasView(feature: makeAngledFeature(degrees: 10))
    let guideCount = harness.guides.count

    // What an undo produces: a feature whose crop differs from the view's.
    var undone = makeAngledFeature(degrees: 10)
    var smaller = CropGuideState(cropFeature: undone.crop, imageSize: imageSize)
    smaller.adjustmentAngle = .zero
    smaller.updateCropExtent(CGRect(x: 20, y: 10, width: 200, height: 150))
    undone.crop = smaller.makeCropFeature()
    harness.canvasView.setFeature(undone)

    #expect(harness.guides.count > guideCount)
    let reloaded = try #require(harness.guides.last?.pendingCrop)
    #expect(reloaded.straightenRadians == 0)
    #expect(reloaded == undone.crop)
    #expect(harness.canvasView.proposedCrop?.cropExtent == smaller.cropExtent)
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

    let reloaded = try #require(harness.guides.last?.pendingCrop)
    #expect(abs(reloaded.rect.width - reloaded.rect.height) <= 1)
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
    #expect(harness.guides.last?.lockedAspectRatio == landscape.swapped())

    // What an undo of the turn produces.
    harness.canvasView.setFeature(initial)

    let guide = try #require(harness.guides.last)
    #expect(guide.lockedAspectRatio == landscape)
    let reloaded = try #require(guide.pendingCrop)
    #expect(reloaded.quarterTurn.isSideways == false)
    #expect(reloaded.topLeftRect(imageSize: imageSize) == CGRect(origin: .zero, size: imageSize))

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

/// The SwiftUI coordinator delivers the canvas's crop guide to the host's
/// `onCropGuideChange`: at once outside a view update, on the next
/// main-actor turn (latest only) while SwiftUI inputs are being applied, and
/// never twice in a row with an equal value.
@MainActor
struct EditingCanvasRepresentableCropGuideTests {

  private let size = CGSize(width: 80, height: 60)

  private func makeCanvasView() -> EditingCanvasView {
    EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)),
        imageSize: size
      ),
      feature: ImageEditorFeature(imageSize: size)
    )
  }

  private func guide(_ interaction: CropInteraction) -> ImageEditorCanvas.CropGuide {
    .init(
      pendingCrop: nil,
      canvasBounds: CGRect(x: 0, y: 0, width: 320, height: 480),
      interaction: interaction,
      lockedAspectRatio: nil
    )
  }

  /// Lets queued main-actor work run.
  private func drainMainActor() async {
    for _ in 0..<10 {
      await Task.yield()
    }
  }

  private final class Deliveries {
    var guides: [ImageEditorCanvas.CropGuide] = []
  }

  private func bind(
    _ coordinator: EditingCanvasRepresentable.Coordinator,
    to canvasView: EditingCanvasView
  ) -> Deliveries {
    let deliveries = Deliveries()
    coordinator.bindCropGuideHandler(
      to: canvasView,
      syncInputs: { _ in },
      onCropGuideChange: { deliveries.guides.append($0) }
    )
    return deliveries
  }

  @Test func `A guide reported while applying inputs is delivered on the next turn, latest only`() async {
    let coordinator = EditingCanvasRepresentable.Coordinator()
    let deliveries = bind(coordinator, to: makeCanvasView())

    coordinator.applySwiftUIInputs {
      coordinator.deliverCropGuide(guide([]))
      coordinator.deliverCropGuide(guide(.movingImage))
    }
    #expect(deliveries.guides.isEmpty, "not delivered during the view update")

    await drainMainActor()
    #expect(deliveries.guides == [guide(.movingImage)])

    // Outside input application a guide is delivered at once.
    coordinator.deliverCropGuide(guide(.resizingGuide))
    #expect(deliveries.guides == [guide(.movingImage), guide(.resizingGuide)])
  }

  @Test func `An equal guide is not delivered again`() async {
    let coordinator = EditingCanvasRepresentable.Coordinator()
    let deliveries = bind(coordinator, to: makeCanvasView())

    coordinator.deliverCropGuide(guide([]))
    coordinator.deliverCropGuide(guide([]))
    #expect(deliveries.guides == [guide([])])

    coordinator.applySwiftUIInputs {
      coordinator.deliverCropGuide(guide([]))
    }
    await drainMainActor()
    #expect(deliveries.guides == [guide([])], "a deferred guide equal to the last one is dropped")

    coordinator.deliverCropGuide(guide(.movingImage))
    coordinator.deliverCropGuide(guide([]))
    #expect(deliveries.guides == [guide([]), guide(.movingImage), guide([])])
  }

  @Test func `A guide reported outside an update supersedes a pending one`() async {
    let coordinator = EditingCanvasRepresentable.Coordinator()
    let deliveries = bind(coordinator, to: makeCanvasView())

    coordinator.applySwiftUIInputs {
      coordinator.deliverCropGuide(guide(.movingImage))
    }
    coordinator.deliverCropGuide(guide(.resizingGuide))
    #expect(deliveries.guides == [guide(.resizingGuide)])

    await drainMainActor()
    #expect(deliveries.guides == [guide(.resizingGuide)], "the older pending guide is never delivered")
  }

  @Test func `The canvas's own reports follow the same rules`() async throws {
    let coordinator = EditingCanvasRepresentable.Coordinator()
    let canvasView = makeCanvasView()
    let deliveries = bind(coordinator, to: canvasView)
    canvasView.setEditingTarget(.crop)

    // Mounting loads the feature inside the view update.
    coordinator.applySwiftUIInputs {
      canvasView.loadFeature()
    }
    #expect(deliveries.guides.isEmpty)
    await drainMainActor()
    #expect(deliveries.guides.count == 1)
    #expect(deliveries.guides.last?.pendingCrop == canvasView.proposedCrop?.makeCropFeature())

    // A command outside the update is reported before it returns.
    let square = AspectRatio(width: 1, height: 1)
    canvasView.setLockedAspectRatio(square)
    #expect(deliveries.guides.count == 2)
    #expect(deliveries.guides.last?.lockedAspectRatio == square)

    // Reset reports the reset crop, then the same guide again; the repeat is
    // dropped.
    canvasView.resetCrop()
    #expect(deliveries.guides.count == 3)
    let reset = try #require(deliveries.guides.last)
    #expect(reset.lockedAspectRatio == nil)
    #expect(reset.pendingCrop == canvasView.proposedCrop?.makeCropFeature())
  }
}
