import CoreGraphics
import SwiftUI
import Testing
import UIKit

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Hosts `ImageEditor` in a window and drives its Reset through its
/// accessibility elements: Reset restores every parameter as one write that
/// is a history step of its own, shows in every mode, and keeps a `.fixed`
/// policy's lock.
@MainActor
struct ImageEditorResetTests {

  /// The host's document, observable so a change the test makes to it
  /// reaches the editor as a host's undo would.
  @MainActor
  @Observable
  final class Host {
    var document: ImageEditorDocument
    private(set) var writes = 0

    init(_ document: ImageEditorDocument) {
      self.document = document
    }

    var binding: Binding<ImageEditorDocument> {
      Binding(get: { self.document }, set: { self.document = $0; self.writes += 1 })
    }
  }

  private static let imageSize = DocumentTestFixtures.rotatedJPEGSize

  /// The initial feature of the whole image: the policy's crop apart, what
  /// Reset restores.
  private static let initial = ImageEditorFeature(imageSize: imageSize)

  private func makeHost() throws -> Host {
    Host(try DocumentTestFixtures.makeDocument(feature: Self.initial))
  }

  /// Whether `label` is on screen as an enabled button.
  private func isEnabledButton(_ label: String, in mounted: MountedEditor) -> Bool {
    guard let element = mounted.element(label) else {
      return false
    }
    return element.accessibilityTraits.contains(.button)
      && element.accessibilityTraits.contains(.notEnabled) == false
  }

