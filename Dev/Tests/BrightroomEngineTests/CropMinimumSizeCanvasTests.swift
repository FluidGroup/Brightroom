import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// A crop below ImageEditor's minimum crop size (128 pixels on the shorter
/// output side, or the image's shorter side when the image is smaller), such
/// as one a host set, is shown exactly and never rewritten on load; the
/// first gesture that records it grows it to the minimum about its center.
///
/// The crop scroll view's maximum zoom stops at the minimum, so it used to
/// show a larger area than such a crop, and a mere pan grew the crop to that
/// area. A guide drag stops at the minimum (at the smallest crop a lock
/// writes), not only at the guide's 80-point floor, so nothing grows after
/// the finger lifts. These tests host the canvas in a 390×700 window and call the
/// scroll view's delegate and the guide's handle handlers the way UIKit
/// does.
@MainActor
struct CropMinimumSizeCanvasTests {

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

  /// A window that records the constraints Auto Layout breaks because the
  /// required ones cannot all hold. UIKit tells the engine's delegate, the
  /// window, before it breaks one (and logs "Unable to simultaneously
  /// satisfy constraints").
  final class ConflictRecordingWindow: UIWindow {
    var brokenConstraints: [NSLayoutConstraint] = []

    @objc(engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:)
    func engine(
      _ engine: AnyObject,
      willBreakConstraint constraint: NSLayoutConstraint,
      dueToMutuallyExclusiveConstraints constraints: [NSLayoutConstraint]
    ) {
      brokenConstraints.append(constraint)
    }
  }

  nonisolated static let largeImage = CGSize(width: 1200, height: 900)

  /// The guide's smallest size on screen, whatever the zoom.
  static let guideFloor = CGSize(width: 80, height: 80)

