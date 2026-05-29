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

struct CropDisplayViewport {
  var viewportFrameInScrollView: CGRect
  var visibleContentRect: CGRect
  var visibleCanvasFrame: CGRect
  var zoomScale: CGFloat
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
