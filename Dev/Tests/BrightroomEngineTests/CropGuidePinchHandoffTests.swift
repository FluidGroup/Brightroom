import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// A pinch near the crop guide zooms the image and never resizes the guide.
///
/// The guide's handles reach 16 pt past its edges, and a pinch finger often
/// lands there. These tests drive the handles' recognizer decisions and the
/// resize handlers directly: the canvas has no touches in a unit test.
@MainActor
struct CropGuidePinchHandoffTests {

  private let imageSize = CGSize(width: 1200, height: 900)

  final class Owner {
    var feature: ImageEditorFeature
    var emittedCount = 0

    init(_ feature: ImageEditorFeature) {
      self.feature = feature
    }
  }

  /// A handle pan whose state and translation the test sets, standing in for
  /// UIKit's touch handling.
  final class ScriptedHandlePan: EditingCanvasView.HandlePanGestureRecognizer {
    var scriptedState: UIGestureRecognizer.State = .possible
    var scriptedTranslation: CGPoint = .zero

    override var state: UIGestureRecognizer.State {
      get { scriptedState }
      set { scriptedState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint {
      scriptedTranslation
    }

    override func setTranslation(_ translation: CGPoint, in view: UIView?) {
      scriptedTranslation = translation
    }
  }

  /// A pinch whose state the test sets.
  final class ScriptedPinch: UIPinchGestureRecognizer {
    var scriptedState: UIGestureRecognizer.State = .possible

    override var state: UIGestureRecognizer.State {
      get { scriptedState }
      set { scriptedState = newValue }
    }
  }

  private func openCanvas() -> (EditingCanvasView, UIWindow, Owner) {
    let feature = ImageEditorFeature(imageSize: imageSize)
    let owner = Owner(feature)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let view = EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize)),
        imageSize: imageSize
      ),
      feature: feature
    )
    view.setFeatureChangeHandler { change in
      change(&owner.feature)
      owner.emittedCount += 1
    }
    view.areAnimationsEnabled = false
    view.frame = window.bounds
    window.addSubview(view)
    window.isHidden = false
    view.setEditingTarget(.crop)
    view.layoutIfNeeded()
    view.loadFeature()
    view.layoutIfNeeded()
    return (view, window, owner)
  }

  /// Drags the right edge 70 pt inward with one finger, leaving the resize
  /// in progress.
  private func beginResizingRightEdge(
    of view: EditingCanvasView,
    with pan: ScriptedHandlePan
  ) {
    let guide = view.guideView
    pan.scriptedState = .began
    pan.scriptedTranslation = CGPoint(x: -40, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    pan.scriptedState = .changed
    pan.scriptedTranslation = CGPoint(x: -30, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    view.layoutIfNeeded()
  }

  private func expectSameCrop(
    _ crop: CropGuideState,
    _ expected: CropGuideState,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let rect = crop.cropExtent
    let expectedRect = expected.cropExtent
    for (value, expectedValue) in [
      (rect.minX, expectedRect.minX),
      (rect.minY, expectedRect.minY),
      (rect.width, expectedRect.width),
      (rect.height, expectedRect.height),
    ] {
      #expect(abs(value - expectedValue) < 1, "\(rect) vs \(expectedRect)", sourceLocation: sourceLocation)
    }
  }

  /// Waits past the scroll settle (0.2 s) and the trailing layout (0.8 s).
  private func waitForSettleAndLayout(_ view: EditingCanvasView) async throws {
    try await Task.sleep(for: .milliseconds(1300))
    view.layoutIfNeeded()
  }

  // MARK: - The pinch reaches a finger on a handle

  @Test
  func `the canvas carries the crop pinch, above the guide's handles`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }

    let pinch = try #require(view.cropSurface.scrollView.pinchGestureRecognizer)
    #expect(pinch.view === view)
    #expect(view.adoptedCropPinchGestureRecognizer === pinch)
    #expect(view.guideView.imageZoomGestureRecognizer === pinch)
    #expect(pinch.isEnabled)

    let handlePans = view.guideView.handlePanGestureRecognizers
    #expect(handlePans.count == 8)
    for handlePan in handlePans {
      let handleView = try #require(handlePan.view)
      // A touch reaches the recognizers of its view and that view's ancestors.
      #expect(handleView.isDescendant(of: view))
      #expect(handleView.isDescendant(of: view.cropSurface.scrollView) == false)
    }
  }

  @Test
  func `the canvas follows the pinch UIScrollView replaces and leaves no stale one`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }

    func expectCanvasCarriesOnlyTheCurrentPinch() {
      let current = view.cropSurface.scrollView.pinchGestureRecognizer
      let carried = (view.gestureRecognizers ?? []).filter { $0 is UIPinchGestureRecognizer }
      #expect(carried.count == (current == nil ? 0 : 1))
      if let current {
        #expect(carried.first === current)
        #expect(current.view === view)
      }
      #expect(view.guideView.imageZoomGestureRecognizer === current)
    }

    let original = try #require(view.cropSurface.scrollView.pinchGestureRecognizer)

    // Equal minimum and maximum zoom scales make UIScrollView drop its pinch.
    view.isZoomEnabled = false
    view.layoutIfNeeded()
    expectCanvasCarriesOnlyTheCurrentPinch()

    view.isZoomEnabled = true
    view.layoutIfNeeded()
    expectCanvasCarriesOnlyTheCurrentPinch()
    let replacement = try #require(view.cropSurface.scrollView.pinchGestureRecognizer)
    #expect(replacement.isEnabled)
    if original !== replacement {
      #expect(original.view !== view)
    }
  }

  @Test
  func `the carried pinch is off while the crop is not the editing target`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }

    view.setEditingTarget(nil)
    view.layoutIfNeeded()
    let pinch = try #require(view.adoptedCropPinchGestureRecognizer)
    #expect(pinch.isEnabled == false)

    view.setEditingTarget(.crop)
    view.layoutIfNeeded()
    #expect(view.adoptedCropPinchGestureRecognizer?.isEnabled == true)
  }

  // MARK: - Delegate decisions

  @Test
  func `a handle starts a resize only with one finger down and no pinch`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }
    let guide = view.guideView

    for handlePan in guide.handlePanGestureRecognizers {
      #expect(guide.gestureRecognizerShouldBegin(handlePan))
    }

    let oneFinger = EditingCanvasView.HandlePanGestureRecognizer(target: nil, action: nil)
    oneFinger.noteActiveTouchCount(1)
    #expect(oneFinger.state == .possible)
    #expect(guide.gestureRecognizerShouldBegin(oneFinger))

    let twoFingers = ScriptedHandlePan(target: nil, action: nil)
    twoFingers.noteActiveTouchCount(2)
    #expect(twoFingers.state == .failed)
    #expect(guide.gestureRecognizerShouldBegin(twoFingers) == false)

    let carried = guide.imageZoomGestureRecognizer
    defer { guide.imageZoomGestureRecognizer = carried }
    let pinch = ScriptedPinch(target: nil, action: nil)
    guide.imageZoomGestureRecognizer = pinch
    let handlePan = try #require(guide.handlePanGestureRecognizers.first)

    for (state, allowsResize) in [
      (UIGestureRecognizer.State.possible, true),
      (.began, false),
      (.changed, false),
      (.ended, true),
      (.cancelled, true),
      (.failed, true),
    ] {
      pinch.scriptedState = state
      #expect(
        guide.gestureRecognizerShouldBegin(handlePan) == allowsResize,
        "pinch state \(state.rawValue)"
      )
    }
  }

  /// A touch whose view and phase the test sets.
  final class ScriptedTouch: UITouch {
    let scriptedView: UIView
    let scriptedPhase: UITouch.Phase

    init(on view: UIView, phase: UITouch.Phase = .moved) {
      self.scriptedView = view
      self.scriptedPhase = phase
      super.init()
    }

    override var view: UIView? { scriptedView }
    override var phase: UITouch.Phase { scriptedPhase }
  }

  /// A finger resting outside the canvas (on the straighten ruler or a
  /// toolbar) cannot join a pinch, so a one-finger resize still runs.
  @Test
  func `a handle counts only the touches over the canvas`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }
    let guide = view.guideView
    let outside = UIView(frame: CGRect(x: 0, y: 650, width: 390, height: 50))
    window.addSubview(outside)

    for handlePan in guide.handlePanGestureRecognizers {
      #expect(handlePan.touchRegion === view)
    }
    let handle = try #require(guide.handlePanGestureRecognizers.first?.view)
    let own = ScriptedTouch(on: handle)
    let count = EditingCanvasView.HandlePanGestureRecognizer.activeTouchCount

    #expect(count([own, ScriptedTouch(on: outside)], view) == 1)
    #expect(count([own, ScriptedTouch(on: view.cropSurface.scrollView)], view) == 2)
    #expect(count([own, ScriptedTouch(on: view.cropSurface.scrollView, phase: .ended)], view) == 1)
    #expect(count([own, ScriptedTouch(on: outside)], nil) == 2)
  }

  @Test
  func `a handle pan lets the crop pinch recognize alongside it, and nothing else`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }
    let guide = view.guideView

    let pinch = try #require(view.cropSurface.scrollView.pinchGestureRecognizer)
    for handlePan in guide.handlePanGestureRecognizers {
      #expect(guide.gestureRecognizer(handlePan, shouldRecognizeSimultaneouslyWith: pinch))
      #expect(
        guide.gestureRecognizer(
          handlePan,
          shouldRecognizeSimultaneouslyWith: view.cropSurface.scrollView.panGestureRecognizer
        ) == false
      )
    }
    let first = try #require(guide.handlePanGestureRecognizers.first)
    let last = try #require(guide.handlePanGestureRecognizers.last)
    #expect(guide.gestureRecognizer(first, shouldRecognizeSimultaneouslyWith: last) == false)
  }

  @Test
  func `the guide leaves another view's recognizer to begin on its own`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }
    let guide = view.guideView
    let pan = ScriptedHandlePan(target: nil, action: nil)
    beginResizingRightEdge(of: view, with: pan)
    defer {
      guide.cancelResizing()
    }

    // While a handle resizes, the crop pinch is still allowed to begin.
    let pinch = try #require(view.cropSurface.scrollView.pinchGestureRecognizer)
    #expect(guide.gestureRecognizerShouldBegin(pinch))
  }

  // MARK: - Cancel and restore

  @Test
  func `a pinch that begins during a resize puts the guide back and records nothing`() async throws {
    let (view, window, owner) = openCanvas()
    defer { window.isHidden = true }
    let guide = view.guideView
    let frameBefore = guide.frame
    let cropBefore = try #require(view.proposedCrop)

    let pan = ScriptedHandlePan(target: nil, action: nil)
    beginResizingRightEdge(of: view, with: pan)
    #expect(guide.frame.width < frameBefore.width - 60)
    #expect(guide.interaction.contains(.resizingGuide))

    // The crop scroll view reports the pinch's begin.
    view.cropSurface.onWillBeginZooming?()
    #expect(guide.frame == frameBefore)
    #expect(guide.interaction.contains(.resizingGuide) == false)

    // UIKit then delivers the cancelled pan's end, which records nothing.
    pan.scriptedState = .cancelled
    guide.handlePanGestureInRight(gesture: pan)
    #expect(guide.frame == frameBefore)

    view.cropSurface.onDidEndZooming?(view.cropSurface.scrollView.zoomScale)
    try await waitForSettleAndLayout(view)

    // The zoom's settle records the guide as the scroll view shows it, which
    // can differ from the stored crop by a fraction of a pixel; the dropped
    // resize would have taken 70 pt off the width.
    expectSameCrop(try #require(view.proposedCrop), cropBefore)
    #expect(guide.frame == frameBefore)
    #expect(owner.emittedCount == 0)
  }

  /// A guide overlay that records each interaction it is told about.
  final class RecordingOverlay: EditingCanvasView.CropInsideOverlayBase {
    var received: [CropInteraction] = []

    override func didChangeInteraction(_ interaction: CropInteraction) {
      received.append(interaction)
    }
  }

  /// The host and the guide's overlays hear idle only once every crop
  /// interaction has ended: a pinch that takes over a resize goes from
  /// resizing to moving the image without an idle value between.
  @Test
  func `a pinch that takes over a resize never reports idle in between`() throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }
    var reported: [CropInteraction] = []
    view.setCropGuideHandler { guide in
      if reported.last != guide.interaction {
        reported.append(guide.interaction)
      }
    }
    let overlay = RecordingOverlay()
    view.setCropInsideOverlay(overlay)

    let pan = ScriptedHandlePan(target: nil, action: nil)
    beginResizingRightEdge(of: view, with: pan)
    let overlayBefore = overlay.received.count
    view.cropSurface.onWillBeginZooming?()

    #expect(view.guideView.interaction == .movingImage)
    #expect(reported.last == .movingImage)
    #expect(reported.dropFirst().contains([]) == false, "host: \(reported.map(\.rawValue))")
    #expect(
      overlay.received.dropFirst(overlayBefore).contains([]) == false,
      "overlay: \(overlay.received.map(\.rawValue))"
    )

    view.cropSurface.onDidEndZooming?(view.cropSurface.scrollView.zoomScale)
    #expect(view.guideView.interaction == [])
  }

  @Test
  func `a second finger during a resize puts the guide back and records nothing`() async throws {
    let (view, window, owner) = openCanvas()
    defer { window.isHidden = true }
    let guide = view.guideView
    let frameBefore = guide.frame
    let cropBefore = try #require(view.proposedCrop)

    let pan = ScriptedHandlePan(target: nil, action: nil)
    // The guide's own wiring for its handles.
    pan.onAdditionalTouch = try #require(guide.handlePanGestureRecognizers.first).onAdditionalTouch
    beginResizingRightEdge(of: view, with: pan)
    #expect(guide.frame.width < frameBefore.width - 60)

    pan.noteActiveTouchCount(2)
    #expect(pan.state == .cancelled)
    #expect(guide.frame == frameBefore)
    #expect(guide.interaction.contains(.resizingGuide) == false)

    guide.handlePanGestureInRight(gesture: pan)
    try await waitForSettleAndLayout(view)

    expectSameCrop(try #require(view.proposedCrop), cropBefore)
    #expect(guide.frame == frameBefore)
    #expect(owner.emittedCount == 0)
  }

  /// With animations on, a dropped resize eases the guide back from where
  /// the finger left it instead of jumping; with them off, it goes back at
  /// once. Either way its frame is the one from before the drag.
  @Test(arguments: [true, false])
  func `a dropped resize animates the guide back when animations are on`(animates: Bool) throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }
    view.areAnimationsEnabled = animates
    let guide = view.guideView
    let frameBefore = guide.frame

    let pan = ScriptedHandlePan(target: nil, action: nil)
    beginResizingRightEdge(of: view, with: pan)
    #expect(guide.frame.width < frameBefore.width - 60)
    guide.layer.removeAllAnimations()

    view.cropSurface.onWillBeginZooming?()

    #expect(guide.frame == frameBefore)
    let animationKeys = guide.layer.animationKeys() ?? []
    #expect(animationKeys.isEmpty != animates, "\(animationKeys)")
    view.cropSurface.onDidEndZooming?(view.cropSurface.scrollView.zoomScale)
  }

  @Test
  func `one finger still resizes the guide and records the crop`() async throws {
    let (view, window, _) = openCanvas()
    defer { window.isHidden = true }
    let guide = view.guideView
    let frameBefore = guide.frame
    let cropBefore = try #require(view.proposedCrop)

    let pan = ScriptedHandlePan(target: nil, action: nil)
    pan.onAdditionalTouch = try #require(guide.handlePanGestureRecognizers.first).onAdditionalTouch
    beginResizingRightEdge(of: view, with: pan)
    pan.noteActiveTouchCount(1)
    #expect(pan.state == .changed)

    pan.scriptedState = .ended
    pan.scriptedTranslation = .zero
    guide.handlePanGestureInRight(gesture: pan)
    #expect(guide.frame.width < frameBefore.width - 60)
    #expect(guide.interaction.contains(.resizingGuide) == false)

    try await waitForSettleAndLayout(view)

    let cropAfter = try #require(view.proposedCrop)
    // 70 pt of the guide's width, in image pixels.
    let expectedWidth = cropBefore.cropExtent.width * (frameBefore.width - 70) / frameBefore.width
    #expect(abs(cropAfter.cropExtent.width - expectedWidth) < 2)
    #expect(abs(cropAfter.cropExtent.minX - cropBefore.cropExtent.minX) < 1)
    #expect(abs(cropAfter.cropExtent.height - cropBefore.cropExtent.height) < 1)
  }
}
