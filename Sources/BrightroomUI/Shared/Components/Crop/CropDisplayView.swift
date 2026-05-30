import CoreGraphics
import UIKit

import BrightroomEngine

protocol CropDisplayRenderable: AnyObject {
  func display(_ content: CropDisplayContent)
  func updateViewport(_ viewport: CropDisplayViewport?)
}

typealias CropDisplayView = UIView & CropDisplayRenderable

enum CropDisplayContent {
  case empty
  case cropInteractionImage(CGImage)
  case renderedEditPreview(CropRenderedEditPreviewContent)
}

struct CropRenderedEditPreviewContent {
  var loadedState: EditingStack.Loaded
  var crop: EditingCrop
}

/// Describes the source-image rect that should be drawn into a Metal-backed
/// crop preview surface.
struct CropDisplayViewport {
  /// The UIKit frame of the Metal surface in its owning scroll view.
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

extension CropView.ImagePlatterView: CropDisplayRenderable {
  func display(_ content: CropDisplayContent) {
    switch content {
    case let .cropInteractionImage(image):
      self.image = UIImage(cgImage: image, scale: 1, orientation: .up)
      imageView.isHidden = false

    case .empty, .renderedEditPreview:
      image = nil
      imageView.isHidden = true
    }
  }

  func updateViewport(_ viewport: CropDisplayViewport?) {}
}
