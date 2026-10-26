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

  private static let modeLabels = ["Crop", "Blur Masking", "Filters", "Adjustments"]

  /// The mode and toolbar icon buttons keep their button semantics, so
  /// assistive technologies hear a button, its disabled state, and can
  /// activate it.
  @Test func `Mode and icon buttons are disabled buttons until the image is prepared`() async throws {
    let document = try DocumentTestFixtures.makeDocument()
    let host = Host(document)
    // A preparation that fails leaves the editor unloaded for good.
    let loader = PreviewSourceLoader(source: document.source) { _ in nil }

    let mounted = mountEditor(
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
    let mounted = mountEditor(ImageEditor(document: host.binding, onDone: {}))
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

  /// A document can open with a blur whose mask the editor cannot paint (a
  /// host restored an inverted brush). Blur stays selectable: the canvas
  /// paints nothing and the brush size is disabled, and Clear removes the
  /// blur, after which Blur paints again.
  @Test func `Blur mode clears a blur the editor cannot paint`() async throws {
    var document = try DocumentTestFixtures.makeDocument()
    let stroke = BrushMask.Stroke(
      stampCenters: [CGPoint(x: 10, y: 20)],
      brush: .init(diameter: 8, hardness: 1, opacity: 1)
    )
    document.feature.localBlur = LocalAdjustmentFeature(
      mask: .inverted(.brush(BrushMask(strokes: [stroke])))
    ) {
      GaussianBlurFeature(radius: .absolute(4))
    }
    #expect(document.feature.isLocalBlurPaintable == false)
    let host = Host(document)
    let mounted = mountEditor(ImageEditor(document: host.binding, onDone: {}))
    defer { mounted.window.isHidden = true }

    func isEnabled(_ label: String) -> Bool? {
      mounted.element(label).map { $0.accessibilityTraits.contains(.notEnabled) == false }
    }

    try await mounted.wait(until: { isEnabled("Blur Masking") == true }, "Blur never became selectable.")
    #expect(try #require(mounted.element("Blur Masking")).accessibilityActivate())
    try await mounted.wait(until: { mounted.element("Clear Blur Mask") != nil }, "Blur shows no Clear.")

    #expect(isEnabled("Clear Blur Mask") == true)
    // The brush size is the only slider in Blur.
    let brushSize = try #require(findSlider(in: mounted.host.view))
    #expect(brushSize.isEnabled == false)
    #expect(brushSize.accessibilityTraits.contains(.notEnabled))
    let canvasView = try #require(find(EditingCanvasView.self, in: mounted.host.view))
    let drawing = canvasView.toolSurface.drawingGestureRecognizer
    #expect(drawing.isEnabled == false, "The canvas does not paint this blur.")

    #expect(try #require(mounted.element("Clear Blur Mask")).accessibilityActivate())
    try await mounted.wait(
      until: { host.document.feature.localBlur == nil && brushSize.isEnabled },
      "Clear did not remove the blur."
    )
    #expect(brushSize.accessibilityTraits.contains(.notEnabled) == false)
    #expect(drawing.isEnabled, "Blur paints once the blur is removed.")
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

  /// Each control keeps its own identifier inside the editor's
  /// `image-editor` container, so UI tests can find a mode button.
  @Test func `Controls keep their own accessibility identifiers`() async throws {
    let host = Host(try DocumentTestFixtures.makeDocument())
    let mounted = mountEditor(ImageEditor(document: host.binding, onDone: {}))
    defer { mounted.window.isHidden = true }

    try await mounted.wait(
      until: { mounted.element("Blur Masking").map { $0.accessibilityTraits.contains(.notEnabled) == false } == true },
      "The editor never prepared the image."
    )
    let identifiers = [
      "Crop": "image-editor.mode.crop",
      "Blur Masking": "image-editor.mode.local-blur",
      "Filters": "image-editor.mode.filters",
      "Adjustments": "image-editor.mode.adjust",
      "Rotate": "image-editor.rotate",
      "Done": "image-editor.done",
    ]
    for (label, identifier) in identifiers {
      #expect(identifierOf(mounted.element(label)) == identifier, "\(label)")
    }
    #expect(mounted.elements.contains { identifierOf($0) == "image-editor" })

    #expect(try #require(mounted.element("Blur Masking")).accessibilityActivate())
    try await mounted.wait(until: { mounted.element("Clear Blur Mask") != nil }, "Blur shows no Clear.")
    #expect(identifierOf(mounted.element("Clear Blur Mask")) == "image-editor.local-blur.clear")
  }

  /// The element's `accessibilityIdentifier`. SwiftUI's elements implement
  /// it without declaring `UIAccessibilityIdentification`.
  private func identifierOf(_ element: NSObject?) -> String? {
    let selector = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
    guard let element, element.responds(to: selector) else {
      return nil
    }
    return element.perform(selector)?.takeUnretainedValue() as? String
  }
}
