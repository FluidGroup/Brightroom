import UIKit

final class _EditingCanvasScrollView: UIScrollView {}

/// A canvas-coordinate content view owned by `UIScrollView` zooming.
///
/// Subviews of this view participate in UIKit's native zoom and zoom-bounce
/// transform. Renderers placed inside it should keep their own drawable sizing
/// explicit so the scroll view never forces a full-canvas Metal surface.
final class _EditingCanvasZoomContentView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "editing-canvas-zoom-content-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class _EditingCanvasViewportGestureView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "editing-canvas-viewport-gesture-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
