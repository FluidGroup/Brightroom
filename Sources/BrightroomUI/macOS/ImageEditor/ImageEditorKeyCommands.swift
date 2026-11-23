#if os(macOS)
import SwiftUI

/// The editor's keyboard shortcuts that no visible control holds:
/// Command-plus (or Command-equals) and Command-minus zoom in and out,
/// Command-0 zooms to fit, Control-Command-I shows or hides the adjustments,
/// also after the inspector was collapsed by dragging, and Escape ends the
/// gray point while it is on (Cancel has no key).
///
/// Each shortcut sits on exactly one hidden button, because two buttons with
/// one shortcut match either of them unpredictably. The shortcuts work while
/// the toolbar's items overflow, and while the editor's window is key they
/// take precedence over the host's menu equivalents: the window takes a key
/// before the menu bar does. So in a host that adds `ImageEditorCommands`
/// and `InspectorCommands`, whose items show the same keys, a key runs here
/// and its menu item's action does not run too.
struct ImageEditorKeyCommands: View {

  private let model: ImageEditorModel
  private let localizedStrings: ImageEditor.LocalizedStrings
  private let isLoaded: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The zoom shortcuts work once `isLoaded`; until then the host's menu
  /// equivalents receive them.
  init(
    model: ImageEditorModel,
    localizedStrings: ImageEditor.LocalizedStrings,
    isLoaded: Bool
  ) {
    self.model = model
    self.localizedStrings = localizedStrings
    self.isLoaded = isLoaded
  }

  var body: some View {
    // The buttons are never seen or read; their titles only name them.
    ZStack {
      Group {
        // Command-equals is Command-plus without Shift, which does not match
        // "+".
        Button(localizedStrings.zoomIn) {
          model.zoomIn()
        }
        .keyboardShortcut("=", modifiers: .command)

        Button(localizedStrings.zoomIn) {
          model.zoomIn()
        }
        .keyboardShortcut("+", modifiers: .command)

        Button(localizedStrings.zoomOut) {
          model.zoomOut()
        }
        .keyboardShortcut("-", modifiers: .command)

        Button(localizedStrings.zoomToFit) {
          model.zoomToFit()
        }
        .keyboardShortcut("0", modifiers: .command)
      }
      .disabled(isLoaded == false)

      Button(localizedStrings.adjust) {
        toggleAdjustments()
      }
      .keyboardShortcut("i", modifiers: [.control, .command])

      // Present only while sampling, so Escape reaches the host otherwise.
      if model.grayPointSampling != .off {
        Button(localizedStrings.cancel) {
          model.cancelGrayPointSampling()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// Hides the adjustments while they show, and shows them otherwise, as the
  /// toolbar's Adjust toggle does.
  private func toggleAdjustments() {
    withAnimation(reduceMotion ? nil : .default) {
      if model.selectedTool == .adjust {
        model.select(nil)
      } else {
        model.select(.adjust)
      }
    }
  }
}
#endif
