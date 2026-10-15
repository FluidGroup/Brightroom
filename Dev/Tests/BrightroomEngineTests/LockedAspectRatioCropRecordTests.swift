import CoreImage
import Testing
import SwiftUI
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// A crop recorded under a locked aspect ratio is written and exported with
/// exactly that ratio in whole pixels, when the ratio's lowest terms are at
/// most 32.
///
/// The guide records continuous selections; snapping each edge inward on
/// its own made a locked square 479×478. These tests call the scroll view's
/// delegate and the guide's handle handlers the way UIKit does, on a
/// 1200×900 image in a 390×700 window, so the recorded selections are
/// fractional.
@MainActor
struct LockedAspectRatioCropRecordTests {

  private let imageSize = CGSize(width: 1200, height: 900)

  final class Owner {
    var feature: ImageEditorFeature
    var emittedCount = 0
    var guides: [ImageEditorCanvas.CropGuide] = []

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

  static let exactCases: [(lock: AspectRatio, turn: QuarterTurn)] = [
    (.square, .zero),
    (AspectRatio(width: 4, height: 5), .zero),
    (AspectRatio(width: 16, height: 9), .zero),
    (.square, .counterclockwise90),
    (AspectRatio(width: 4, height: 5), .counterclockwise90),
    (AspectRatio(width: 16, height: 9), .counterclockwise270),
  ]

