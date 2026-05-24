import UIKit

final class MetalBrushSandboxScrollView: UIScrollView {}

final class MetalBrushSandboxAttachmentContentView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-attachment-content-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class MetalBrushSandboxViewportCanvasView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-viewport-canvas-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class MetalBrushSandboxViewportGestureView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-viewport-gesture-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
