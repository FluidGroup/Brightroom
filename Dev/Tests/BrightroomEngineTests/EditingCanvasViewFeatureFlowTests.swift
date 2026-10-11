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

  // MARK: - A local blur the canvas cannot paint

  private func makeFeature(localBlurMask mask: Mask) -> ImageEditorFeature {
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.localBlur = LocalAdjustmentFeature(mask: mask) {
      GaussianBlurFeature(radius: .absolute(12))
    }
    return feature
  }

  private let strokeRecord = EditingCanvasStrokeRecord(
    stamps: [CGPoint(x: 40, y: 30), CGPoint(x: 42, y: 31)],
    brush: .init(size: 12)
  )

  @Test(arguments: MasksThatAreNotABrush.all)
  func `The localBlur target does not paint a mask that is not a brush`(mask: Mask) throws {
    let feature = makeFeature(localBlurMask: mask)
    #expect(feature.isLocalBlurPaintable == false)
    let harness = makeLoadedCanvasView(feature: feature)

    #expect(harness.canvasView.toolSurface.drawingGestureRecognizer.isEnabled == false)

    // A stroke that reaches the commit path anyway changes nothing.
    var completed = false
    harness.canvasView.commitCanvasStroke(record: strokeRecord) { completed = true }

    #expect(completed)
    #expect(harness.emitted.isEmpty)
    #expect(harness.box.owned == feature)
    #expect(harness.box.owned.localBlur?.mask == mask)
  }

  @Test func `The localBlur target paints a brush mask and an absent blur`() {
    let brushFeature = makeFeature(localBlurMask: .brush(MasksThatAreNotABrush.brush))
    #expect(brushFeature.isLocalBlurPaintable)
    #expect(ImageEditorFeature(imageSize: imageSize).isLocalBlurPaintable)

    let harness = makeLoadedCanvasView(feature: brushFeature)
    #expect(harness.canvasView.toolSurface.drawingGestureRecognizer.isEnabled)

    harness.canvasView.commitCanvasStroke(record: strokeRecord) {}
    #expect(harness.emitted.count == 1)
    #expect(harness.emitted.last?.localBlurStrokes.count == MasksThatAreNotABrush.brush.strokes.count + 1)
  }

  /// A host that replaces the blur while Blur is open (an undo, a restore)
  /// turns painting off, and back on once the blur is a brush or removed.
  @Test func `Painting follows whether the host's local blur is paintable`() throws {
    let harness = makeLoadedCanvasView(feature: makeFeature(localBlurMask: .brush(MasksThatAreNotABrush.brush)))
    let drawing = harness.canvasView.toolSurface.drawingGestureRecognizer
    #expect(drawing.isEnabled)

    // The host owns the feature it passes in.
    let inverted = makeFeature(localBlurMask: .inverted(.brush(MasksThatAreNotABrush.brush)))
    harness.box.owned = inverted
    harness.canvasView.setFeature(inverted)
    #expect(drawing.isEnabled == false)
    harness.canvasView.commitCanvasStroke(record: strokeRecord) {}
    #expect(harness.emitted.isEmpty)

    var cleared = inverted
    cleared.localBlur = nil
    harness.box.owned = cleared
    harness.canvasView.setFeature(cleared)
    #expect(drawing.isEnabled)
    harness.canvasView.commitCanvasStroke(record: strokeRecord) {}
    let painted = try #require(harness.emitted.last)
    #expect(painted.localBlur?.content == ImageEditorFeature.defaultLocalBlurContent)
    #expect(painted.localBlurStrokes.count == 1)
  }

  /// The owner applies the canvas's change to its latest feature. When the
  /// host replaced the blur before the stroke's change reached it, the
  /// stroke leaves that blur unchanged.
  @Test func `A stroke that reaches a blur the host replaced leaves it unchanged`() {
    let harness = makeLoadedCanvasView(feature: makeFeature(localBlurMask: .brush(MasksThatAreNotABrush.brush)))
    let replaced = makeFeature(localBlurMask: .feathered(.brush(MasksThatAreNotABrush.brush), radius: 8))
    harness.box.owned = replaced

    harness.canvasView.commitCanvasStroke(record: strokeRecord) {}

    #expect(harness.emitted == [replaced])
  }

  /// Leaving the localBlur target view-only shows what the nil target
  /// shows: the canvas draws no blur for a mask it cannot rasterize, and the
  /// export of the unchanged document still applies the host's mask.
  @Test(arguments: MasksThatAreNotABrush.all)
  func `A mask that is not a brush has no canvas strokes and still exports`(mask: Mask) throws {
    let feature = makeFeature(localBlurMask: mask)
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: feature.localBlur) == .viewportBase)

    let source = makeSource(size: imageSize)
    let renderer = FeatureRenderer()
    let withBlur = try renderer.makeImage(from: source, feature: feature)
    var withoutBlur = feature
    withoutBlur.localBlur = nil
    let plain = try renderer.makeImage(from: source, feature: withoutBlur)

    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    func bytes(_ image: CIImage) -> [UInt8] {
      var pixels = [UInt8](repeating: 0, count: Int(imageSize.width * imageSize.height) * 4)
      context.render(
        image,
        toBitmap: &pixels,
        rowBytes: Int(imageSize.width) * 4,
        bounds: CGRect(origin: .zero, size: imageSize),
        format: .RGBA8,
        colorSpace: nil
      )
      return pixels
    }
    #expect(bytes(withBlur) != bytes(plain), "export applies the host's mask")
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
    ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &harness.box.owned)
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

  // MARK: - Reloading under an aspect-ratio lock

  private func makeFeature(
    topLeftRect: CGRect,
    quarterTurn: QuarterTurn = .zero,
    straightenRadians: Double = 0
  ) -> ImageEditorFeature {
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.crop = CropFeature(
      topLeftRect: topLeftRect,
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
    return feature
  }

  /// An undo under a lock to a crop that already has the locked ratio shows
  /// that crop where it was, and Done writes nothing over the undo.
  @Test func `A reloaded crop that has the locked ratio keeps its place`() throws {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    harness.canvasView.setLockedAspectRatio(.square)
    harness.canvasView.applyPendingCrop()

    let topLeftSquare = CGRect(x: 0, y: 0, width: 150, height: 150)
    let undone = makeFeature(topLeftRect: topLeftSquare)
    harness.box.owned = undone
    harness.canvasView.setFeature(undone)

    #expect(harness.canvasView.proposedCrop?.cropExtent == topLeftSquare)
    #expect(harness.canvasView.proposedCrop?._usedAspectRatio == .square)
    let guide = try #require(harness.guides.last)
    #expect(guide.lockedAspectRatio == .square)
    #expect(guide.pendingCrop == undone.crop)

    let emittedCount = harness.emitted.count
    harness.canvasView.applyPendingCrop()
    #expect(harness.emitted.count == emittedCount, "Done does not overwrite the undo")
  }

  /// A `.fixed` editor loads the crop in `makeUIView` and receives its lock
  /// in the first `updateUIView`. A crop of that ratio, saved from an earlier
  /// session, stays where the user left it.
  @Test func `A lock applied after loading keeps a crop that has the ratio`() {
    let topLeftSquare = CGRect(x: 0, y: 0, width: 150, height: 150)
    let harness = makeLoadedCanvasView(feature: makeFeature(topLeftRect: topLeftSquare), target: .crop)
    let coordinator = EditingCanvasRepresentable.Coordinator()

    coordinator.applyLockedAspectRatio(.square, to: harness.canvasView)
    harness.canvasView.applyPendingCrop()

    #expect(harness.canvasView.proposedCrop?.cropExtent == topLeftSquare)
    #expect(harness.canvasView.proposedCrop?._usedAspectRatio == .square)
    #expect(harness.guides.last?.lockedAspectRatio == .square)
    #expect(harness.emitted.isEmpty)
  }

  /// A face-detection crop of `.square` is rounded inward to whole pixels,
  /// so it can miss the exact ratio by a pixel. Opening it in a
  /// `.fixed(.square)` editor keeps it on the face.
  @Test func `A face crop keeps its place under a fixed square lock`() throws {
    // A face box in Vision coordinates (bottom-left origin), right of center.
    let face = CGRect(x: 0.70, y: 0.55, width: 0.0731, height: 0.0977)
    var initial = ImageEditorFeature(imageSize: imageSize)
    initial.crop = CropFeature.framingFace(face, imageSize: imageSize, paddingBias: 1.3, aspectRatio: .square)
    let faceRect = initial.crop.topLeftRect(imageSize: imageSize)
    try #require(faceRect.width != faceRect.height, "the face crop exercises the rounding allowance")

    let harness = makeLoadedCanvasView(feature: initial, target: .crop)
    EditingCanvasRepresentable.Coordinator().applyLockedAspectRatio(.square, to: harness.canvasView)
    harness.canvasView.applyPendingCrop()

    #expect(harness.canvasView.proposedCrop?.cropExtent == faceRect)
    #expect(harness.guides.last?.pendingCrop == initial.crop)
    #expect(harness.emitted.isEmpty, "the face crop is not replaced by the centered square")
  }

  /// A redo to a sideways crop turns the lock with the output and keeps the
  /// selection, which has the turned ratio.
  @Test func `A reloaded sideways crop that has the turned ratio keeps its place`() throws {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    let landscape = AspectRatio(width: 4, height: 3)
    harness.canvasView.setLockedAspectRatio(landscape)
    harness.canvasView.applyPendingCrop()

    // A 3:4 output: the selection before the turn is 4:3, at the top left.
    let topLeftSelection = CGRect(x: 0, y: 0, width: 200, height: 150)
    let redone = makeFeature(topLeftRect: topLeftSelection, quarterTurn: .counterclockwise90)
    harness.box.owned = redone
    harness.canvasView.setFeature(redone)

    #expect(harness.guides.last?.lockedAspectRatio == landscape.swapped())
    #expect(harness.canvasView.proposedCrop?.cropExtent == topLeftSelection)
    let emittedCount = harness.emitted.count
    harness.canvasView.applyPendingCrop()
    #expect(harness.emitted.count == emittedCount)
  }

  /// An undo to a sideways crop whose output already has the locked ratio
  /// keeps the lock as it is, instead of turning it and fitting the swapped
  /// ratio inside the selection; Done writes nothing over the undo.
  @Test func `A reloaded sideways crop whose output has the lock keeps the lock and its place`() throws {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    let landscape = AspectRatio(width: 4, height: 3)
    harness.canvasView.setLockedAspectRatio(landscape)
    harness.canvasView.applyPendingCrop()

    // A 4:3 output: the selection before the turn is 3:4, at the top left.
    let topLeftSelection = CGRect(x: 0, y: 0, width: 150, height: 200)
    let undone = makeFeature(topLeftRect: topLeftSelection, quarterTurn: .counterclockwise90)
    harness.box.owned = undone
    harness.canvasView.setFeature(undone)

    #expect(harness.guides.last?.lockedAspectRatio == landscape)
    #expect(harness.canvasView.proposedCrop?.cropExtent == topLeftSelection)
    #expect(harness.canvasView.proposedCrop?._usedAspectRatio == landscape)
    let emittedCount = harness.emitted.count
    harness.canvasView.applyPendingCrop()
    #expect(harness.emitted.count == emittedCount, "Done does not overwrite the undo")
  }

  /// A straightened crop of the locked ratio keeps its place as well.
  @Test func `A reloaded straightened crop that has the locked ratio keeps its place`() throws {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    harness.canvasView.setLockedAspectRatio(.square)
    harness.canvasView.applyPendingCrop()

    let undone = makeFeature(
      topLeftRect: CGRect(x: 100, y: 60, width: 150, height: 150),
      straightenRadians: 0.1
    )
    harness.box.owned = undone
    harness.canvasView.setFeature(undone)

    #expect(harness.canvasView.proposedCrop?.cropExtent == undone.crop.topLeftRect(imageSize: imageSize))
    #expect(harness.guides.last?.pendingCrop == undone.crop)
    let emittedCount = harness.emitted.count
    harness.canvasView.applyPendingCrop()
    #expect(harness.emitted.count == emittedCount)
  }

  /// A reloaded crop without the locked ratio is fitted inside its own
  /// rectangle, about its center, not at the image's center.
  @Test func `A reloaded crop without the locked ratio is fitted inside itself`() throws {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    harness.canvasView.setLockedAspectRatio(.square)
    harness.canvasView.applyPendingCrop()

    let mismatched = makeFeature(topLeftRect: CGRect(x: 0, y: 0, width: 200, height: 100))
    harness.box.owned = mismatched
    harness.canvasView.setFeature(mismatched)

    #expect(harness.canvasView.proposedCrop?.cropExtent == CGRect(x: 50, y: 0, width: 100, height: 100))
    #expect(harness.canvasView.proposedCrop?._usedAspectRatio == .square)
  }

  /// `setCrop` with a crop that has no ratio session adopts the lock the
  /// same way.
  @Test func `A crop set under a lock keeps its place when it has the ratio`() {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    harness.canvasView.setLockedAspectRatio(.square)

    let topLeftSquare = CGRect(x: 0, y: 0, width: 150, height: 150)
    harness.canvasView.setCrop(CropGuideState(imageSize: imageSize, cropRect: topLeftSquare))

    #expect(harness.canvasView.proposedCrop?.cropExtent == topLeftSquare)
    #expect(harness.canvasView.proposedCrop?._usedAspectRatio == .square)
  }

  /// In a window, the layout after the reload keeps the crop as well.
  @Test func `A reloaded crop that has the locked ratio keeps its place after layout`() throws {
    let source = try #require(
      CIContext().createCGImage(makeSource(size: imageSize), from: CGRect(origin: .zero, size: imageSize))
    )
    let initial = ImageEditorFeature(imageSize: imageSize)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let canvasView = EditingCanvasView(source: EditingCanvasSource(PreviewSource.test(cgImage: source)), feature: initial)
    let box = Harness.Box(owned: initial)
    canvasView.setFeatureChangeHandler { change in
      change(&box.owned)
      box.emitted.append(box.owned)
    }
    canvasView.areAnimationsEnabled = false
    canvasView.setEditingTarget(.crop)
    canvasView.frame = window.bounds
    window.addSubview(canvasView)
    window.isHidden = false
    canvasView.layoutIfNeeded()
    canvasView.loadFeature()
    canvasView.layoutIfNeeded()

    canvasView.setLockedAspectRatio(.square)
    canvasView.layoutIfNeeded()
    canvasView.applyPendingCrop()

    let topLeftSquare = CGRect(x: 0, y: 0, width: 150, height: 150)
    let undone = makeFeature(topLeftRect: topLeftSquare)
    box.owned = undone
    canvasView.setFeature(undone)
    canvasView.layoutIfNeeded()
    let emittedCount = box.emitted.count
    canvasView.applyPendingCrop()

    #expect(canvasView.proposedCrop?.cropExtent == topLeftSquare)
    #expect(box.emitted.count == emittedCount)
    withExtendedLifetime(window) {}
  }

  @Test func `Switching between tool targets commits nothing`() {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize))

    harness.canvasView.setEditingTarget(nil)
    harness.canvasView.setEditingTarget(.localBlur)

    #expect(harness.emitted.isEmpty)
  }

  /// Records each interaction set the guide hands an overlay.
  private final class RecordingInsideOverlay: EditingCanvasView.CropInsideOverlayBase {
    var received: [CropInteraction] = []

    override func didChangeInteraction(_ interaction: CropInteraction) {
      received.append(interaction)
    }
  }

  /// The crop scroll view's drag and pinch overlap (a pinch starts during a
  /// drag, a finger keeps panning after the pinch ends): the image is moving
  /// until both have ended, including the drag's deceleration.
  @Test func `The image is moving until every scroll gesture has ended`() {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    let canvasView = harness.canvasView
    let overlay = RecordingInsideOverlay()
    canvasView.setCropInsideOverlay(overlay)
    let surface = canvasView.cropSurface
    let scrollView = surface.scrollView

    surface.scrollViewWillBeginDragging(scrollView)
    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    #expect(harness.guides.last?.interaction == .movingImage)

    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    #expect(harness.guides.last?.interaction == .movingImage, "the drag continues after the pinch")

    surface.scrollViewDidEndDragging(scrollView, willDecelerate: true)
    #expect(harness.guides.last?.interaction == .movingImage, "the image decelerates")

    surface.scrollViewDidEndDecelerating(scrollView)
    #expect(harness.guides.last?.interaction == [])

    // The overlay hears each change of the set once.
    #expect(overlay.received == [.movingImage, []])
  }

  /// Reset snaps the image, which ends an image move in progress, and leaves
  /// a guide resize in progress to its own gesture.
  @Test func `Reset ends an image move and keeps a guide resize`() throws {
    let harness = makeLoadedCanvasView(feature: ImageEditorFeature(imageSize: imageSize), target: .crop)
    let canvasView = harness.canvasView
    let surface = canvasView.cropSurface
    let scrollView = surface.scrollView

    surface.scrollViewWillBeginDragging(scrollView)
    canvasView.guideView.insertInteraction(.resizingGuide)
    #expect(harness.guides.last?.interaction == [.movingImage, .resizingGuide])

    canvasView.resetCrop()
    #expect(harness.guides.last?.interaction == .resizingGuide)

    // The drag's late end changes nothing.
    surface.scrollViewDidEndDragging(scrollView, willDecelerate: false)
    #expect(harness.guides.last?.interaction == .resizingGuide)

    canvasView.guideView.removeInteraction(.resizingGuide)
    #expect(harness.guides.last?.interaction == [])
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

/// The SwiftUI coordinator applies a value input (`straightenAngle(_:isEditing:)`,
/// `lockedAspectRatio(_:)`) only when the host's value changes, so a value
/// the host keeps passing never pushes the canvas back after a reset or an
/// undo.
@MainActor
struct EditingCanvasRepresentableValueInputTests {

  private let size = CGSize(width: 80, height: 60)

  private final class Latest {
    var guide: ImageEditorCanvas.CropGuide?
  }

  private func makeLoadedCanvasView(
    straightenDegrees: Double = 0
  ) -> (EditingCanvasView, Latest) {
    var feature = ImageEditorFeature(imageSize: size)
    var crop = CropGuideState(cropFeature: feature.crop, imageSize: size)
    crop.adjustmentAngle = .degrees(straightenDegrees)
    feature.crop = crop.makeCropFeature()
    let canvasView = EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)),
        imageSize: size
      ),
      feature: feature
    )
    let latest = Latest()
    canvasView.setCropGuideHandler { latest.guide = $0 }
    canvasView.setEditingTarget(.crop)
    canvasView.loadFeature()
    return (canvasView, latest)
  }

  @Test func `The aspect-ratio lock takes effect only when the host's value changes`() {
    let (canvasView, latest) = makeLoadedCanvasView()
    let coordinator = EditingCanvasRepresentable.Coordinator()
    let square = AspectRatio(width: 1, height: 1)

    coordinator.applyLockedAspectRatio(square, to: canvasView)
    #expect(latest.guide?.lockedAspectRatio == square)

    // The canvas unlocks the guide itself; the same host value does not
    // lock it again.
    canvasView.resetCrop()
    #expect(latest.guide?.lockedAspectRatio == nil)
    coordinator.applyLockedAspectRatio(square, to: canvasView)
    #expect(latest.guide?.lockedAspectRatio == nil)

    // A changed value does.
    coordinator.applyLockedAspectRatio(nil, to: canvasView)
    coordinator.applyLockedAspectRatio(square, to: canvasView)
    #expect(latest.guide?.lockedAspectRatio == square)
  }

  @Test func `The straighten angle takes effect only when the host's value changes`() throws {
    let (canvasView, _) = makeLoadedCanvasView(straightenDegrees: 10)
    let coordinator = EditingCanvasRepresentable.Coordinator()
    let tilted = ImageEditorCanvas.StraightenAngleInput(angle: .degrees(10), isEditing: false)

    // The host mirrors the loaded angle.
    coordinator.applyStraightenAngle(tilted, to: canvasView)
    #expect(canvasView.proposedCrop?.adjustmentAngle == .degrees(10))

    // An undo reloads a level crop; the host's unchanged angle leaves it.
    canvasView.setFeature(ImageEditorFeature(imageSize: size))
    #expect(canvasView.proposedCrop?.adjustmentAngle == .zero)
    coordinator.applyStraightenAngle(tilted, to: canvasView)
    #expect(canvasView.proposedCrop?.adjustmentAngle == .zero)

    // A changed angle does, and nil leaves the angle alone.
    coordinator.applyStraightenAngle(.init(angle: .degrees(5), isEditing: false), to: canvasView)
    #expect(canvasView.proposedCrop?.adjustmentAngle == .degrees(5))
    coordinator.applyStraightenAngle(.init(angle: nil, isEditing: false), to: canvasView)
    #expect(canvasView.proposedCrop?.adjustmentAngle == .degrees(5))
  }
}

