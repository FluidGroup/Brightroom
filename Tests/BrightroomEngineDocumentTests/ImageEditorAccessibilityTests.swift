import CoreGraphics
import SwiftUI
import Testing
import UIKit

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// Hosts `ImageEditor` in a window and drives it through its accessibility
/// elements, as VoiceOver (or a UI test) would.
@MainActor
struct ImageEditorAccessibilityTests {

  @MainActor
  final class Host {
    var document: ImageEditorDocument

    init(_ document: ImageEditorDocument) {
      self.document = document
    }

    var binding: Binding<ImageEditorDocument> {
      Binding(get: { self.document }, set: { self.document = $0 })
    }
  }

  @MainActor
  struct Mounted {
    let window: UIWindow
    let host: UIViewController

    /// Every element in the window's accessibility tree.
    var elements: [NSObject] {
      var elements: [NSObject] = []
      collect(host.view, into: &elements)
      return elements
    }

    /// The element labelled `label`, if one is on screen.
    func element(_ label: String) -> NSObject? {
      elements.first { $0.accessibilityLabel == label }
    }

    /// Lays the window out until `condition` holds.
    func wait(
      until condition: () -> Bool,
      _ comment: Comment,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      for _ in 0..<200 {
        host.view.layoutIfNeeded()
        if condition() {
          return
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      Issue.record(comment, sourceLocation: sourceLocation)
      throw CancellationError()
    }

    private func collect(_ object: NSObject, into elements: inout [NSObject]) {
      elements.append(object)
      if let children = object.accessibilityElements as? [NSObject] {
        for child in children {
          collect(child, into: &elements)
        }
      } else {
        let count = object.accessibilityElementCount()
        if count != NSNotFound {
          for index in 0..<count {
            if let child = object.accessibilityElement(at: index) as? NSObject {
              collect(child, into: &elements)
            }
          }
        }
      }
      if let view = object as? UIView {
        for subview in view.subviews {
          collect(subview, into: &elements)
        }
      }
    }
  }

  private func mount(_ rootView: some View) -> Mounted {
    let host = UIHostingController(rootView: rootView)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = host
    window.makeKeyAndVisible()
    return Mounted(window: window, host: host)
  }

  private static let modeLabels = ["Crop", "Blur Masking", "Filters", "Adjustments"]

  /// The mode and toolbar icon buttons keep their button semantics, so
  /// assistive technologies hear a button, its disabled state, and can
  /// activate it.
  @Test func `Mode and icon buttons are disabled buttons until the image is prepared`() async throws {
    let document = try DocumentTestFixtures.makeDocument()
    let host = Host(document)
    // A preparation that fails leaves the editor unloaded for good.
    let loader = PreviewSourceLoader(source: document.source) { _ in nil }

    let mounted = mount(
      ImageEditorContent(
        document: host.binding,
        previewSourceLoader: loader,
        options: .init(),
        localizedStrings: .init(),
        onDone: {},
        onCancel: nil
      )
    )
    defer { mounted.window.isHidden = true }

    try await mounted.wait(
      until: { loader.phase == .failed && mounted.element("Done").map { $0.accessibilityTraits.contains(.notEnabled) == false } == true },
      "The editor never showed the failed preparation."
    )

    for label in Self.modeLabels + ["Rotate", "Aspect Ratio"] {
      let element = try #require(mounted.element(label), "\(label)")
      #expect(element.accessibilityTraits.contains(.button), "\(label)")
      #expect(element.accessibilityTraits.contains(.notEnabled), "\(label)")
    }
    // Done stays the way out of a failed preparation.
    let done = try #require(mounted.element("Done"))
    #expect(done.accessibilityTraits.contains(.button))
  }

  /// The aspect-ratio toggle and a mode button activate through
  /// accessibility. (Elements inside a SwiftUI `ScrollView`, such as the
  /// filter swatches, are not in the tree a test reads without the
  /// accessibility runtime, so they are not checked here.)
  @Test func `Editor buttons are buttons that activate`() async throws {
    let host = Host(try DocumentTestFixtures.makeDocument())
    let mounted = mount(ImageEditor(document: host.binding, onDone: {}))
    defer { mounted.window.isHidden = true }

    func isEnabledButton(_ label: String) -> Bool {
      guard let element = mounted.element(label) else {
        return false
      }
      return element.accessibilityTraits.contains(.button)
        && element.accessibilityTraits.contains(.notEnabled) == false
    }

    try await mounted.wait(until: { isEnabledButton("Filters") }, "The editor never prepared the image.")
    for label in Self.modeLabels + ["Rotate", "Aspect Ratio"] {
      #expect(isEnabledButton(label), "\(label)")
    }
    #expect(mounted.element("Crop")?.accessibilityValue == "selected")

    // The aspect-ratio toggle shows the orientation chips.
    #expect(try #require(mounted.element("Aspect Ratio")).accessibilityActivate())
    try await mounted.wait(until: { mounted.element("Horizontal") != nil }, "Aspect Ratio did not open.")
    #expect(mounted.element("Horizontal")?.accessibilityTraits.contains(.button) == true)
    #expect(mounted.element("Vertical")?.accessibilityTraits.contains(.button) == true)

    #expect(try #require(mounted.element("Filters")).accessibilityActivate())
    try await mounted.wait(
      until: { mounted.element("Filters")?.accessibilityValue == "selected" && mounted.element("Rotate") == nil },
      "Activating Filters did not select it."
    )
    #expect(mounted.element("Crop")?.accessibilityValue == "not selected")
    #expect(isEnabledButton("Crop"))
  }
}
