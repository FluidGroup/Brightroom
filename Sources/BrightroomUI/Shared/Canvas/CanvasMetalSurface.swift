import CoreGraphics
import Metal

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

typealias CanvasStrokeCommitHandler = (
  EditingCanvasStrokeRecord,
  @escaping () -> Void
) -> Void

/// Owns the Metal canvas view of a surface and draws frames into it.
///
/// It is platform-neutral: the UIKit crop and tool surfaces
/// (`EditingCanvasView.CanvasSurface`) add their scroll views on top of it,
/// and an AppKit canvas uses it with `CanvasNavigation`. The canvas view sits
/// in a fixed host view and never moves; each frame places its pixels with
/// the viewport passed to `draw(viewport:postCrop:)`.
@MainActor
class CanvasMetalSurface: NSObject {
  var canvasView: EditingCanvasMTKView?
  var canvasSize: CGSize?
  /// The mapping of the last frame submitted for display, also used to
  /// map drawing gestures back into the surface's editing domain.
  var displayedViewport: CanvasViewport?

  @discardableResult
  func ensureCanvasView(
    in hostView: PlatformView,
    canvasSize: CGSize,
    brush: EditingCanvasBrush,
    smoothing: ImageEditorCanvas.Brush.Smoothing,
    onStrokeCommit: @escaping CanvasStrokeCommitHandler
  ) -> EditingCanvasMTKView? {
    if let canvasView, self.canvasSize == canvasSize {
      return canvasView
    }

    removeCanvasView()

    guard
      canvasSize.width > 0,
      canvasSize.height > 0,
      let device = MTLCreateSystemDefaultDevice()
    else {
      return nil
    }

    let view = EditingCanvasMTKView(canvasSize: canvasSize, device: device)
    #if os(iOS)
    view.isUserInteractionEnabled = false
    #endif
    view.isHidden = true
    view.configure(brush: brush, smoothing: smoothing)
    view.onStrokeCommit = onStrokeCommit
    view.frame = hostView.bounds
    hostView.addSubview(view)
    canvasView = view
    self.canvasSize = canvasSize
    return view
  }

  func removeCanvasView() {
    displayedViewport = nil
    canvasView?.removeFromSuperview()
    canvasView = nil
    canvasSize = nil
  }

  func hideCanvasView() {
    canvasView?.isHidden = true
    // A hidden canvas draws nothing, so it keeps no drawable-size image
    // under the post-crop pass (the crop surface after crop editing).
    canvasView?.releasePreFinishCache()
  }

  func configureCanvas(
    brush: EditingCanvasBrush,
    smoothing: ImageEditorCanvas.Brush.Smoothing
  ) {
    canvasView?.configure(brush: brush, smoothing: smoothing)
  }

  func setCommittedStrokes(_ records: [EditingCanvasStrokeRecord]) {
    canvasView?.setCommittedStrokes(records)
  }

  /// Shows the crop output of `source` under `effects`. Render images are
  /// rebuilt only when `key` changes; committed strokes are always applied.
  ///
  /// Does nothing until the canvas view exists at `geometry.outputSize`.
  ///
  /// - Parameter key: The inputs of the current render images. It is
  ///   updated when the images are rebuilt; pass nil to force a rebuild.
  func updateCropOutput(
    source: EditingCanvasSource,
    effects: ImageEditorFeature.Effects,
    geometry: EditingCanvasCropOutputGeometry,
    mode: EditingCanvasMode,
    committedStrokes: [EditingCanvasStrokeRecord],
    key: inout CanvasRenderInputKey?
  ) {
    guard geometry.outputSize == canvasSize, let canvasView else {
      return
    }

    let inputKey = CanvasRenderInputKey(
      sourceImage: ObjectIdentifier(source.editingSourceImage),
      effects: effects,
      geometry: geometry,
      mode: mode
    )

    // Hosts call this on every state update (stroke commits, brush changes,
    // unrelated SwiftUI re-renders). Rebuilding identical render-image graphs
    // would discard the canvas's viewport texture caches each time.
    if key != inputKey || canvasView.hasRenderImages == false {
      guard
        let images = EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
          editingSourceImage: source.editingSourceImage,
          effects: effects.canvasEffect,
          geometry: geometry,
          mode: mode
        )
      else {
        return
      }

      canvasView.setRenderImages(images)
      key = inputKey
    }

    canvasView.setCommittedStrokes(committedStrokes)
    canvasView.isHidden = false
  }

  /// Samples the viewport and submits a changed frame without moving the canvas.
  ///
  /// - Parameter postCrop: The pass drawn after the crop, sampled with
  ///   `viewport`, or nil when the feature has none.
  func draw(viewport: CanvasViewport?, postCrop: CanvasPostCrop?) {
    guard let canvasView else { return }
    displayedViewport = viewport
    guard let viewport else {
      canvasView.isHidden = true
      canvasView.releasePreFinishCache()
      return
    }
    canvasView.isHidden = false
    #if os(iOS)
    if canvasView.contentScaleFactor != viewport.contentScaleFactor {
      canvasView.contentScaleFactor = viewport.contentScaleFactor
    }
    #endif
    canvasView.setViewport(viewport.editingCanvasViewport)
    canvasView.setPostCrop(
      effect: postCrop?.effect,
      frame: postCrop?.frame ?? .null,
      chainEntry: postCrop?.chainEntry ?? .null
    )
    canvasView.drawIfNeeded()
  }
}
