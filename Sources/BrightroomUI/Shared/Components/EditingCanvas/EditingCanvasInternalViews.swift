import UIKit

final class _EditingCanvasScrollView: UIScrollView {}

final class _EditingCanvasAttachmentContentView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "editing-canvas-attachment-content-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class _EditingCanvasViewportCanvasView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "editing-canvas-viewport-canvas-view"
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
