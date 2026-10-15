import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// A crop below ImageEditor's minimum crop size (128 pixels on the shorter
/// output side, or the image's shorter side when the image is smaller), such
/// as one a host set, is shown exactly and never rewritten on load.
///
/// The crop scroll view's maximum zoom stops at the minimum, so it used to
/// show a larger area than such a crop, and a mere pan grew the crop to that
/// area. These tests host the canvas in a 390×700 window and call the
/// scroll view's delegate the way UIKit does.
@MainActor
struct CropMinimumSizeCanvasTests {

  final class Owner {
    var feature: ImageEditorFeature
    var emittedCount = 0

    init(_ feature: ImageEditorFeature) {
      self.feature = feature
    }
  }

  static let largeImage = CGSize(width: 1200, height: 900)

  private func openCanvas(
    imageSize: CGSize = Self.largeImage,
    crop topLeftRect: CGRect?,
    lock: AspectRatio? = nil
  ) -> (EditingCanvasView, UIWindow, Owner) {
    var feature = ImageEditorFeature(imageSize: imageSize)
    if let topLeftRect {
      feature.crop = CropFeature(topLeftRect: topLeftRect, imageSize: imageSize)
    }
    let owner = Owner(feature)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
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
        .size
    ).max
  }

  // MARK: - Loading

  static let smallCrops: [(name: String, rect: CGRect, lock: AspectRatio?)] = [
    ("a face crop", CGRect(x: 242, y: 68, width: 105, height: 104), nil),
    ("a face crop under a square lock", CGRect(x: 242, y: 68, width: 105, height: 104), .square),
    ("a 16:9 crop under its lock", CGRect(x: 500, y: 400, width: 160, height: 90), AspectRatio(width: 16, height: 9)),
    ("a thin crop", CGRect(x: 600, y: 100, width: 40, height: 300), nil),
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
}
