import CoreGraphics

/// Describes the source-image rect that should be drawn into a Metal-backed
/// crop preview surface.
struct CropDisplayViewport {
  /// The UIKit frame of the Metal surface in its owning scroll view.
  ///
  /// This can be larger than the visible crop viewport when the renderer needs
  /// overscan pixels for rotation or presentation-layer animation.
  var viewportFrameInScrollView: CGRect

  /// The source-image rect that should be sampled for the current viewport.
  var visibleContentRect: CGRect

  /// The rect inside the Metal surface where `visibleContentRect` is rendered.
  var visibleCanvasFrame: CGRect

  /// The scroll-view zoom scale represented by this viewport.
  var zoomScale: CGFloat

  /// The display scale used to size the Metal drawable.
  var contentScaleFactor: CGFloat
}