  private func openCanvas(
    imageSize: CGSize = Self.largeImage,
    crop topLeftRect: CGRect?,
    lock: AspectRatio? = nil
  ) -> (EditingCanvasView, ConflictRecordingWindow, Owner) {
    var feature = ImageEditorFeature(imageSize: imageSize)
    if let topLeftRect {
      feature.crop = CropFeature(topLeftRect: topLeftRect, imageSize: imageSize)
    }
    let owner = Owner(feature)
    let window = ConflictRecordingWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let view = EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize)),
        imageSize: imageSize
      ),
      feature: feature
    )
    view.setCropGuideHandler { _ in }
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
      // As a `.fixed` editor applies its lock after loading the document.
      EditingCanvasRepresentable.Coordinator().applyLockedAspectRatio(lock, to: view)
      view.layoutIfNeeded()
    }
    return (view, window, owner)
  }

  /// The guide's size in image pixels at the scroll view's current zoom.
  private func guideSizeInImage(_ view: EditingCanvasView) throws -> CGSize {
    let crop = try #require(view.proposedCrop)
    let pixelsPerPoint = 1 / (view.cropSurface.scrollView.zoomScale * crop.imageToPlatterScale())
    return CGSize(
      width: view.guideView.bounds.width * pixelsPerPoint,
      height: view.guideView.bounds.height * pixelsPerPoint
    )
  }

  /// The maximum zoom that keeps a crop at the minimum size.
  private func usualMaximumZoom(_ view: EditingCanvasView) throws -> CGFloat {
    let crop = try #require(view.proposedCrop)
    return crop.calculateZoomScale(
      visibleSize: view.guideView.bounds
        .applying(CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians))
        .size,
      guideSize: view.guideView.bounds.size
    ).max
  }

  /// Past the scroll settle (0.2 s) and the guide's layout delay (0.8 s).
  private func waitForSettleAndLayout(_ view: EditingCanvasView) async throws {
    try await Task.sleep(for: .milliseconds(1100))
    view.layoutIfNeeded()
  }

  /// Image pixels per point at the crop scroll view's current zoom.
  private func pixelsPerPoint(_ view: EditingCanvasView) throws -> CGFloat {
    let crop = try #require(view.proposedCrop)
    return 1 / (view.cropSurface.scrollView.zoomScale * crop.imageToPlatterScale())
  }

  /// Drags the image by `translation` points and lets it settle, as a
  /// one-finger pan without deceleration does.
  private func pan(_ view: EditingCanvasView, by translation: CGPoint) async throws {
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    surface.scrollViewWillBeginDragging(scrollView)
    scrollView.contentOffset = CGPoint(
      x: scrollView.contentOffset.x - translation.x,
      y: scrollView.contentOffset.y - translation.y
    )
    surface.scrollViewDidEndDragging(scrollView, willDecelerate: false)
    try await waitForSettleAndLayout(view)
  }

  /// Zooms by `factor` about the guide's center and lets it settle.
  private func zoom(_ view: EditingCanvasView, by factor: CGFloat) async throws {
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    let guide = view.guideView.convert(view.guideView.bounds, to: scrollView)
    let anchor = CGPoint(x: guide.midX - scrollView.bounds.minX, y: guide.midY - scrollView.bounds.minY)
    let content = CGPoint(
      x: (scrollView.contentOffset.x + anchor.x) / scrollView.zoomScale,
      y: (scrollView.contentOffset.y + anchor.y) / scrollView.zoomScale
    )
    scrollView.setZoomScale(scrollView.zoomScale * factor, animated: false)
    scrollView.contentOffset = CGPoint(
      x: content.x * scrollView.zoomScale - anchor.x,
      y: content.y * scrollView.zoomScale - anchor.y
    )
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await waitForSettleAndLayout(view)
  }

  /// The recorded crop is `expectedSize` (a side that reached the minimum
  /// keeps its length) about `expectedCenter`, within half a pixel on a
  /// grown side; the crop written from it has the same sides; and after
  /// the layout the guide shows exactly it at the usual maximum zoom.
  private func expectRecordedAtMinimum(
    _ view: EditingCanvasView,
    owner: Owner,
    original: CGRect,
    expectedSize: CGSize,
    expectedCenter: CGPoint,
    imageSize: CGSize = Self.largeImage,
    _ name: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let recorded = try #require(view.proposedCrop, sourceLocation: sourceLocation).cropExtent
    let description = "\(name): recorded \(recorded)"
    let grows = (width: expectedSize.width != original.width, height: expectedSize.height != original.height)

    #expect(abs(recorded.width - expectedSize.width) < 1e-6, "\(description)", sourceLocation: sourceLocation)
    #expect(abs(recorded.height - expectedSize.height) < 1e-6, "\(description)", sourceLocation: sourceLocation)
    #expect(
      abs(recorded.midX - expectedCenter.x) <= (grows.width ? 0.5 : 0) + 1e-6,
      "\(description), center x \(expectedCenter.x)",
      sourceLocation: sourceLocation
    )
    #expect(
      abs(recorded.midY - expectedCenter.y) <= (grows.height ? 0.5 : 0) + 1e-6,
      "\(description), center y \(expectedCenter.y)",
      sourceLocation: sourceLocation
    )

    // The layout after the record shows the grown crop, at the usual range.
    let guide = try guideSizeInImage(view)
    #expect(abs(guide.width - recorded.width) < 1e-6, "\(description), guide \(guide)", sourceLocation: sourceLocation)
    #expect(abs(guide.height - recorded.height) < 1e-6, "\(description), guide \(guide)", sourceLocation: sourceLocation)
    let usualMaximum = try usualMaximumZoom(view)
    #expect(
      view.cropSurface.scrollView.maximumZoomScale <= usualMaximum * (1 + 1e-9),
      "\(description)",
      sourceLocation: sourceLocation
    )

    // The written crop keeps the grown sides in whole pixels.
    let emittedBefore = owner.emittedCount
    view.applyPendingCrop()
    #expect(owner.emittedCount == emittedBefore + 1, "\(description)", sourceLocation: sourceLocation)
    let written = owner.feature.crop.topLeftRect(imageSize: imageSize)
    if grows.width {
      #expect(written.minX == recorded.minX && written.width == recorded.width, "\(description), written \(written)", sourceLocation: sourceLocation)
    }
    if grows.height {
      #expect(written.minY == recorded.minY && written.height == recorded.height, "\(description), written \(written)", sourceLocation: sourceLocation)
    }
    let minimum = CropGuideState.minimumCropOutputSideLength(imageSize: imageSize)
    #expect(min(written.width, written.height) >= minimum, "\(description), written \(written)", sourceLocation: sourceLocation)
  }

  // MARK: - Loading

  nonisolated static let smallCrops: [(name: String, rect: CGRect, lock: AspectRatio?)] = [
    ("a face crop", CGRect(x: 242, y: 68, width: 105, height: 104), nil),
    ("a face crop under a square lock", CGRect(x: 242, y: 68, width: 105, height: 104), .square),
    ("a 16:9 crop under its lock", CGRect(x: 500, y: 400, width: 160, height: 90), AspectRatio(width: 16, height: 9)),
    ("a thin crop", CGRect(x: 600, y: 100, width: 40, height: 300), nil),
  ]

  /// `smallCrops` with the size the first record grows each to: each short
  /// side to 128 without a lock, the smallest whole multiple of the lock's
  /// terms with one (16:9: 15 × (16, 9)).
  nonisolated static let grownSmallCrops: [(name: String, rect: CGRect, lock: AspectRatio?, grown: CGSize)] = [
    ("a face crop", CGRect(x: 242, y: 68, width: 105, height: 104), nil, CGSize(width: 128, height: 128)),
    ("a face crop under a square lock", CGRect(x: 242, y: 68, width: 105, height: 104), .square, CGSize(width: 128, height: 128)),
    ("a 16:9 crop under its lock", CGRect(x: 500, y: 400, width: 160, height: 90), AspectRatio(width: 16, height: 9), CGSize(width: 240, height: 135)),
    ("a thin crop", CGRect(x: 600, y: 100, width: 40, height: 300), nil, CGSize(width: 128, height: 300)),
  ]

  @Test(arguments: smallCrops)
  func `a crop below the minimum loads with the guide on exactly that crop`(
    name: String,
    rect: CGRect,
    lock: AspectRatio?
  ) throws {
    let (view, window, owner) = openCanvas(crop: rect, lock: lock)
    defer { window.isHidden = true }

    let guide = try guideSizeInImage(view)
    #expect(abs(guide.width - rect.width) < 1e-6, "\(name): guide \(guide)")
    #expect(abs(guide.height - rect.height) < 1e-6, "\(name): guide \(guide)")
    let scrollView = view.cropSurface.scrollView
    let usualMaximum = try usualMaximumZoom(view)
    #expect(scrollView.maximumZoomScale > usualMaximum, "\(name)")
    #expect(scrollView.zoomScale <= scrollView.maximumZoomScale, "\(name)")

    // Loading writes nothing, and the guide reports the loaded crop.
    #expect(view.proposedCrop?.cropExtent == rect, "\(name)")
    view.applyPendingCrop()
    #expect(owner.emittedCount == 0, "\(name)")
    #expect(owner.feature.crop.topLeftRect(imageSize: Self.largeImage) == rect, "\(name)")
  }

  /// An undo that brings back a small crop shows it exactly too.
  @Test func `a small crop an undo brings back is shown exactly`() throws {
    let (view, window, owner) = openCanvas(crop: nil)
    defer { window.isHidden = true }
    let small = CGRect(x: 242, y: 68, width: 105, height: 104)
    var feature = owner.feature
    feature.crop = CropFeature(topLeftRect: small, imageSize: Self.largeImage)
    owner.feature = feature
    view.setFeature(feature)
    view.layoutIfNeeded()

    let guide = try guideSizeInImage(view)
    #expect(abs(guide.width - 105) < 1e-6 && abs(guide.height - 104) < 1e-6, "guide \(guide)")
    view.applyPendingCrop()
    #expect(owner.emittedCount == 0)
  }

  @Test func `a crop that reaches the minimum keeps the usual maximum zoom`() throws {
    for rect in [nil, CGRect(x: 300, y: 200, width: 300, height: 200), CGRect(x: 300, y: 200, width: 128, height: 400)] {
      let (view, window, _) = openCanvas(crop: rect)
      defer { window.isHidden = true }
      let usualMaximum = try usualMaximumZoom(view)
      #expect(
        abs(view.cropSurface.scrollView.maximumZoomScale - usualMaximum) <= usualMaximum * 1e-12,
        "\(String(describing: rect))"
      )
    }
  }

  /// On an image smaller than 128 pixels on a side, the minimum is the
  /// image's shorter side.
  @Test func `on a small image a crop below its shorter side is shown exactly`() throws {
    let imageSize = CGSize(width: 100, height: 80)
    let (view, window, owner) = openCanvas(imageSize: imageSize, crop: CGRect(x: 10, y: 10, width: 50, height: 40))
    defer { window.isHidden = true }

    let guide = try guideSizeInImage(view)
    #expect(abs(guide.width - 50) < 1e-6 && abs(guide.height - 40) < 1e-6, "guide \(guide)")
    view.applyPendingCrop()
    #expect(owner.emittedCount == 0)

    // The whole image needs no more zoom than usual.
    let (fullView, fullWindow, _) = openCanvas(imageSize: imageSize, crop: nil)
    defer { fullWindow.isHidden = true }
    let usualMaximum = try usualMaximumZoom(fullView)
    #expect(abs(fullView.cropSurface.scrollView.maximumZoomScale - usualMaximum) <= usualMaximum * 1e-12)
  }

  // MARK: - Recording

  @Test(arguments: grownSmallCrops)
  func `the first pan records a crop below the minimum grown about its center`(
    name: String,
    rect: CGRect,
    lock: AspectRatio?,
    grown: CGSize
  ) async throws {
    let (view, window, owner) = openCanvas(crop: rect, lock: lock)
    defer { window.isHidden = true }
    let pixelsPerPoint = try pixelsPerPoint(view)
    let loaded = try #require(view.proposedCrop).cropExtent

    try await pan(view, by: CGPoint(x: 10, y: -6))

    // The guide moved over the image by the opposite of the drag.
    try expectRecordedAtMinimum(
      view,
      owner: owner,
      original: rect,
      expectedSize: grown,
      expectedCenter: CGPoint(x: loaded.midX - 10 * pixelsPerPoint, y: loaded.midY + 6 * pixelsPerPoint),
      name
    )
  }

  @Test func `the first zoom records a crop below the minimum grown about its center`() async throws {
    let rect = CGRect(x: 242, y: 68, width: 105, height: 104)
    let (view, window, owner) = openCanvas(crop: rect)
    defer { window.isHidden = true }

    // Zooming out a little shows 116.7 × 115.6 pixels, still under 128.
    try await zoom(view, by: 0.9)

    try expectRecordedAtMinimum(
      view,
      owner: owner,
      original: rect,
      expectedSize: CGSize(width: 128, height: 128),
      expectedCenter: CGPoint(x: rect.midX, y: rect.midY),
      "zoom"
    )
  }

  // MARK: - Guide resize

  /// Drags the guide's right edge by `translation` points in two steps,
  /// the way UIKit calls the handle's pan, and returns the guide's size in
  /// image pixels just before the finger lifts, and in points.
  private func dragRightEdge(
    _ view: EditingCanvasView,
    by translation: CGFloat
  ) throws -> (shownInImage: CGSize, shownInPoints: CGSize) {
    let guide = view.guideView
    let pan = ScriptedHandlePan(target: nil, action: nil)
    pan.scriptedState = .began
    pan.scriptedTranslation = CGPoint(x: translation / 2, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    pan.scriptedState = .changed
    pan.scriptedTranslation = CGPoint(x: translation / 2, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    view.layoutIfNeeded()
    let shownInImage = try guideSizeInImage(view)
    let shownInPoints = guide.bounds.size
    pan.scriptedState = .ended
    pan.scriptedTranslation = .zero
    guide.handlePanGestureInRight(gesture: pan)
    return (shownInImage, shownInPoints)
  }

  /// Zooms to `fraction` of the maximum zoom about the guide's center and
  /// lets it settle.
  private func zoomToFractionOfMaximum(_ view: EditingCanvasView, _ fraction: CGFloat) async throws {
    let scrollView = view.cropSurface.scrollView
    try await zoom(view, by: scrollView.maximumZoomScale * fraction / scrollView.zoomScale)
  }

  /// The crop recorded when the drag ended is the one the guide showed,
  /// within the fraction of a pixel that whole-pixel alignment moves it;
  /// it is still the crop after the guide's layout, which shows it (within
  /// a pixel: the guide's frame lands on display pixels, so it can show a
  /// fraction of a pixel past the image, which the layout leaves out).
  private func expectRecordedAsShown(
    _ view: EditingCanvasView,
    shown: CGSize,
    _ name: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> CGRect {
    let recorded = try #require(view.proposedCrop, sourceLocation: sourceLocation).cropExtent
    let description = "\(name): shown \(shown), recorded \(recorded)"
    #expect(abs(recorded.width - shown.width) <= 0.5, "\(description)", sourceLocation: sourceLocation)
    #expect(abs(recorded.height - shown.height) <= 0.5, "\(description)", sourceLocation: sourceLocation)

    try await waitForSettleAndLayout(view)
    let settled = try #require(view.proposedCrop, sourceLocation: sourceLocation).cropExtent
    #expect(
      abs(settled.minX - recorded.minX) < 1e-6 && abs(settled.minY - recorded.minY) < 1e-6
        && abs(settled.width - recorded.width) < 1e-6 && abs(settled.height - recorded.height) < 1e-6,
      "\(description), settled \(settled)",
      sourceLocation: sourceLocation
    )
    let guide = try guideSizeInImage(view)
    #expect(
      abs(guide.width - recorded.width) <= 1 && abs(guide.height - recorded.height) <= 1,
      "\(description), guide after the layout \(guide)",
      sourceLocation: sourceLocation
    )
    return recorded
  }

  /// At the maximum zoom the guide's shorter side shows 128 pixels, and a
  /// drag of its right edge stops when the width shows 128 too. The guide
  /// used to stop only at its 80-point minimum (about 38 pixels here), and
  /// the record then grew the crop to 128 pixels, so the guide jumped
  /// wider at the layout after the drag.
  @Test func `a guide drag at the maximum zoom stops at the minimum crop`() async throws {
    let (view, window, owner) = openCanvas(crop: nil)
    defer { window.isHidden = true }
    try await zoomToFractionOfMaximum(view, 1)
    let pixelsPerPoint = try pixelsPerPoint(view)
    try #require(128 / pixelsPerPoint > Self.guideFloor.width, "128 pixels are \(128 / pixelsPerPoint) points")

    let (shown, _) = try dragRightEdge(view, by: -400)

    #expect(abs(shown.width - 128) <= 0.5, "shown \(shown)")
    #expect(abs(shown.height - 128) <= 0.5, "shown \(shown)")
    let recorded = try await expectRecordedAsShown(view, shown: shown, "free")
    view.applyPendingCrop()
    let written = owner.feature.crop.topLeftRect(imageSize: Self.largeImage)
    #expect(written.width >= 128 && written.height >= 128 && written.width <= recorded.width + 1e-6, "written \(written)")
  }

  /// Under a lock the drag stops at the smallest crop the lock writes, a
  /// whole multiple of its terms, and writes exactly that.
  @Test(arguments: [
    (AspectRatio(width: 16, height: 9), CGSize(width: 240, height: 135)),
    (AspectRatio(width: 4, height: 3), CGSize(width: 172, height: 129)),
    (AspectRatio.square, CGSize(width: 128, height: 128)),
  ])
  func `a guide drag under a lock stops at the smallest crop the lock writes`(
    lock: AspectRatio,
    expected: CGSize
  ) async throws {
    let (view, window, owner) = openCanvas(crop: nil, lock: lock)
    defer { window.isHidden = true }
    try await zoomToFractionOfMaximum(view, 0.6)
    let before = try guideSizeInImage(view)
    let pixelsPerPoint = try pixelsPerPoint(view)
    try #require(before.width > expected.width + 10, "the guide shows \(before)")
    try #require(expected.width / pixelsPerPoint > Self.guideFloor.width, "\(expected.width / pixelsPerPoint) points")

    let (shown, _) = try dragRightEdge(view, by: -600)

    #expect(abs(shown.width - expected.width) <= 0.5, "shown \(shown)")
    #expect(abs(shown.height - expected.height) <= 0.5, "shown \(shown)")
    _ = try await expectRecordedAsShown(view, shown: shown, "\(lock)")
    view.applyPendingCrop()
    let written = owner.feature.crop.topLeftRect(imageSize: Self.largeImage)
    #expect(written.size == expected, "written \(written)")
  }

  /// Zoomed out, 128 pixels are fewer points than the guide's 80-point
  /// floor, which stays the limit.
  @Test func `zoomed out a guide drag stops at the guide's 80-point floor`() async throws {
    let (view, window, _) = openCanvas(crop: nil)
    defer { window.isHidden = true }
    let pixelsPerPoint = try pixelsPerPoint(view)
    try #require(128 / pixelsPerPoint < Self.guideFloor.width, "128 pixels are \(128 / pixelsPerPoint) points")

    let (shown, shownInPoints) = try dragRightEdge(view, by: -600)

    #expect(abs(shownInPoints.width - Self.guideFloor.width) <= 0.5, "shown \(shownInPoints) points")
    #expect(shown.width > 128, "shown \(shown)")
    _ = try await expectRecordedAsShown(view, shown: shown, "zoomed out")
  }

  /// On an image smaller than 128 pixels on a side the drag stops at the
  /// image's shorter side.
  @Test func `on a small image a guide drag stops at the image's shorter side`() async throws {
    let imageSize = CGSize(width: 100, height: 80)
    let (view, window, owner) = openCanvas(imageSize: imageSize, crop: nil)
    defer { window.isHidden = true }
    let pixelsPerPoint = try pixelsPerPoint(view)
    try #require(80 / pixelsPerPoint > Self.guideFloor.width, "80 pixels are \(80 / pixelsPerPoint) points")

    let (shown, _) = try dragRightEdge(view, by: -600)

    #expect(abs(shown.width - 80) <= 0.5, "shown \(shown)")
    #expect(abs(shown.height - 80) <= 0.5, "shown \(shown)")
    _ = try await expectRecordedAsShown(view, shown: shown, "small image")
    view.applyPendingCrop()
    #expect(owner.feature.crop.rect.size == CGSize(width: 80, height: 80), "written \(owner.feature.crop.rect)")
  }

  enum Handle: String, CaseIterable, Sendable {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
  }

  /// Drags `handle` inward by `distance` points in two steps and returns
  /// the guide's size in image pixels just before the finger lifts.
  private func drag(
    _ view: EditingCanvasView,
    _ handle: Handle,
    inwardBy distance: CGFloat
  ) throws -> CGSize {
    let guide = view.guideView
    let translation: CGPoint
    let call: (UIPanGestureRecognizer) -> Void
    switch handle {
    case .top: translation = CGPoint(x: 0, y: distance); call = guide.handlePanGestureInTop
    case .bottom: translation = CGPoint(x: 0, y: -distance); call = guide.handlePanGestureInBottom
    case .left: translation = CGPoint(x: distance, y: 0); call = guide.handlePanGestureInLeft
    case .right: translation = CGPoint(x: -distance, y: 0); call = guide.handlePanGestureInRight
    case .topLeft: translation = CGPoint(x: distance, y: distance); call = guide.handlePanGestureInTopLeft
    case .topRight: translation = CGPoint(x: -distance, y: distance); call = guide.handlePanGestureInTopRight
    case .bottomLeft: translation = CGPoint(x: distance, y: -distance); call = guide.handlePanGestureInBottomLeft
    case .bottomRight: translation = CGPoint(x: -distance, y: -distance); call = guide.handlePanGestureInBottomRight
    }
    let pan = ScriptedHandlePan(target: nil, action: nil)
    pan.scriptedState = .began
    pan.scriptedTranslation = CGPoint(x: translation.x / 2, y: translation.y / 2)
    call(pan)
    pan.scriptedState = .changed
    pan.scriptedTranslation = CGPoint(x: translation.x / 2, y: translation.y / 2)
    call(pan)
    view.layoutIfNeeded()
    let shown = try guideSizeInImage(view)
    pan.scriptedState = .ended
    pan.scriptedTranslation = .zero
    call(pan)
    return shown
  }

  /// A crop at the minimum against the image's bottom-right corner, at the
  /// maximum zoom, after a pan toward that corner that the settle moves
  /// back: the scroll view can rest a fraction of a point past the image
  /// (here about 0.08 point on the right and 0.06 at the bottom), so the
  /// guide's largest frame for a drag is that much smaller than the guide.
  /// The drag's minimum is the guide's size, so a required minimum could
  /// not hold together with the largest frame and the edge the drag keeps,
  /// and Auto Layout broke one of them on every drag. The largest frame
  /// wins; the record grows the fraction of a pixel back to the minimum.
  @Test(arguments: Handle.allCases)
  func `a drag of a minimum crop resting past the image edge breaks no constraint`(handle: Handle) async throws {
    let (view, window, owner) = openCanvas(crop: CGRect(x: 1072, y: 772, width: 128, height: 128))
    defer { window.isHidden = true }
    try await pan(view, by: CGPoint(x: -7.3, y: -5.1))
    let remaining = view.remainingScroll
    try #require(remaining.right < 0 || remaining.bottom < 0, "remaining scroll \(remaining)")
    window.brokenConstraints = []

    let shown = try drag(view, handle, inwardBy: 50)

    #expect(window.brokenConstraints.isEmpty, "\(handle): broke \(window.brokenConstraints)")
    #expect(min(shown.width, shown.height) >= 128 - 0.5, "\(handle): shown \(shown)")
    try await waitForSettleAndLayout(view)
    let recorded = try #require(view.proposedCrop).cropExtent
    #expect(abs(recorded.width - 128) < 1e-6 && abs(recorded.height - 128) < 1e-6, "\(handle): recorded \(recorded)")
    view.applyPendingCrop()
    #expect(owner.feature.crop.rect.size == CGSize(width: 128, height: 128), "\(handle): written \(owner.feature.crop.rect)")
  }

  /// Under a lock whose shorter term does not divide 128 (16:9, 4:3), the
  /// ratio-exact crop of a guide 128 pixels high is a smaller multiple
  /// (224 × 126, 168 × 126); the record grows it to the next one, so the
  /// editor never writes a crop under the minimum.
  @Test(arguments: [
    (AspectRatio(width: 16, height: 9), CGSize(width: 240, height: 135)),
    (AspectRatio(width: 4, height: 3), CGSize(width: 172, height: 129)),
    (AspectRatio.square, CGSize(width: 128, height: 128)),
  ])
  func `a zoom to the maximum under a lock writes at least the minimum with the exact ratio`(
    lock: AspectRatio,
    expected: CGSize
  ) async throws {
    let (view, window, owner) = openCanvas(crop: nil, lock: lock)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await waitForSettleAndLayout(view)

    let recorded = try #require(view.proposedCrop).cropExtent
    #expect(abs(recorded.width - expected.width) < 1e-6 && abs(recorded.height - expected.height) < 1e-6, "recorded \(recorded)")

    view.applyPendingCrop()
    let written = owner.feature.crop.topLeftRect(imageSize: Self.largeImage)
    #expect(written.size == expected, "written \(written)")
  }

  /// Under such a lock the maximum zoom stops at that next multiple, so a
  /// zoom to the maximum records what the guide shows and the settle does
  /// not zoom out to the grown crop.
  @Test(arguments: [
    (AspectRatio(width: 16, height: 9), CGSize(width: 240, height: 135)),
    (AspectRatio(width: 4, height: 3), CGSize(width: 172, height: 129)),
    (AspectRatio(width: 4, height: 5), CGSize(width: 128, height: 160)),
  ])
  func `the maximum zoom under a lock shows the smallest crop the lock writes`(
    lock: AspectRatio,
    expected: CGSize
  ) async throws {
    let (view, window, _) = openCanvas(crop: nil, lock: lock)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
    let shown = try guideSizeInImage(view)
    let zoomScale = scrollView.zoomScale
    #expect(abs(shown.width - expected.width) < 1e-6 && abs(shown.height - expected.height) < 1e-6, "shown \(shown)")
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await waitForSettleAndLayout(view)

    #expect(abs(scrollView.zoomScale - zoomScale) <= zoomScale * 1e-6, "zoom \(zoomScale) → \(scrollView.zoomScale)")
    let recorded = try #require(view.proposedCrop).cropExtent
    #expect(abs(recorded.width - shown.width) < 1e-6 && abs(recorded.height - shown.height) < 1e-6, "recorded \(recorded)")
  }

  /// The maximum zoom stops where the straightened guide's own shorter side
  /// shows the minimum. It used to stop where the guide's larger bounding
  /// box did, so the guide showed less (105 pixels high at 10°), and the
  /// record then grew the crop: the guide's ratio changed without a lock,
  /// and the zoom jumped back with one.
  @Test(arguments: [nil, AspectRatio.square, AspectRatio(width: 3, height: 2)])
  func `a zoom to the maximum on a straightened crop records what the guide shows`(lock: AspectRatio?) async throws {
    let (view, window, owner) = openCanvas(crop: nil, lock: lock)
    defer { window.isHidden = true }
    view.setStraightenAngle(.degrees(10))
    try await waitForSettleAndLayout(view)

    let surface = view.cropSurface
    let scrollView = surface.scrollView
    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
    let shown = try guideSizeInImage(view)
    let zoomScale = scrollView.zoomScale
    #expect(min(shown.width, shown.height) >= 128 - 1e-6, "shown \(shown)")
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await waitForSettleAndLayout(view)

    let recorded = try #require(view.proposedCrop).cropExtent
    #expect(
      abs(recorded.width - shown.width) < 1e-6 && abs(recorded.height - shown.height) < 1e-6,
      "shown \(shown), recorded \(recorded)"
    )
    #expect(abs(scrollView.zoomScale - zoomScale) <= zoomScale * 1e-6, "zoom \(zoomScale) → \(scrollView.zoomScale)")

    view.applyPendingCrop()
    let written = owner.feature.crop.rect.size
    #expect(min(written.width, written.height) >= 128, "written \(written)")
  }

  /// A crop at or above the minimum records as it did.
  @Test func `a pan records a crop that reaches the minimum unchanged in size`() async throws {
    let rect = CGRect(x: 300, y: 200, width: 300, height: 200)
    let (view, window, _) = openCanvas(crop: rect)
    defer { window.isHidden = true }
    let pixelsPerPoint = try pixelsPerPoint(view)

    try await pan(view, by: CGPoint(x: 10, y: -6))

    let recorded = try #require(view.proposedCrop).cropExtent
    #expect(abs(recorded.width - 300) < 1e-6 && abs(recorded.height - 200) < 1e-6, "recorded \(recorded)")
    #expect(abs(recorded.midX - (rect.midX - 10 * pixelsPerPoint)) < 1e-6, "recorded \(recorded)")
    #expect(abs(recorded.midY - (rect.midY + 6 * pixelsPerPoint)) < 1e-6, "recorded \(recorded)")
  }

  /// On an image smaller than 128 pixels on a side, a pan grows the crop to
  /// the image's shorter side.
  @Test func `on a small image the first pan grows a crop to the image's shorter side`() async throws {
    let imageSize = CGSize(width: 100, height: 80)
    let rect = CGRect(x: 25, y: 20, width: 50, height: 40)
    let (view, window, owner) = openCanvas(imageSize: imageSize, crop: rect)
    defer { window.isHidden = true }
    let pixelsPerPoint = try pixelsPerPoint(view)

    try await pan(view, by: CGPoint(x: -4, y: 0))

    let expectedCenter = CGPoint(x: rect.midX + 4 * pixelsPerPoint, y: rect.midY)
    let recorded = try #require(view.proposedCrop).cropExtent
    // 80 × 80 about the guide's center, moved inside the 80-pixel height.
    #expect(recorded.size == CGSize(width: 80, height: 80), "recorded \(recorded)")
    #expect(abs(recorded.midX - expectedCenter.x) <= 0.5 + 1e-6, "recorded \(recorded)")
    #expect(recorded.minY == 0, "recorded \(recorded)")
    view.applyPendingCrop()
    #expect(owner.feature.crop.rect.size == CGSize(width: 80, height: 80))
  }
}
