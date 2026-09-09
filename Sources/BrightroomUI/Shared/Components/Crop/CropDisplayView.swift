import CoreGraphics

/// One frame of the mapping from an editing domain into a fixed Metal canvas.
///
/// Crop uses source-image coordinates; Tool uses its evaluated output domain.
/// Both domains and the canvas use top-left, y-down coordinates. The affine
/// transform retains rotation as well as pan and zoom; the bounding rectangles
/// only limit rendering work and must not be used to reconstruct that transform.
struct CropDisplayViewport {

  /// The conservative content bounds sampled by this frame.
  let visibleContentRect: CGRect

  /// The complete mapping used by both image rendering and pointer conversion.
  let contentToCanvasTransform: CGAffineTransform

  /// The display scale used to size the fixed canvas's drawable.
  let contentScaleFactor: CGFloat

  /// The axis-aligned enclosure of sampled content on the canvas.
  var visibleCanvasFrame: CGRect {
    visibleContentRect.applying(contentToCanvasTransform)
  }

  /// Creates a viewport only when the mapping is invertible and intersects
  /// the canvas. The inverse enclosure deliberately includes extra content
  /// under rotation so rotated corners cannot disappear at the viewport edge.
  init?(
    contentBounds: CGRect,
    canvasBounds: CGRect,
    contentToCanvasTransform: CGAffineTransform,
    contentScaleFactor: CGFloat
  ) {
    let values = [
      contentBounds.minX, contentBounds.minY, contentBounds.width, contentBounds.height,
      canvasBounds.minX, canvasBounds.minY, canvasBounds.width, canvasBounds.height,
      contentToCanvasTransform.a, contentToCanvasTransform.b,
      contentToCanvasTransform.c, contentToCanvasTransform.d,
      contentToCanvasTransform.tx, contentToCanvasTransform.ty,
      contentScaleFactor,
    ]
    let determinant = contentToCanvasTransform.a * contentToCanvasTransform.d
      - contentToCanvasTransform.b * contentToCanvasTransform.c
    guard values.allSatisfy(\.isFinite),
          contentBounds.isInfinite == false, canvasBounds.isInfinite == false,
          contentBounds.width > 0, contentBounds.height > 0,
          canvasBounds.width > 0, canvasBounds.height > 0,
          contentScaleFactor > 0,
          determinant.isFinite, abs(determinant) > 1e-12
    else {
      return nil
    }

    let visible = canvasBounds
      .applying(contentToCanvasTransform.inverted())
      .intersection(contentBounds)
    guard visible.isNull == false, visible.isEmpty == false else {
      return nil
    }

    self.visibleContentRect = visible
    self.contentToCanvasTransform = contentToCanvasTransform
    self.contentScaleFactor = contentScaleFactor
  }

  /// Resolves a canvas point using the exact mapping of the displayed frame.
  func contentPoint(fromCanvasPoint point: CGPoint) -> CGPoint {
    point.applying(contentToCanvasTransform.inverted())
  }

  /// Reconstructs an affine mapping from three corresponding content corners.
  ///
  /// The corners are the mapped origin, (width, 0), and (0, height) of a
  /// positive-sized content domain. Sampling points instead of a converted
  /// rectangle preserves the orientation of the image's two basis vectors.
  static func contentTransform(
    contentSize: CGSize,
    origin: CGPoint,
    horizontalCorner: CGPoint,
    verticalCorner: CGPoint
  ) -> CGAffineTransform {
    .init(
      a: (horizontalCorner.x - origin.x) / contentSize.width,
      b: (horizontalCorner.y - origin.y) / contentSize.width,
      c: (verticalCorner.x - origin.x) / contentSize.height,
      d: (verticalCorner.y - origin.y) / contentSize.height,
      tx: origin.x,
      ty: origin.y
    )
  }
}
