import CoreImage
import BrightroomEngine
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
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


final class MetalBrushSandboxTiledCanvasView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-tiled-canvas-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class MetalBrushSandboxTiledView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-tiled-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class MetalBrushSandboxSelectionGestureView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    accessibilityIdentifier = "metal-brush-selection-gesture-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class MetalBrushSandboxTiledGestureView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-tiled-gesture-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