  private var source: CIImage {
    CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize))
  }

  private func openCanvas(
    lock: AspectRatio?,
    quarterTurn: QuarterTurn = .zero
  ) -> (EditingCanvasView, UIWindow, Owner) {
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.crop = CropFeature(
      topLeftRect: CGRect(origin: .zero, size: imageSize),
      imageSize: imageSize,
      quarterTurn: quarterTurn
    )
    let owner = Owner(feature)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let view = EditingCanvasView(
      source: EditingCanvasSource(editingSourceImage: source, imageSize: imageSize),
      feature: feature
    )
    view.setCropGuideHandler { owner.guides.append($0) }
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

  /// Past the scroll settle (0.2 s) and the guide's layout delay (0.8 s).
  private func waitForSettleAndLayout(_ view: EditingCanvasView) async throws {
    try await Task.sleep(for: .milliseconds(1100))
    view.layoutIfNeeded()
  }

  /// Zooms by `factor` about the guide's centre, then pans by a fractional
  /// distance, settling after each, as a pinch and a drag do.
  private func zoomAndPan(_ view: EditingCanvasView, by factor: CGFloat) async throws {
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

    surface.scrollViewWillBeginDragging(scrollView)
    let maxOffset = maxContentOffset(scrollView)
    scrollView.contentOffset = CGPoint(
      x: min(max(scrollView.contentOffset.x - 13.37, -scrollView.contentInset.left), maxOffset.x),
      y: min(max(scrollView.contentOffset.y + 7.21, -scrollView.contentInset.top), maxOffset.y)
    )
    surface.scrollViewDidEndDragging(scrollView, willDecelerate: false)
    try await waitForSettleAndLayout(view)
  }

  /// The written crop's output has exactly `lock`, as the largest whole
  /// multiple of its terms inside the recorded selection, centered on it
  /// within half a pixel; the guide reports the crop it wrote, the export
  /// has that size, and a reload of it keeps it and writes nothing.
  private func expectWrittenExactly(
    _ lock: AspectRatio,
    view: EditingCanvasView,
    owner: Owner,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let recorded = try #require(view.proposedCrop, sourceLocation: sourceLocation)
    let selection = recorded.cropExtent
    let emittedBefore = owner.emittedCount
    view.applyPendingCrop()
    #expect(owner.emittedCount == emittedBefore + 1, sourceLocation: sourceLocation)

    let written = owner.feature
    let crop = written.crop
    let aligned = crop.topLeftRect(imageSize: imageSize)
    let output = crop.outputGeometry(in: .zero).outputBounds.size
    let terms = try #require(PixelAlignedCrop.exactTerms(of: lock), sourceLocation: sourceLocation)
    let description = "recorded \(selection) → \(aligned), output \(output), lock \(lock)"

    let multiple = Int(output.width) / terms.width
    #expect(multiple >= 1, "\(description)", sourceLocation: sourceLocation)
    #expect(
      output == CGSize(width: multiple * terms.width, height: multiple * terms.height),
      "\(description)",
      sourceLocation: sourceLocation
    )
    let selectionTerms = crop.quarterTurn.isSideways ? (width: terms.height, height: terms.width) : terms
    let available = (width: Int(floor(selection.width + 1e-8)), height: Int(floor(selection.height + 1e-8)))
    #expect(
      Int(aligned.width) <= available.width && Int(aligned.height) <= available.height,
      "\(description)",
      sourceLocation: sourceLocation
    )
    #expect(
      (multiple + 1) * selectionTerms.width > available.width
        || (multiple + 1) * selectionTerms.height > available.height,
      "\(description)",
      sourceLocation: sourceLocation
    )
    #expect(abs(aligned.midX - selection.midX) <= 0.5 + 1e-9, "\(description)", sourceLocation: sourceLocation)
    #expect(abs(aligned.midY - selection.midY) <= 0.5 + 1e-9, "\(description)", sourceLocation: sourceLocation)
    #expect(owner.guides.last?.pendingCrop == crop, "\(description)", sourceLocation: sourceLocation)

    // The export has the written size.
    let rendered = try FeatureRenderer().makeImage(from: source, feature: written)
    #expect(rendered.extent.size == output, "\(description), rendered \(rendered.extent)", sourceLocation: sourceLocation)

    // An undo and a redo under the lock bring it back as it is.
    let other = ImageEditorFeature(imageSize: imageSize)
    owner.feature = other
    view.setFeature(other)
    owner.feature = written
    view.setFeature(written)
    let emittedAfterReload = owner.emittedCount
    view.applyPendingCrop()
    #expect(view.proposedCrop?.cropExtent == aligned, "\(description)", sourceLocation: sourceLocation)
    #expect(owner.emittedCount == emittedAfterReload, "\(description)", sourceLocation: sourceLocation)
  }

  // MARK: - Exact ratios

  @Test(arguments: exactCases)
  func `a zoom and a pan under a lock write exactly the locked ratio`(
    lock: AspectRatio,
    turn: QuarterTurn
  ) async throws {
    let (view, window, owner) = openCanvas(lock: lock, quarterTurn: turn)
    defer { window.isHidden = true }

    try await zoomAndPan(view, by: 1.37)

    try expectWrittenExactly(lock, view: view, owner: owner)
  }

  /// A guide resize records through clipping and the ratio fit, not the
  /// move inside the image; it writes the exact ratio as well.
  @Test(arguments: [AspectRatio.square, AspectRatio(width: 4, height: 5)])
  func `a guide resize under a lock writes exactly the locked ratio`(lock: AspectRatio) async throws {
    let (view, window, owner) = openCanvas(lock: lock)
    defer { window.isHidden = true }
    let guide = view.guideView

    let pan = ScriptedHandlePan(target: nil, action: nil)
    pan.scriptedState = .began
    pan.scriptedTranslation = CGPoint(x: -23.3, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    pan.scriptedState = .changed
    pan.scriptedTranslation = CGPoint(x: -31.7, y: 0)
    guide.handlePanGestureInRight(gesture: pan)
    pan.scriptedState = .ended
    pan.scriptedTranslation = .zero
    guide.handlePanGestureInRight(gesture: pan)
    try await waitForSettleAndLayout(view)

    let recorded = try #require(view.proposedCrop).cropExtent
    try #require(recorded.width < imageSize.width - 10, "the resize recorded a smaller crop: \(recorded)")
    try expectWrittenExactly(lock, view: view, owner: owner)
  }

  /// A straighten edit records through clipping too, and keeps a fractional
  /// origin; the size is still exactly the ratio.
  @Test func `a straighten under a lock writes exactly the locked ratio`() throws {
    let lock = AspectRatio(width: 4, height: 5)
    let (view, window, owner) = openCanvas(lock: lock)
    defer { window.isHidden = true }

    view.setStraightenAngle(.degrees(3.3))

    try expectWrittenExactly(lock, view: view, owner: owner)
    #expect(owner.feature.crop.straightenRadians == Angle.degrees(3.3).radians)
  }

  // MARK: - Snapped edge by edge

  /// A ratio with large terms, such as an image's own 1123:794, keeps the
  /// edge-by-edge snap, within a pixel or two of the ratio.
  @Test func `a lock with large terms writes the nearest whole pixels`() async throws {
    let lock = AspectRatio(width: 1123, height: 794)
    let (view, window, owner) = openCanvas(lock: lock)
    defer { window.isHidden = true }

    try await zoomAndPan(view, by: 1.37)
    let recorded = try #require(view.proposedCrop)
    view.applyPendingCrop()

    let crop = owner.feature.crop
    #expect(crop == CropFeature(topLeftRect: recorded.cropExtent, imageSize: imageSize))
    let ratio = lock.width / lock.height
    #expect(abs(crop.rect.width - ratio * crop.rect.height) < 2 * ratio, "\(crop.rect)")
  }

  @Test func `an unlocked crop writes the nearest whole pixels`() async throws {
    let (view, window, owner) = openCanvas(lock: nil)
    defer { window.isHidden = true }

    try await zoomAndPan(view, by: 1.37)
    let recorded = try #require(view.proposedCrop)
    view.applyPendingCrop()

    #expect(owner.feature.crop == CropFeature(topLeftRect: recorded.cropExtent, imageSize: imageSize))
  }

  // MARK: - Kept crops

  /// A stored crop that misses the lock by a pixel (a face crop of `.square`,
  /// 105×104) is kept on load and written by nothing but a gesture.
  @Test func `a loaded crop that misses the lock by a pixel is not rewritten`() throws {
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.crop = CropFeature(topLeftRect: CGRect(x: 242, y: 68, width: 105, height: 104), imageSize: imageSize)
    let (view, window, owner) = openCanvas(lock: nil)
    defer { window.isHidden = true }
    owner.feature = feature
    view.setFeature(feature)
    EditingCanvasRepresentable.Coordinator().applyLockedAspectRatio(.square, to: view)

    view.applyPendingCrop()

    #expect(owner.emittedCount == 0)
    #expect(owner.guides.last?.pendingCrop == feature.crop)
  }

  // MARK: - Started under a lock

  /// An EditingCanvasView over a gray image of `imageSize` showing
  /// `feature`, hosted in a 390×700 window.
  private func openCanvas(feature: ImageEditorFeature, imageSize: CGSize) -> (EditingCanvasView, UIWindow, Owner) {
    let owner = Owner(feature)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    let view = EditingCanvasView(
      source: EditingCanvasSource(
        editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize)),
        imageSize: imageSize
      ),
      feature: feature
    )
    view.setCropGuideHandler { owner.guides.append($0) }
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

  private func makeSourceImage(_ size: CGSize) throws -> SourceImage {
    let context = try #require(
      CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    return SourceImage(cgImage: try #require(context.makeImage()))
  }

  /// The typical avatar flow: a document made with
  /// `InitialCrop.aspectRatio(_:)`, opened in a `.fixed` editor of the same
  /// ratio and confirmed without touching the crop, exports exactly the
  /// ratio. The editor keeps the loaded crop (nothing is written), so the
  /// initial crop itself has to be exact; it was 2418 × 3024.
  @Test func `an initial aspect-ratio crop under the same fixed lock exports exactly the ratio`() async throws {
    let imageSize = CGSize(width: 4032, height: 3024)
    let lock = AspectRatio(width: 4, height: 5)
    let document = await EditingDocument(source: try makeSourceImage(imageSize), initialCrop: .aspectRatio(lock))
    let (view, window, owner) = openCanvas(feature: document.feature, imageSize: imageSize)
    defer { window.isHidden = true }
    EditingCanvasRepresentable.Coordinator().applyLockedAspectRatio(lock, to: view)

    view.applyPendingCrop()

    #expect(owner.emittedCount == 0)
    let crop = owner.feature.crop
    #expect(crop.rect.size == CGSize(width: 2416, height: 3020), "\(crop.rect)")
    let output = try FeatureRenderer().makeImage(
      from: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: imageSize)),
      feature: crop
    )
    #expect(output.extent.size == CGSize(width: 2416, height: 3020))
  }

  // MARK: - Picked locks

  /// A ratio the user picks keeps a crop that already has it within the
  /// rounding allowance, and aligns it to exactly the ratio, so the picked
  /// ratio is exported. A 1080 × 1349 photo's full crop was kept as it was.
  @Test func `a picked ratio aligns a crop that nearly has it to exactly the ratio`() throws {
    let imageSize = CGSize(width: 1080, height: 1349)
    let lock = AspectRatio(width: 4, height: 5)
    let (view, window, owner) = openCanvas(feature: ImageEditorFeature(imageSize: imageSize), imageSize: imageSize)
    defer { window.isHidden = true }

    // As ImageEditor's picker does: the canvas mounted unlocked.
    let coordinator = EditingCanvasRepresentable.Coordinator()
    coordinator.applyLockedAspectRatio(nil, to: view)
    coordinator.applyLockedAspectRatio(lock, to: view)
    view.layoutIfNeeded()
    view.applyPendingCrop()

    // 269 × (4, 5), centered within half a pixel.
    #expect(owner.emittedCount == 1)
    let written = owner.feature.crop.topLeftRect(imageSize: imageSize)
    #expect(written.size == CGSize(width: 1076, height: 1345), "\(written)")
    #expect(abs(written.midX - 540) <= 0.5 && abs(written.midY - 674.5) <= 0.5, "\(written)")
    // The guide shows the crop that was written.
    #expect(view.proposedCrop?.cropExtent == written)
    #expect(owner.guides.last?.pendingCrop == owner.feature.crop)
  }

  /// The same for a stored crop a pixel off square when the user picks
  /// Square.
  @Test func `a picked square aligns a stored crop a pixel off square`() throws {
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.crop = CropFeature(topLeftRect: CGRect(x: 100, y: 100, width: 479, height: 478), imageSize: imageSize)
    let (view, window, owner) = openCanvas(feature: feature, imageSize: imageSize)
    defer { window.isHidden = true }

    view.setLockedAspectRatio(.square)
    view.applyPendingCrop()

    #expect(owner.emittedCount == 1)
    let written = owner.feature.crop.topLeftRect(imageSize: imageSize)
    #expect(written.size == CGSize(width: 478, height: 478), "\(written)")
    #expect(abs(written.midX - 339.5) <= 0.5 && abs(written.midY - 339) <= 0.5, "\(written)")
  }

  /// The lock a canvas mounts with (a `.fixed` editor) keeps the same crop
  /// on its pixels: opening the document writes nothing.
  @Test func `the lock a canvas mounts with keeps a crop that nearly has it`() throws {
    let imageSize = CGSize(width: 1080, height: 1349)
    let lock = AspectRatio(width: 4, height: 5)
    let feature = ImageEditorFeature(imageSize: imageSize)
    let (view, window, owner) = openCanvas(feature: feature, imageSize: imageSize)
    defer { window.isHidden = true }

    EditingCanvasRepresentable.Coordinator().applyLockedAspectRatio(lock, to: view)
    view.applyPendingCrop()

    #expect(owner.emittedCount == 0)
    #expect(view.proposedCrop?.cropExtent == CGRect(origin: .zero, size: imageSize))
  }
}
