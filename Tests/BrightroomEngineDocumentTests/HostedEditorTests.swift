import CoreGraphics
import SwiftUI
import Testing
import UIKit

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Hosts the editors over a document binding in a window: they prepare the
/// document's source image themselves, write nothing on mount, and write
/// canvas changes back without committing.
@MainActor
struct HostedEditorTests {

  @MainActor
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

  /// Receives the proxy of an `ImageEditorCanvasReader` from inside a view.
  @MainActor
  final class ProxyBox {
    var proxy: ImageEditorCanvasProxy?
  }

  /// Shows `rootView` in a window and waits until an `EditingCanvasView` is mounted.
  private func mount(
    _ rootView: some View
  ) async throws -> (window: UIWindow, host: UIViewController, canvasView: EditingCanvasView) {
    let host = UIHostingController(rootView: rootView)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.makeKeyAndVisible()

    for _ in 0..<300 {
      host.view.layoutIfNeeded()
      if let canvasView = find(EditingCanvasView.self, in: host.view) {
        return (window, host, canvasView)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    window.isHidden = true
    Issue.record("The canvas never mounted.")
    throw CancellationError()
  }

  @Test func `The crop canvas prepares the image and writes crop commits without committing`() async throws {
    let image = try DocumentTestFixtures.makeImage()
    let host = Host(EditingDocument(source: image))
    let box = ProxyBox()

    let mounted = try await mount(
      ImageEditorCanvasReader { canvas in
        ImageEditorCanvas(document: host.binding)
          .onAppear { box.proxy = canvas }
      }
    )
    defer { mounted.window.isHidden = true }

    #expect(mounted.canvasView.bounds.isEmpty == false)
    #expect(host.writes == 0, "Mounting must not write the document.")

    let canvas = try #require(box.proxy)
    canvas.rotateCounterclockwise()
    canvas.applyPendingCrop()

    #expect(host.writes == 1)
    #expect(host.document.feature.crop.quarterTurn != .zero)
    #expect(host.document.hasUncommittedChanges, "ImageEditorCanvas never commits.")
    #expect(host.document.source == image)
  }

  @MainActor
  final class GuideRecorder {
    var guides: [ImageEditorCanvas.CropGuide] = []
  }

  @Test func `The crop canvas reports its guide after mounting, once`() async throws {
    let host = Host(EditingDocument(source: try DocumentTestFixtures.makeImage()))
    let recorder = GuideRecorder()

    let mounted = try await mount(
      ImageEditorCanvas(document: host.binding)
        .onCropGuideChange { recorder.guides.append($0) }
    )
    defer { mounted.window.isHidden = true }

    // The guide loaded in makeUIView arrives on a later turn.
    for _ in 0..<10 {
      mounted.host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(recorder.guides.count == 1)
    let guide = try #require(recorder.guides.last)
    #expect(guide.canvasBounds == CGRect(origin: .zero, size: mounted.canvasView.bounds.size))
    #expect(guide.canvasBounds.isEmpty == false)
    #expect(guide.pendingCrop?.isPixelEquivalent(
      to: host.document.feature.crop,
      imageSize: host.document.source.pixelSize
    ) == true)
    #expect(guide.interaction.isEmpty)
    #expect(host.writes == 0)
  }

  /// What the crop overlay builders received, latest last.
  @MainActor
  final class InteractionRecorder {
    var inside: [CropInteraction] = []
    var outside: [CropInteraction] = []
  }

  /// Moving the image and resizing the guide at once: the guide and both
  /// overlays receive the union, and idle only when both have ended.
  @Test func `Overlapping crop interactions are reported as their union`() async throws {
    let host = Host(EditingDocument(source: try DocumentTestFixtures.makeImage()))
    let guides = GuideRecorder()
    let overlays = InteractionRecorder()

    let mounted = try await mount(
      ImageEditorCanvas(document: host.binding) { interaction in
        let _ = overlays.inside.append(interaction)
        Color.clear
      } cropOutsideOverlay: { interaction in
        let _ = overlays.outside.append(interaction)
        Color.clear
      }
      .onCropGuideChange { guides.guides.append($0) }
    )
    defer { mounted.window.isHidden = true }

    let canvasView = mounted.canvasView
    let scrollView = canvasView.cropSurface.scrollView

    /// Waits until the overlays have rendered `expected` and the guide
    /// reported it (the guide loaded on mount arrives on a later turn).
    func expectInteraction(
      _ expected: CropInteraction,
      _ comment: Comment,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      for _ in 0..<50 {
        mounted.host.view.layoutIfNeeded()
        if overlays.inside.last == expected, overlays.outside.last == expected,
          guides.guides.last?.interaction == expected
        {
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(overlays.inside.last == expected, comment, sourceLocation: sourceLocation)
      #expect(overlays.outside.last == expected, comment, sourceLocation: sourceLocation)
      #expect(guides.guides.last?.interaction == expected, comment, sourceLocation: sourceLocation)
    }

    try await expectInteraction([], "idle after mounting")
    let guidesBefore = guides.guides.count
    let insideBefore = overlays.inside.count
    let outsideBefore = overlays.outside.count

    canvasView.cropSurface.scrollViewWillBeginDragging(scrollView)
    try await expectInteraction(.movingImage, "dragging the image")

    // A guide resize begins and ends through these, as its gestures do.
    canvasView.guideView.insertInteraction(.resizingGuide)
    try await expectInteraction([.movingImage, .resizingGuide], "a guide resize joins the drag")

    canvasView.cropSurface.scrollViewDidEndDragging(scrollView, willDecelerate: false)
    try await expectInteraction(.resizingGuide, "the resize continues after the drag ends")

    canvasView.cropSurface.scrollViewWillBeginZooming(scrollView, with: nil)
    try await expectInteraction([.movingImage, .resizingGuide], "a pinch joins the resize")

    canvasView.guideView.removeInteraction(.resizingGuide)
    try await expectInteraction(.movingImage, "the pinch continues after the resize ends")

    canvasView.cropSurface.scrollViewDidEndZooming(scrollView, with: nil, atScale: scrollView.zoomScale)
    try await expectInteraction([], "idle once every interaction has ended")

    // Nothing reported idle while an interaction was still in progress: the
    // reports since the drag began hold no empty set before the final ones.
    func whileInteracting(_ reports: some Collection<CropInteraction>) -> [CropInteraction] {
      Array(reports.reversed().drop(while: \.isEmpty).reversed())
    }
    #expect(whileInteracting(guides.guides.dropFirst(guidesBefore).map(\.interaction)).allSatisfy { $0.isEmpty == false })
    #expect(whileInteracting(overlays.inside.dropFirst(insideBefore)).allSatisfy { $0.isEmpty == false })
    #expect(whileInteracting(overlays.outside.dropFirst(outsideBefore)).allSatisfy { $0.isEmpty == false })
  }

  /// A custom editor's host state: the document and the tool.
  @MainActor
  @Observable
  final class ToolHost {
    var document: ImageEditorDocument
    var target: ImageEditorCanvas.Target? = .crop

    init(_ document: ImageEditorDocument) {
      self.document = document
    }
  }

  private struct ToolHostView: View {
    let host: ToolHost
    let box: ProxyBox

    var body: some View {
      ImageEditorCanvasReader { canvas in
        ImageEditorCanvas(document: Binding(get: { host.document }, set: { host.document = $0 }))
          .editingTarget(host.target)
          .onAppear { box.proxy = canvas }
      }
    }
  }

  /// The custom-editor recipe: in the tool button, apply the crop, switch
  /// the tool, then commit. Committing in `onChange(of: target)` instead
  /// would run before the crop the canvas writes when leaving `.crop`.
  @Test func `Applying before switching tools puts the crop in the commit`() async throws {
    let host = ToolHost(EditingDocument(source: try DocumentTestFixtures.makeImage()))
    let box = ProxyBox()

    let mounted = try await mount(ToolHostView(host: host, box: box))
    defer { mounted.window.isHidden = true }

    let canvas = try #require(box.proxy)
    canvas.rotateCounterclockwise()
    // The tool button.
    canvas.applyPendingCrop()
    host.target = .localBlur
    host.document.commit()

    // Let the view update and any deferred canvas write run.
    for _ in 0..<10 {
      mounted.host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(host.document.history.undoStack.count == 1)
    #expect(host.document.hasUncommittedChanges == false, "Leaving .crop must not write a crop after the commit.")
    #expect(host.document.feature.crop.quarterTurn != .zero)
  }

  /// A straighten slider's host state.
  @MainActor
  @Observable
  final class StraightenHost {
    var document: ImageEditorDocument
    var angle: Angle?
    var isEditing = false

    init(_ document: ImageEditorDocument) {
      self.document = document
    }
  }

  private struct StraightenHostView: View {
    let host: StraightenHost

    var body: some View {
      ImageEditorCanvas(document: Binding(get: { host.document }, set: { host.document = $0 }))
        .straightenAngle(host.angle, isEditing: host.isEditing)
    }
  }

  @Test func `Straightening records the crop when the edit ends`() async throws {
    let host = StraightenHost(EditingDocument(source: try DocumentTestFixtures.makeImage()))
    let mounted = try await mount(StraightenHostView(host: host))
    defer { mounted.window.isHidden = true }

    func settle() async throws {
      for _ in 0..<5 {
        mounted.host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    try await settle()
    let level = try #require(mounted.canvasView.proposedCrop)

    // While editing, the canvas shows the angle without recording the crop.
    host.angle = .degrees(10)
    host.isEditing = true
    try await settle()
    let editing = try #require(mounted.canvasView.proposedCrop)
    #expect(editing.adjustmentAngle == .degrees(10))
    #expect(editing.cropExtent == level.cropExtent)

    // Ending the edit records the crop inside the straightened image.
    host.isEditing = false
    try await settle()
    let recorded = try #require(mounted.canvasView.proposedCrop)
    #expect(recorded.adjustmentAngle == .degrees(10))
    #expect(recorded.cropExtent.width < level.cropExtent.width)
    #expect(recorded.cropExtent.height < level.cropExtent.height)
  }

  private struct StraightenReaderView: View {
    let host: StraightenHost
    let box: ProxyBox

    var body: some View {
      ImageEditorCanvasReader { canvas in
        ImageEditorCanvas(document: Binding(get: { host.document }, set: { host.document = $0 }))
          .straightenAngle(host.angle, isEditing: host.isEditing)
          .onAppear { box.proxy = canvas }
      }
    }
  }

  /// Lays the window out over a few main-actor turns.
  private func settle(_ view: UIView) async throws {
    for _ in 0..<5 {
      view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test func `Ending straightening and applying in one action writes the recorded crop`() async throws {
    let host = StraightenHost(EditingDocument(source: try DocumentTestFixtures.makeImage()))
    let box = ProxyBox()
    let mounted = try await mount(StraightenReaderView(host: host, box: box))
    defer { mounted.window.isHidden = true }
    try await settle(mounted.host.view)
    let level = host.document.feature.crop

    host.angle = .degrees(10)
    host.isEditing = true
    try await settle(mounted.host.view)

    // A slider's end handler that also applies and commits: the end of the
    // edit reaches the canvas only on its next update.
    host.isEditing = false
    try #require(box.proxy).applyPendingCrop()
    host.document.commit()
    let written = host.document.feature.crop

    try await settle(mounted.host.view)
    let recorded = try #require(mounted.canvasView.proposedCrop).makeCropFeature()
    #expect(written == recorded)
    #expect(written.straightenRadians == Angle.degrees(10).radians)
    #expect(written.rect.width < level.rect.width)
    #expect(written.rect.height < level.rect.height)
  }

  @Test func `Ending straightening without an angle records the crop at the angle shown`() async throws {
    let host = StraightenHost(EditingDocument(source: try DocumentTestFixtures.makeImage()))
    let mounted = try await mount(StraightenHostView(host: host))
    defer { mounted.window.isHidden = true }
    try await settle(mounted.host.view)
    let level = try #require(mounted.canvasView.proposedCrop)

    host.angle = .degrees(10)
    host.isEditing = true
    try await settle(mounted.host.view)

    host.angle = nil
    host.isEditing = false
    try await settle(mounted.host.view)

    let recorded = try #require(mounted.canvasView.proposedCrop)
    #expect(recorded.adjustmentAngle == .degrees(10))
    #expect(recorded.cropExtent.width < level.cropExtent.width)
    #expect(recorded.cropExtent.height < level.cropExtent.height)
  }

  @Test func `ImageEditor writes nothing on mount`() async throws {
    var document = try DocumentTestFixtures.makeDocument()
    document.feature = DocumentTestFixtures.exposure(1)
    document.commit()
    let host = Host(document)

    let mounted = try await mount(
      ImageEditor(document: host.binding, onDone: {}, onCancel: {})
    )
    defer { mounted.window.isHidden = true }

    // Let deferred canvas work run.
    for _ in 0..<10 {
      mounted.host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(host.writes == 0, "Mounting must not write the document.")
    #expect(host.document == document)
  }
}
