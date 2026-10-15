import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// The crop scroll view lays out only after its settle records the crop.
///
/// A layout moves the scroll view to the recorded crop. Run before the
/// settle records a zoom or a pan, it moves the image back to the crop from
/// before the gesture. These tests call the scroll view's delegate the way
/// UIKit does and hold the settle back the way a zoom bounce, a long
/// deceleration, or a rest outside the scroll range does.
@MainActor
struct CropScrollSettleLayoutTests {

  private let imageSize = CGSize(width: 1200, height: 900)

  final class Owner {
    var feature: ImageEditorFeature
    var emittedCount = 0

    init(_ feature: ImageEditorFeature) {
      self.feature = feature
    }
  }

  /// A handle pan whose state and translation the test sets.
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

  static let locks: [AspectRatio?] = [nil, .square, AspectRatio(width: 4, height: 5)]

  private func openCanvas(lock: AspectRatio?) -> (EditingCanvasView, UIWindow, Owner) {
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
    if let lock {
      view.setLockedAspectRatio(lock)
      view.layoutIfNeeded()
    }
    return (view, window, owner)
  }

  private func maxContentOffset(_ scrollView: UIScrollView) -> CGPoint {
    CGPoint(
      x: scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right,
      y: scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
    )
  }

  private func clampedContentOffset(_ offset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
    let maxOffset = maxContentOffset(scrollView)
    return CGPoint(
      x: min(max(offset.x, -scrollView.contentInset.left), maxOffset.x),
      y: min(max(offset.y, -scrollView.contentInset.top), maxOffset.y)
    )
  }

  /// Zooms by `factor` about a point 10 pt inside the guide's right edge,
  /// as a pinch there does, and keeps the offset in the scroll range.
  private func zoomTowardRightEdge(_ view: EditingCanvasView, by factor: CGFloat) {
    let scrollView = view.cropSurface.scrollView
    let guide = view.guideView.convert(view.guideView.bounds, to: scrollView)
    let anchor = CGPoint(
      x: guide.maxX - 10 - scrollView.bounds.minX,
      y: guide.midY - scrollView.bounds.minY
    )
    let content = CGPoint(
      x: (scrollView.contentOffset.x + anchor.x) / scrollView.zoomScale,
      y: (scrollView.contentOffset.y + anchor.y) / scrollView.zoomScale
    )
    scrollView.setZoomScale(scrollView.zoomScale * factor, animated: false)
    scrollView.contentOffset = clampedContentOffset(
      CGPoint(
        x: content.x * scrollView.zoomScale - anchor.x,
        y: content.y * scrollView.zoomScale - anchor.y
      ),
      in: scrollView
    )
  }

  /// Image pixels per point of the guide, for the stored crop.
  private func pixelsPerGuidePoint(_ view: EditingCanvasView) throws -> CGFloat {
    let crop = try #require(view.proposedCrop)
    return crop.cropExtent.width / view.guideView.bounds.width
  }

  /// Past the scroll settle (0.2 s) but short of the guide's layout delay
  /// (0.8 s).
  private func waitForSettle() async throws {
    try await Task.sleep(for: .milliseconds(400))
  }

  /// Past the guide's layout delay (0.8 s) from now.
  private func waitPastLayoutDelay(_ view: EditingCanvasView) async throws {
    try await Task.sleep(for: .milliseconds(1100))
    view.layoutIfNeeded()
  }

  // MARK: - Zoom

  @Test(arguments: [nil, AspectRatio.square] as [AspectRatio?])
  func `a zoom that rests past the scroll range keeps the zoom`(lock: AspectRatio?) async throws {
    let (view, window, owner) = openCanvas(lock: lock)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    let cropBefore = try #require(view.proposedCrop)
    let zoomBefore = scrollView.zoomScale

    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    zoomTowardRightEdge(view, by: 2)
    // A rest UIKit does not bounce back, as after a below-minimum pinch
    // whose bounce left the offset where a stale content size allowed it.
    scrollView.contentOffset.x = maxContentOffset(scrollView).x + 20
    let zoomAtRelease = scrollView.zoomScale
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: zoomAtRelease)

