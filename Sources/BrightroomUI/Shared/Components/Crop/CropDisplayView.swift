import CoreGraphics

/// Describes the content rect that should be drawn into a Metal-backed crop
/// preview surface.
///
/// Crop mode uses source-image coordinates for `visibleContentRect`. Tool modes
/// may use a different display domain, such as the final crop-output image.
struct CropDisplayViewport {
  /// The UIKit frame of the Metal surface in its owning scroll view.
  ///
  /// This can be larger than the visible crop viewport when the renderer needs
  /// overscan pixels for rotation or presentation-layer animation.
  var viewportFrameInScrollView: CGRect

  /// The content-domain rect that should be sampled for the current viewport.
  var visibleContentRect: CGRect

  /// The rect inside the Metal surface where `visibleContentRect` is rendered.
  var visibleCanvasFrame: CGRect

  /// The display scale used to size the Metal drawable.
  var contentScaleFactor: CGFloat
}
