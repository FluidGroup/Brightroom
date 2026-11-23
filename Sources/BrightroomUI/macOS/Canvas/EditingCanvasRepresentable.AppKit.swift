#if os(macOS)
import BrightroomParametric
import SwiftUI

/// Hosts the AppKit `EditingCanvasView` once the image and the document are
/// available. The canvas views only, so nothing is written back.
struct EditingCanvasRepresentable: NSViewRepresentable {

  let source: EditingCanvasSource
  let feature: ImageEditorFeature
  var adjustmentRendering: AdjustmentRendering = .standard
  let areAnimationsEnabled: Bool
  /// Not edited on macOS yet; a non-nil target is reported once in the log.
  let editingTarget: ImageEditorCanvas.Target?

  func makeNSView(context: Context) -> EditingCanvasView {
    let view = EditingCanvasView(source: source, feature: feature)
    view.setAdjustmentRendering(adjustmentRendering)
    view.areAnimationsEnabled = areAnimationsEnabled
    view.reportEditingTarget(editingTarget)
    return view
  }

  func updateNSView(_ canvasView: EditingCanvasView, context: Context) {
    canvasView.areAnimationsEnabled = areAnimationsEnabled
    canvasView.setAdjustmentRendering(adjustmentRendering)
    canvasView.setFeature(feature)
    canvasView.reportEditingTarget(editingTarget)
  }

  static func dismantleNSView(_ canvasView: EditingCanvasView, coordinator: ()) {
    canvasView.invalidate()
  }
}
#endif