    try await waitPastLayoutDelay(view)
    try await waitPastLayoutDelay(view)

    // Before, the settle waited for the offset to come back into range, and
    // the layout scheduled by the zoom ran first and zoomed back out to the
    // crop from before the pinch.
    #expect(scrollView.zoomScale > zoomBefore * 1.8, "zoom \(zoomBefore) → \(scrollView.zoomScale)")
    #expect(abs(scrollView.zoomScale - zoomAtRelease) < zoomAtRelease * 0.1)
    let cropAfter = try #require(view.proposedCrop)
    #expect(
      cropAfter.cropExtent.width < cropBefore.cropExtent.width * 0.6,
      "\(cropBefore.cropExtent) → \(cropAfter.cropExtent), zoom \(zoomAtRelease) → \(scrollView.zoomScale), offset \(scrollView.contentOffset), max \(maxContentOffset(scrollView))"
    )
    #expect(owner.emittedCount == 0)
  }

  @Test(arguments: locks)
  func `a zoom to the edge keeps its crop and nothing moves after it settles`(lock: AspectRatio?) async throws {
    let (view, window, _) = openCanvas(lock: lock)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    let cropBefore = try #require(view.proposedCrop)

    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    zoomTowardRightEdge(view, by: 2)
    scrollView.contentOffset.x = maxContentOffset(scrollView).x
    let zoomAtRelease = scrollView.zoomScale
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: zoomAtRelease)

    try await waitForSettle()
    let zoomAtSettle = scrollView.zoomScale
    let offsetAtSettle = scrollView.contentOffset
    let cropAtSettle = try #require(view.proposedCrop)

    try await waitPastLayoutDelay(view)

    #expect(abs(scrollView.zoomScale - zoomAtSettle) <= 1e-4)
    #expect(abs(scrollView.contentOffset.x - offsetAtSettle.x) <= 0.5)
    #expect(abs(scrollView.contentOffset.y - offsetAtSettle.y) <= 0.5)
    #expect(view.proposedCrop == cropAtSettle)

    // The recorded crop is the guide at the zoom the pinch left: half the
    // size, against the right edge, with the locked ratio.
    let rect = cropAtSettle.cropExtent
    #expect(abs(zoomAtSettle - zoomAtRelease) < zoomAtRelease * 0.005)
    #expect(abs(rect.width - cropBefore.cropExtent.width / 2) < 2, "\(rect)")
    #expect(abs(rect.height - cropBefore.cropExtent.height / 2) < 2, "\(rect)")
    #expect(abs(rect.maxX - imageSize.width) < 1, "\(rect)")
    if let lock {
      #expect(abs(rect.width / rect.height - lock.width / lock.height) < 0.01, "\(rect)")
    }
  }

  // MARK: - Pan

  @Test(arguments: locks)
  func `a pan whose settle waits past the layout delay keeps the pan`(lock: AspectRatio?) async throws {
    let (view, window, _) = openCanvas(lock: lock)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView

    // Zoom in about the guide's centre so the image can pan both ways.
    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    let guide = view.guideView.convert(view.guideView.bounds, to: scrollView)
    let content = CGPoint(
      x: (scrollView.contentOffset.x + guide.midX - scrollView.bounds.minX) / scrollView.zoomScale,
      y: (scrollView.contentOffset.y + guide.midY - scrollView.bounds.minY) / scrollView.zoomScale
    )
    scrollView.setZoomScale(scrollView.zoomScale * 2, animated: false)
    scrollView.contentOffset = clampedContentOffset(
      CGPoint(
        x: content.x * scrollView.zoomScale - (guide.midX - scrollView.bounds.minX),
        y: content.y * scrollView.zoomScale - (guide.midY - scrollView.bounds.minY)
      ),
      in: scrollView
    )
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await waitForSettle()

    let cropBeforePan = try #require(view.proposedCrop)
    let pixelsPerPoint = try pixelsPerGuidePoint(view)
    let zoomBeforePan = scrollView.zoomScale

    // A flick toward the left edge of the image: the deceleration outlasts
    // the layout delay after its last reported scroll.
    surface.scrollViewWillBeginDragging(scrollView)
    scrollView.contentOffset.x -= 40
    let offsetAfterPan = scrollView.contentOffset
    #expect(offsetAfterPan.x >= -scrollView.contentInset.left, "the pan stays in the scroll range")
    surface.scrollViewDidEndDragging(scrollView, willDecelerate: true)
    try await waitPastLayoutDelay(view)

    #expect(abs(scrollView.contentOffset.x - offsetAfterPan.x) <= 0.5, "the pan was undone before it was recorded")
    #expect(scrollView.zoomScale == zoomBeforePan)

    surface.scrollViewDidEndDecelerating(scrollView)
    try await waitForSettle()
    let offsetAtSettle = scrollView.contentOffset
    try await waitPastLayoutDelay(view)

    let cropAfter = try #require(view.proposedCrop)
    let shift = cropAfter.cropExtent.minX - cropBeforePan.cropExtent.minX
    #expect(
      abs(shift + 40 * pixelsPerPoint) < 1,
      "shift \(shift), expected \(-40 * pixelsPerPoint): \(cropBeforePan.cropExtent) → \(cropAfter.cropExtent)"
    )
    #expect(abs(cropAfter.cropExtent.width - cropBeforePan.cropExtent.width) < 1)
    #expect(abs(cropAfter.cropExtent.minY - cropBeforePan.cropExtent.minY) < 1)
    #expect(abs(scrollView.contentOffset.x - offsetAtSettle.x) <= 0.5)
    #expect(abs(scrollView.contentOffset.y - offsetAtSettle.y) <= 0.5)
    #expect(abs(scrollView.zoomScale - zoomBeforePan) <= 1e-4)
  }

  /// How the host applies the crop.
  enum CropApplication: String, CaseIterable, Sendable {
    /// Switching the editing target away from the crop.
    case leavingCrop
    /// `applyPendingCrop()` while crop editing, as Done does.
    case applyingPendingCrop
  }

  /// A flick whose deceleration is still running when the crop is applied
  /// writes the crop the flick left on screen. The settle that would have
  /// recorded it runs later and records nothing once the crop is no longer
  /// the editing target.
  @Test(arguments: locks, CropApplication.allCases)
  func `a pan applied before its settle is written as on screen`(
    lock: AspectRatio?,
    application: CropApplication
  ) async throws {
    let (view, window, owner) = openCanvas(lock: lock)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView

    // Zoom in about the guide's centre so the image can pan both ways.
    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    let guide = view.guideView.convert(view.guideView.bounds, to: scrollView)
    let content = CGPoint(
      x: (scrollView.contentOffset.x + guide.midX - scrollView.bounds.minX) / scrollView.zoomScale,
      y: (scrollView.contentOffset.y + guide.midY - scrollView.bounds.minY) / scrollView.zoomScale
    )
    scrollView.setZoomScale(scrollView.zoomScale * 2, animated: false)
    scrollView.contentOffset = clampedContentOffset(
      CGPoint(
        x: content.x * scrollView.zoomScale - (guide.midX - scrollView.bounds.minX),
        y: content.y * scrollView.zoomScale - (guide.midY - scrollView.bounds.minY)
      ),
      in: scrollView
    )
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await waitForSettle()

    let cropBeforePan = try #require(view.proposedCrop)
    let pixelsPerPoint = try pixelsPerGuidePoint(view)
    #expect(owner.emittedCount == 0)

    surface.scrollViewWillBeginDragging(scrollView)
    scrollView.contentOffset.x -= 40
    surface.scrollViewDidEndDragging(scrollView, willDecelerate: true)
    switch application {
    case .leavingCrop:
      view.setEditingTarget(.localBlur)
    case .applyingPendingCrop:
      view.applyPendingCrop()
    }

    #expect(owner.emittedCount == 1)
    let written = owner.feature.crop.topLeftRect(imageSize: imageSize)
    let expected = cropBeforePan.cropExtent.offsetBy(dx: -40 * pixelsPerPoint, dy: 0)
    if let lock {
      // Under a lock, the written crop is the largest whole multiple of the
      // ratio's terms inside the guide, centered on it within half a pixel.
      let terms = try #require(PixelAlignedCrop.exactTerms(of: lock))
      let largestTerm = CGFloat(max(terms.width, terms.height))
      #expect(abs(written.midX - expected.midX) <= 0.5 + 1e-6, "\(expected) → \(written)")
      #expect(abs(written.midY - expected.midY) <= 0.5 + 1e-6, "\(expected) → \(written)")
      #expect(written.width <= expected.width + 1e-6 && written.width > expected.width - largestTerm, "\(expected) → \(written)")
      #expect(written.height <= expected.height + 1e-6 && written.height > expected.height - largestTerm, "\(expected) → \(written)")
      #expect(written.width * lock.height == written.height * lock.width, "\(written)")
    } else {
      // The written crop is rounded inward to whole pixels.
      #expect(written.minX >= expected.minX - 1e-6 && written.minX < expected.minX + 1, "\(expected) → \(written)")
      #expect(written.maxX <= expected.maxX + 1e-6 && written.maxX > expected.maxX - 1, "\(expected) → \(written)")
      #expect(written.minY >= expected.minY - 1e-6 && written.minY < expected.minY + 1, "\(expected) → \(written)")
      #expect(written.maxY <= expected.maxY + 1e-6 && written.maxY > expected.maxY - 1, "\(expected) → \(written)")
    }

    // UIKit ends the deceleration later; nothing more is recorded or written.
    surface.scrollViewDidEndDecelerating(scrollView)
    let cropAfterApply = try #require(view.proposedCrop)
    try await waitPastLayoutDelay(view)
    #expect(view.proposedCrop == cropAfterApply)
    #expect(owner.emittedCount == 1)
  }

  // MARK: - Guide resize, then a pan

  @Test
  func `a pan right after a guide resize lays out when it settles, not before`() async throws {
    let (view, window, _) = openCanvas(lock: nil)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    let guide = view.guideView

    // Pull the right edge 70 pt in with one finger and lift it. The guide
    // keeps its new frame until the layout after the guide's delay.
    let pan = ScriptedHandlePan(target: nil, action: nil)
    pan.scriptedState = .began
    pan.scriptedTranslation = CGPoint(x: -40, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    pan.scriptedState = .changed
    pan.scriptedTranslation = CGPoint(x: -30, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    view.layoutIfNeeded()
    pan.scriptedState = .ended
    pan.scriptedTranslation = .zero
    guide.handlePanGestureInRight(gesture: pan)

    let resizedGuideFrame = guide.frame
    let resizedCrop = try #require(view.proposedCrop)
    try #require(resizedCrop.cropExtent.width < imageSize.width - 100)

    // Before that layout runs, the image is dragged 20 pt past the edge of
    // the scroll range and bounces back, and the bounce outlasts the delay.
    surface.scrollViewWillBeginDragging(scrollView)
    let offsetBeforePan = scrollView.contentOffset
    scrollView.contentOffset.x += 20
    surface.scrollViewDidEndDragging(scrollView, willDecelerate: true)
    scrollView.contentOffset = offsetBeforePan
    try await waitPastLayoutDelay(view)

    #expect(guide.frame == resizedGuideFrame, "laid out before the pan was recorded")

    surface.scrollViewDidEndDecelerating(scrollView)
    try await waitForSettle()
    view.layoutIfNeeded()

    // The settle records the crop, then lays out once, without waiting for
    // another delay: the guide grows back to fill the canvas.
    let cropAfter = try #require(view.proposedCrop)
    #expect(abs(cropAfter.cropExtent.minX - resizedCrop.cropExtent.minX) < 1, "\(resizedCrop.cropExtent) → \(cropAfter.cropExtent)")
    #expect(abs(cropAfter.cropExtent.width - resizedCrop.cropExtent.width) < 1, "\(resizedCrop.cropExtent) → \(cropAfter.cropExtent)")
    #expect(guide.frame != resizedGuideFrame)
    #expect(
      abs(guide.frame.width / guide.frame.height - cropAfter.cropExtent.width / cropAfter.cropExtent.height) < 0.01,
      "\(guide.frame) for \(cropAfter.cropExtent)"
    )
  }
}