  /// Mounts the editor over `host` and waits until it has prepared the
  /// image and reported its first crop guide.
  private func mountLoadedEditor(
    _ host: Host,
    options: ImageEditor.Options = .init()
  ) async throws -> (mounted: MountedEditor, canvasView: EditingCanvasView) {
    let mounted = mountEditor(ImageEditor(document: host.binding, options: options, onDone: {}))
    try await mounted.wait(
      until: { isEnabledButton("Rotate", in: mounted) },
      "The editor never prepared the image."
    )
    let canvasView = try #require(find(EditingCanvasView.self, in: mounted.host.view))
    // The first guide arrives on a later turn.
    for _ in 0..<10 {
      mounted.host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    return (mounted, canvasView)
  }

  private func activate(_ label: String, in mounted: MountedEditor) throws {
    #expect(try #require(mounted.element(label), "\(label)").accessibilityActivate(), "\(label)")
  }

  @Test func `Reset is hidden while the feature is initial, and shows in every mode once it differs`() async throws {
    let host = try makeHost()
    let (mounted, _) = try await mountLoadedEditor(host)
    defer { mounted.window.isHidden = true }
    #expect(mounted.element("Reset") == nil)

    try activate("Filters", in: mounted)
    try await mounted.wait(
      until: { mounted.element("Filters")?.accessibilityValue == "selected" },
      "Activating Filters did not select it."
    )
    #expect(mounted.element("Reset") == nil)

    // An adjustment the host puts in the document shows Reset in Filters.
    host.document.feature.effects.exposure = ExposureFeature(ev: 1)
    try await mounted.wait(until: { isEnabledButton("Reset", in: mounted) }, "Reset is not shown in Filters.")

    try activate("Reset", in: mounted)
    #expect(host.document.feature == Self.initial)
    try await mounted.wait(until: { mounted.element("Reset") == nil }, "Reset stayed after resetting.")
  }

  @Test func `Reset in Adjust mode writes the initial feature once, and undo restores the adjustment with the crop`() async throws {
    let host = try makeHost()
    let (mounted, canvasView) = try await mountLoadedEditor(host)
    defer { mounted.window.isHidden = true }

    // A turn, applied by leaving Crop, then an adjustment: two visits.
    try activate("Rotate", in: mounted)
    try activate("Adjustments", in: mounted)
    try await mounted.wait(
      until: { host.document.feature.crop.quarterTurn != .zero && findSlider(in: mounted.host.view)?.isEnabled == true },
      "Leaving Crop did not apply the turn."
    )
    try #require(findSlider(in: mounted.host.view)).accessibilityIncrement()
    try await mounted.wait(
      until: { host.document.feature.effects.exposure != nil },
      "The slider step was not written."
    )
    let edited = host.document.feature
    #expect(edited.crop.quarterTurn != .zero)
    try await mounted.wait(until: { isEnabledButton("Reset", in: mounted) }, "Reset is not shown in Adjust.")

    let writes = host.writes
    try activate("Reset", in: mounted)
    #expect(host.writes == writes + 1, "Reset is one write.")
    #expect(host.document.feature == Self.initial)
    #expect(host.document.hasUncommittedChanges, "The reset is the step in progress.")

    var undone = host.document
    undone.undo()
    #expect(undone.feature == edited, "Undo restores the adjustment and the crop together.")
    undone.undo()
    #expect(undone.feature.effects.exposure == nil)
    #expect(undone.feature.crop == edited.crop, "The crop visit is a step of its own.")
    undone.undo()
    #expect(undone.feature == Self.initial)

    // The canvas reloads the crop, the slider shows 0, and Reset leaves.
    try await mounted.wait(
      until: {
        canvasView.proposedCrop?.rotation == .zero
          && mounted.element("Reset") == nil
          && findSlider(in: mounted.host.view)?.accessibilityValue == "0.00"
      },
      "The canvas and the slider did not follow the reset."
    )
    try await canvasView.waitForPendingCropUpdates(after: .milliseconds(300))
    #expect(host.document.feature == Self.initial, "No later write brings the edit back.")
  }

  @Test func `Reset in Crop mode writes the whole image over a pending crop, which nothing brings back`() async throws {
    let host = try makeHost()
    let (mounted, canvasView) = try await mountLoadedEditor(host)
    defer { mounted.window.isHidden = true }

    // A turn the guide shows but the document has not received, and a zoom
    // whose settle has not recorded it.
    try activate("Rotate", in: mounted)
    try await mounted.wait(until: { isEnabledButton("Reset", in: mounted) }, "Reset is not shown for a pending crop.")
    #expect(host.writes == 0)
    let scrollView = canvasView.cropSurface.scrollView
    canvasView.cropSurface.scrollViewWillBeginZooming(scrollView, with: nil)
    canvasView.cropSurface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    #expect(canvasView.hasPendingCropUpdate)

    try activate("Reset", in: mounted)
    #expect(host.document.feature == Self.initial)
    #expect(host.document.hasUncommittedChanges)
    var undone = host.document
    undone.undo()
    #expect(undone.feature.crop.quarterTurn != .zero, "The pending crop is the step before the reset.")

    try await mounted.wait(
      until: { canvasView.proposedCrop?.rotation == .zero && mounted.element("Reset") == nil },
      "The canvas did not follow the reset."
    )
    try await canvasView.waitForPendingCropUpdates(after: .seconds(1))
    #expect(host.document.feature == Self.initial, "No timer records the pending crop again.")
    let writes = host.writes
    try activate("Done", in: mounted)
    #expect(host.writes == writes, "Done writes nothing after a reset.")
    #expect(host.document.feature == Self.initial)
  }

  /// GitHub #342: a `.fixed` editor used to lose its lock on Reset, and
  /// could not lock again.
  @Test func `Under a fixed ratio Reset writes the fitted crop and keeps the lock`() async throws {
    let host = try makeHost()
    var options = ImageEditor.Options()
    options.aspectRatioPolicy = .fixed(.square)
    let (mounted, canvasView) = try await mountLoadedEditor(host, options: options)
    defer { mounted.window.isHidden = true }
    let fitted = InitialCrop.crop(fitting: .square, imageSize: Self.imageSize)
    // The 20 x 40 image fits a centered 20 x 20 square.
    #expect(fitted.rect == CGRect(x: 0, y: 10, width: 20, height: 20))

    try await mounted.wait(
      until: { canvasView.guideView.lockedAspectRatio == .square && mounted.element("Reset") == nil },
      "The guide shows the fitted crop, which is the initial one."
    )
    try activate("Rotate", in: mounted)
    try await mounted.wait(until: { isEnabledButton("Reset", in: mounted) }, "Reset is not shown for a turned crop.")

    try activate("Reset", in: mounted)
    #expect(host.document.feature == ImageEditorFeature(crop: fitted))
    try await mounted.wait(
      until: { canvasView.proposedCrop?.rotation == .zero && mounted.element("Reset") == nil },
      "The canvas did not follow the reset."
    )
    #expect(canvasView.guideView.lockedAspectRatio == .square, "The lock is kept.")
    #expect(canvasView.proposedCrop?.makeCropFeature() == fitted)

    // The kept lock fits what the guide is given next, so Done writes a
    // square.
    canvasView.setCrop(CropGuideState(cropFeature: Self.initial.crop, imageSize: Self.imageSize))
    try activate("Done", in: mounted)
    let written = host.document.feature.crop
    #expect(written.rect.width == written.rect.height)
    #expect(written.rect.width == 20)
  }

  /// A `.fixed` editor fits the document's crop to its ratio when the canvas
  /// loads, so a whole-image crop in the document is no reason to show Reset
  /// before the guide reports the crop it shows; an effect is.
  @Test func `Under a fixed ratio Reset is hidden until the guide reports the crop`() async throws {
    let host = try makeHost()
    var options = ImageEditor.Options()
    options.aspectRatioPolicy = .fixed(.square)
    // A preparation that fails leaves the editor unloaded for good.
    let loader = PreviewSourceLoader(source: host.document.source) { _ in nil }
    let mounted = mountEditor(
      ImageEditorContent(
        document: host.binding,
        previewSourceLoader: loader,
        options: options,
        localizedStrings: .init(),
        onDone: {},
        onCancel: nil
      )
    )
    defer { mounted.window.isHidden = true }
    try await mounted.wait(
      until: { loader.phase == .failed && mounted.element("Done") != nil },
      "The editor never showed the failed preparation."
    )
    #expect(mounted.element("Reset") == nil, "The whole-image crop will be fitted; nothing to reset.")

    host.document.feature.effects.exposure = ExposureFeature(ev: 1)
    try await mounted.wait(until: { mounted.element("Reset") != nil }, "Reset is not shown for an effect.")
  }

  /// A host's own effect in `effects.custom` has no control, so it alone is
  /// nothing to reset, and Reset keeps it.
  @Test func `Reset keeps the host's custom effects and is hidden while they are the only effect`() async throws {
    let custom = [AnyImageEffect(ExposureFeature(ev: 1))]
    var feature = Self.initial
    feature.effects.custom = custom
    let host = Host(try DocumentTestFixtures.makeDocument(feature: feature))
    let (mounted, _) = try await mountLoadedEditor(host)
    defer { mounted.window.isHidden = true }
    #expect(mounted.element("Reset") == nil, "A custom effect alone is nothing to reset.")

    host.document.feature.effects.saturation = SaturationFeature(value: 0.5)
    try await mounted.wait(until: { isEnabledButton("Reset", in: mounted) }, "Reset is not shown for an adjustment.")

    let writes = host.writes
    try activate("Reset", in: mounted)
    #expect(host.writes == writes + 1)
    #expect(host.document.feature == feature, "Reset keeps the custom effects.")
    #expect(host.document.feature.effects.custom == custom)
    try await mounted.wait(until: { mounted.element("Reset") == nil }, "Reset stayed after resetting.")
  }

  /// The `SteppedSliderControl` on screen (generic, so matched by name).
  private func findSlider(in view: UIView) -> UIControl? {
    if let control = view as? UIControl, "\(type(of: control))".hasPrefix("SteppedSliderControl") {
      return control
    }
    for subview in view.subviews {
      if let found = findSlider(in: subview) {
        return found
      }
    }
    return nil
  }

  private func find<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
    if let match = view as? View {
      return match
    }
    for subview in view.subviews {
      if let found = find(type, in: subview) {
        return found
      }
    }
    return nil
  }
}

extension EditingCanvasView {

  /// Waits `minimum`, then until no scroll settle or crop layout is still
  /// scheduled, and lays out. (`Dev/Tests` has the same helper.)
  fileprivate func waitForPendingCropUpdates(
    after minimum: Duration,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    try await Task.sleep(for: minimum)
    let deadline = ContinuousClock.now + timeout
    while hasPendingCropUpdate {
      try #require(
        ContinuousClock.now < deadline,
        "a scroll settle or crop layout was still scheduled after \(timeout)",
        sourceLocation: sourceLocation
      )
      try await Task.sleep(for: .milliseconds(20))
    }
    layoutIfNeeded()
  }
}
