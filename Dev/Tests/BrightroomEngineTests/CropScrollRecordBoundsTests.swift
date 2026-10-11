import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// A zoom or a pan records the guide on screen as the crop, moved back
/// inside the image when it rests a little past the image edge.
///
/// UIKit rounds a scroll view's offset to device pixels, so a guide that
/// rests against the image edge can sit a fraction of a point past it. The
/// recorded crop keeps the guide's size and ratio, and the edge lands on the
/// image edge. These tests call the scroll view's delegate the way UIKit
/// does, on a 1200×900 image in a 390×700 window.
@MainActor
struct CropScrollRecordBoundsTests {

  private let imageSize = CGSize(width: 1200, height: 900)

  static let locks: [AspectRatio?] = [
    nil,
    .square,
    AspectRatio(width: 4, height: 5),
    AspectRatio(width: 16, height: 9),
  ]

  static let straightenDegrees: [Double] = [0, 4]

  private func openCanvas(lock: AspectRatio?, straightenDegrees: Double) -> (EditingCanvasView, UIWindow) {
    var feature = ImageEditorFeature(imageSize: imageSize)
    if straightenDegrees != 0 {
      var crop = CropGuideState(cropFeature: feature.crop, imageSize: imageSize)
      crop.adjustmentAngle = .degrees(straightenDegrees)
      crop.updateCropExtent(
        CropGeometry.fittingRect(
          rect: CGRect(origin: .zero, size: imageSize),
          in: imageSize,
          straightenRadians: crop.adjustmentAngle.radians,
          respectingAspectRatio: nil
        )
      )
      feature.crop = crop.makeCropFeature()
    }
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let view = EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize)),
        imageSize: imageSize
      ),
      feature: feature
    )
    view.setFeatureChangeHandler { _ in }
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
    return (view, window)
  }

  private func maxContentOffset(_ scrollView: UIScrollView) -> CGPoint {
    CGPoint(
      x: scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right,
      y: scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
    )
  }

  /// Zooms to `zoomScale` about a point 10 pt inside the guide's right edge,
  /// as a pinch there does, and keeps the offset in the scroll range.
  private func zoomTowardRightEdge(_ view: EditingCanvasView, to zoomScale: CGFloat) {
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
    scrollView.setZoomScale(zoomScale, animated: false)
    let maxOffset = maxContentOffset(scrollView)
    scrollView.contentOffset = CGPoint(
      x: min(max(content.x * scrollView.zoomScale - anchor.x, -scrollView.contentInset.left), maxOffset.x),
      y: min(max(content.y * scrollView.zoomScale - anchor.y, -scrollView.contentInset.top), maxOffset.y)
    )
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

  /// The image area `rect` samples: its bounding box after straightening
  /// about its centre.
  private func sampledArea(_ rect: CGRect, straightenDegrees: Double) -> CGRect {
    let radians = straightenDegrees * .pi / 180
    let cosine = abs(CGFloat(cos(radians)))
    let sine = abs(CGFloat(sin(radians)))
    let width = cosine * rect.width + sine * rect.height
    let height = sine * rect.width + cosine * rect.height
    return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
  }

  /// Past the scroll settle (0.2 s) but short of the guide's layout delay
  /// (0.8 s).
  private func waitForSettle() async throws {
    try await Task.sleep(for: .milliseconds(400))
  }

  private func waitPastLayoutDelay(_ view: EditingCanvasView) async throws {
    try await Task.sleep(for: .milliseconds(1100))
    view.layoutIfNeeded()
  }

  /// Ends the zoom, waits for its settle and for the layout delay, and checks
  /// that the recorded crop is the guide at release: the same size and
  /// ratio, its right edge on the image's right edge, its sampled area inside
  /// the image, and that the layout after it keeps the zoom and offset.
  private func endZoomAndExpectGuideRecorded(
    _ view: EditingCanvasView,
    lock: AspectRatio?,
    straightenDegrees: Double,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let surface = view.cropSurface
    let scrollView = surface.scrollView
    let guideSize = try guideSizeInImage(view)
    let zoomAtRelease = scrollView.zoomScale
    let offsetAtRelease = scrollView.contentOffset
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: zoomAtRelease)

    try await waitForSettle()
    let crop = try #require(view.proposedCrop, sourceLocation: sourceLocation)

    try await waitPastLayoutDelay(view)

    let rect = crop.cropExtent
    let sampled = sampledArea(rect, straightenDegrees: straightenDegrees)
    let description = "\(rect) sampling \(sampled), guide \(guideSize)"

    // The guide's size and ratio, not shrunk to fit.
    #expect(abs(rect.width - guideSize.width) < 1e-6, "\(description)", sourceLocation: sourceLocation)
    #expect(abs(rect.height - guideSize.height) < 1e-6, "\(description)", sourceLocation: sourceLocation)
    if let lock {
      #expect(
        abs(rect.width / rect.height - lock.width / lock.height) < 1e-6,
        "\(description)",
        sourceLocation: sourceLocation
      )
    }

    // On the right edge, and inside the image.
    #expect(abs(sampled.maxX - imageSize.width) < 1e-6, "\(description)", sourceLocation: sourceLocation)
    #expect(sampled.minX >= -1e-6, "\(description)", sourceLocation: sourceLocation)
    #expect(sampled.minY >= -1e-6, "\(description)", sourceLocation: sourceLocation)
    #expect(sampled.maxY <= imageSize.height + 1e-6, "\(description)", sourceLocation: sourceLocation)

    // The layout at the settle keeps the zoom the pinch left and moves the
    // image at most the fraction of a point it rested past the edge.
    let motion = "zoom \(zoomAtRelease) → \(scrollView.zoomScale), offset \(offsetAtRelease) → \(scrollView.contentOffset)"
    #expect(abs(scrollView.zoomScale - zoomAtRelease) <= 1e-4, "\(motion)", sourceLocation: sourceLocation)
    #expect(abs(scrollView.contentOffset.x - offsetAtRelease.x) <= 0.5, "\(motion)", sourceLocation: sourceLocation)
    #expect(abs(scrollView.contentOffset.y - offsetAtRelease.y) <= 0.5, "\(motion)", sourceLocation: sourceLocation)
    #expect(view.proposedCrop == crop, sourceLocation: sourceLocation)
  }

  @Test(arguments: locks, straightenDegrees)
  func `a zoom that rests just past the image edge records the guide`(
    lock: AspectRatio?,
    straightenDegrees: Double
  ) async throws {
    let (view, window) = openCanvas(lock: lock, straightenDegrees: straightenDegrees)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView

    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    zoomTowardRightEdge(view, to: scrollView.zoomScale * 2)
    // Less than the half point the settle accepts as a rest in the range.
    scrollView.contentOffset.x = maxContentOffset(scrollView).x + 0.4

    try await endZoomAndExpectGuideRecorded(view, lock: lock, straightenDegrees: straightenDegrees)
  }

  @Test(arguments: locks, straightenDegrees)
  func `a zoom out to the minimum near the image edge records the guide`(
    lock: AspectRatio?,
    straightenDegrees: Double
  ) async throws {
    let (view, window) = openCanvas(lock: lock, straightenDegrees: straightenDegrees)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView

    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    zoomTowardRightEdge(view, to: scrollView.zoomScale * 2.5)
    scrollView.contentOffset.x = maxContentOffset(scrollView).x
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await waitForSettle()
    try await waitPastLayoutDelay(view)

    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    zoomTowardRightEdge(view, to: scrollView.minimumZoomScale)
    scrollView.contentOffset.x = maxContentOffset(scrollView).x

    try await endZoomAndExpectGuideRecorded(view, lock: lock, straightenDegrees: straightenDegrees)
  }

  @Test(arguments: locks)
  func `a zoom that rests well past the image edge records the guide inside the image`(
    lock: AspectRatio?
  ) async throws {
    let (view, window) = openCanvas(lock: lock, straightenDegrees: 0)
    defer { window.isHidden = true }
    let surface = view.cropSurface
    let scrollView = surface.scrollView

    surface.scrollViewWillBeginZooming(scrollView, with: nil)
    zoomTowardRightEdge(view, to: scrollView.zoomScale * 2)
    // A rest UIKit does not bounce back, as after a below-minimum pinch
    // whose bounce left the offset where a stale content size allowed it.
    scrollView.contentOffset.x = maxContentOffset(scrollView).x + 20
    let guideSize = try guideSizeInImage(view)
    let zoomAtRelease = scrollView.zoomScale
    surface.scrollViewDidEndZooming(scrollView, with: nil, atScale: zoomAtRelease)

    try await waitPastLayoutDelay(view)

    // Recorded with the guide's size, moved back onto the right edge; the
    // layout then moves the image back under the guide at the same zoom.
    let rect = try #require(view.proposedCrop).cropExtent
    #expect(abs(rect.width - guideSize.width) < 1e-6, "\(rect), guide \(guideSize)")
    #expect(abs(rect.height - guideSize.height) < 1e-6, "\(rect), guide \(guideSize)")
    #expect(abs(rect.maxX - imageSize.width) < 1e-6, "\(rect)")
    #expect(rect.minY >= 0 && rect.maxY <= imageSize.height, "\(rect)")
    #expect(abs(scrollView.zoomScale - zoomAtRelease) <= 1e-4, "zoom \(zoomAtRelease) → \(scrollView.zoomScale)")
    #expect(abs(scrollView.contentOffset.x - maxContentOffset(scrollView).x) <= 0.5)
  }
}
