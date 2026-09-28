import CoreGraphics
import SwiftUI
import Testing
import UIKit

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Hosts the editors over a document binding in a window: they prepare the
/// document's image themselves, write nothing on mount, and write canvas
/// changes back without committing.
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
    let rotate = ImageEditorCanvas.RotateAction()
    let apply = ImageEditorCanvas.ApplyAction()

    let mounted = try await mount(
      ImageEditorCanvas(document: host.binding)
        .registerRotateAction(rotate)
        .registerApplyAction(apply)
    )
    defer { mounted.window.isHidden = true }

    #expect(mounted.canvasView.bounds.isEmpty == false)
    #expect(host.writes == 0, "Mounting must not write the document.")

    rotate()
    apply()

    #expect(host.writes == 1)
    #expect(host.document.feature.crop.quarterTurn != .zero)
    #expect(host.document.hasUncommittedChanges, "ImageEditorCanvas never commits.")
    #expect(host.document.source == image)
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
    let rotate: ImageEditorCanvas.RotateAction
    let apply: ImageEditorCanvas.ApplyAction

    var body: some View {
      ImageEditorCanvas(document: Binding(get: { host.document }, set: { host.document = $0 }))
        .editingTarget(host.target)
        .registerRotateAction(rotate)
        .registerApplyAction(apply)
    }
  }

  /// The custom-editor recipe: in the tool button, apply the crop, switch
  /// the tool, then commit. Committing in `onChange(of: target)` instead
  /// would run before the crop the canvas writes when leaving `.crop`.
  @Test func `Applying before switching tools puts the crop in the commit`() async throws {
    let host = ToolHost(EditingDocument(source: try DocumentTestFixtures.makeImage()))
    let rotate = ImageEditorCanvas.RotateAction()
    let apply = ImageEditorCanvas.ApplyAction()

    let mounted = try await mount(ToolHostView(host: host, rotate: rotate, apply: apply))
    defer { mounted.window.isHidden = true }

    rotate()
    // The tool button.
    apply()
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
