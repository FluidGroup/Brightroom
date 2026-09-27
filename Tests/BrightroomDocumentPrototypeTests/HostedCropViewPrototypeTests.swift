import CoreGraphics
import SwiftUI
import Testing
import UIKit

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Hosts `SwiftUICropView` over a document binding in a window: the view
/// prepares the document's image itself and writes canvas changes back.
@MainActor
struct HostedCropViewPrototypeTests {

  final class Box {
    var document: EditingDocument<PhotosCropFeature>
    var writes = 0
    init(_ document: EditingDocument<PhotosCropFeature>) { self.document = document }
  }

  private func findCropView(in view: UIView) -> CropView? {
    if let cropView = view as? CropView {
      return cropView
    }
    for subview in view.subviews {
      if let found = findCropView(in: subview) {
        return found
      }
    }
    return nil
  }

  @Test func `The canvas prepares the image and writes crop commits into the binding`() async throws {
    let image = try EditingDocumentPrototypeTests.makeImage()
    let box = Box(EditingDocument(image: image))
    let binding = Binding(
      get: { box.document },
      set: { box.document = $0; box.writes += 1 }
    )
    let rotate = SwiftUICropView.RotateAction()
    let apply = SwiftUICropView.ApplyAction()

    let host = UIHostingController(
      rootView: SwiftUICropView(document: binding)
        .registerRotateAction(rotate)
        .registerApplyAction(apply)
    )
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.makeKeyAndVisible()

    var cropView: CropView?
    for _ in 0..<300 {
      host.view.layoutIfNeeded()
      cropView = findCropView(in: host.view)
      if cropView != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let mounted = try #require(cropView, "The canvas never mounted.")
    #expect(mounted.bounds.isEmpty == false)
    #expect(box.writes == 0, "Mounting must not write the document.")

    rotate()
    apply()

    #expect(box.document.feature.crop.rotation != .zero)
    #expect(box.document.hasUncommittedChanges, "SwiftUICropView never commits.")
    #expect(box.document.image == image)

    window.isHidden = true
  }
}
