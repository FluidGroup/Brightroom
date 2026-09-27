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
    var document: EditingDocument<PhotosCropFeature>
    private(set) var writes = 0

    init(_ document: EditingDocument<PhotosCropFeature>) {
      self.document = document
    }

    var binding: Binding<EditingDocument<PhotosCropFeature>> {
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

  /// Shows `rootView` in a window and waits until a `CropView` is mounted.
  private func mount(
    _ rootView: some View
  ) async throws -> (window: UIWindow, host: UIViewController, cropView: CropView) {
    let host = UIHostingController(rootView: rootView)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.makeKeyAndVisible()

    for _ in 0..<300 {
      host.view.layoutIfNeeded()
      if let cropView = find(CropView.self, in: host.view) {
        return (window, host, cropView)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    window.isHidden = true
    Issue.record("The canvas never mounted.")
    throw CancellationError()
  }

  @Test func `The crop canvas prepares the image and writes crop commits without committing`() async throws {
    let image = try DocumentTestFixtures.makeImage()
    let host = Host(EditingDocument(image: image))
    let rotate = SwiftUICropView.RotateAction()
    let apply = SwiftUICropView.ApplyAction()

    let mounted = try await mount(
      SwiftUICropView(document: host.binding)
        .registerRotateAction(rotate)
        .registerApplyAction(apply)
    )
    defer { mounted.window.isHidden = true }

    #expect(mounted.cropView.bounds.isEmpty == false)
    #expect(host.writes == 0, "Mounting must not write the document.")

    rotate()
    apply()

    #expect(host.writes == 1)
    #expect(host.document.feature.crop.rotation != .zero)
    #expect(host.document.hasUncommittedChanges, "SwiftUICropView never commits.")
    #expect(host.document.image == image)
  }

  @Test func `The PhotosCrop editor writes nothing on mount`() async throws {
    var document = try DocumentTestFixtures.makeDocument()
    document.feature = DocumentTestFixtures.exposure(1)
    document.commit()
    let host = Host(document)

    let mounted = try await mount(
      SwiftUIPhotosCropView(document: host.binding, onDone: {}, onCancel: {})
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
