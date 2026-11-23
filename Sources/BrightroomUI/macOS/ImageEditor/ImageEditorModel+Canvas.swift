#if os(macOS)

/// The zoom commands of the toolbar and the keyboard. Each goes to the canvas
/// registered in `canvasRegistry`, and does nothing until one has registered.
extension ImageEditorModel {

  /// Zooms in by `EditingCanvasView.zoomStepFactor` about the centre.
  func zoomIn() {
    canvasRegistry.canvasView?.zoomIn()
  }

  /// Zooms out by `EditingCanvasView.zoomStepFactor` about the centre.
  func zoomOut() {
    canvasRegistry.canvasView?.zoomOut()
  }

  func zoomToFit() {
    canvasRegistry.canvasView?.zoomToFit()
  }

  /// Zooms at once to `fraction` of the way from the fit to the largest zoom
  /// (`ImageEditorCanvas.Zoom.fraction`).
  func setZoomFraction(_ fraction: Double) {
    canvasRegistry.canvasView?.zoom(toFraction: fraction)
  }
}

#endif