/// `ImageEditorCanvasProxy` sends commands to the canvas an
/// `ImageEditorCanvasReader` registered most recently.
@MainActor
struct ImageEditorCanvasProxyTests {

  private let size = CGSize(width: 80, height: 60)

  private func makeLoadedCanvasView() -> EditingCanvasView {
    let canvasView = EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)),
        imageSize: size
      ),
      feature: ImageEditorFeature(imageSize: size)
    )
    canvasView.setEditingTarget(.crop)
    canvasView.loadFeature()
    return canvasView
  }

  @Test func `Commands before a canvas is mounted do nothing`() {
    let registry = ImageEditorCanvasRegistry()
    let canvas = ImageEditorCanvasProxy(registry: registry)

    canvas.resetCrop()
    canvas.rotateCounterclockwise()
    canvas.applyPendingCrop()
    #expect(registry.canvasView == nil)
  }

  @Test func `Commands go to the most recently mounted canvas`() {
    let registry = ImageEditorCanvasRegistry()
    let canvas = ImageEditorCanvasProxy(registry: registry)
    let first = makeLoadedCanvasView()
    let second = makeLoadedCanvasView()

    registry.register(first)
    registry.register(second)
    // Registering again on an update keeps the mount order.
    registry.register(first)
    #expect(registry.canvasView === second)

    canvas.rotateCounterclockwise()
    #expect(second.proposedCrop?.rotation == .counterclockwise90)
    #expect(first.proposedCrop?.rotation == .zero)

    // When the latest canvas is dismantled, the earlier one receives them.
    registry.unregister(second)
    canvas.rotateCounterclockwise()
    #expect(first.proposedCrop?.rotation == .counterclockwise90)
  }
}
