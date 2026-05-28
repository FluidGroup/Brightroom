import CoreGraphics
import CoreImage
import MetalKit
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

final class CropViewportDisplayView: UIView, CropDisplayRenderable {

  let canvasSize: CGSize

  private let canvasView: _EditingCanvasMTKView
  private var currentInputKey: InputKey?

  init?(canvasSize: CGSize) {
    guard canvasSize.width > 0, canvasSize.height > 0 else {
      return nil
    }

    guard let device = MTLCreateSystemDefaultDevice() else {
      return nil
    }

    self.canvasSize = canvasSize
    self.canvasView = _EditingCanvasMTKView(canvasSize: canvasSize, device: device)

    super.init(frame: .zero)

    isUserInteractionEnabled = false
    isHidden = true

    canvasView.isUserInteractionEnabled = false
    canvasView.setViewportCachedSourceEnabled(true)
    addSubview(canvasView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    canvasView.frame = bounds
  }

  func display(_ content: CropDisplayContent) {
    switch content {
    case .empty, .cropInteractionImage:
      isHidden = true

    case let .renderedEditPreview(content):
      isHidden = false
      updateRenderedEditPreview(content)
    }
  }

  func updateViewport(_ viewport: CropDisplayViewport?) {
    guard let viewport else {
      isHidden = true
      return
    }

    frame = viewport.viewportFrameInScrollView
    contentScaleFactor = viewport.contentScaleFactor
    canvasView.contentScaleFactor = viewport.contentScaleFactor
    canvasView.frame = bounds
    canvasView.setViewport(
      visibleContentRect: viewport.visibleContentRect,
      visibleCanvasFrame: viewport.visibleCanvasFrame,
      zoomScale: viewport.zoomScale
    )
  }

  private func updateRenderedEditPreview(_ content: CropRenderedEditPreviewContent) {
    guard content.crop.imageSize == canvasSize else {
      return
    }

    let key = InputKey(content: content)
    guard currentInputKey != key || canvasView.hasRenderImages == false else {
      return
    }

    let renderPlan = RenderPlan(localAdjustments: content.loadedState.currentEdit.localAdjustments)
    guard
      let images = EditingCanvasRenderImageFactory.makeRenderImages(
        loadedState: content.loadedState,
        canvasSize: content.crop.imageSize,
        mode: renderPlan.canvasMode
      )
    else {
      return
    }

    canvasView.setRenderImages(images)
    canvasView.setCommittedStrokes(renderPlan.committedStrokes)
    currentInputKey = key
  }

  private struct InputKey: Equatable {
    var imageSize: CGSize
    var sourceExtent: CGRect
    var filters: EditingStack.Edit.Filters
    var localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]

    init(content: CropRenderedEditPreviewContent) {
      let previewSourceImage = content.loadedState.editingSourceImage.removingExtentOffset()
      self.imageSize = content.crop.imageSize
      self.sourceExtent = previewSourceImage.extent
      self.filters = content.loadedState.currentEdit.filters
      self.localAdjustments = content.loadedState.currentEdit.localAdjustments
    }
  }

  private enum RenderPlan: Equatable {
    case viewportBase
    case singleLocalAdjustment(EditingStack.Edit.LocalAdjustmentLayer)
    case renderedEditPreview

    init(localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]) {
      let activeLayers = localAdjustments.filter {
        $0.isEnabled && $0.effect.isActive && $0.mask.isEmpty == false
      }

      switch activeLayers.count {
      case 0:
        self = .viewportBase
      case 1:
        self = .singleLocalAdjustment(activeLayers[0])
      default:
        self = .renderedEditPreview
      }
    }

    var canvasMode: EditingCanvasMode {
      switch self {
      case .viewportBase:
        return .viewportBase
      case let .singleLocalAdjustment(layer):
        return .localAdjustment(effect: layer.effect)
      case .renderedEditPreview:
        return .renderedEditPreview
      }
    }

    var committedStrokes: [EditingCanvasStrokeRecord] {
      switch self {
      case .viewportBase, .renderedEditPreview:
        return []
      case let .singleLocalAdjustment(layer):
        return layer.mask.strokes.map {
          EditingCanvasStrokeRecord(localAdjustmentStroke: $0)
        }
      }
    }
  }
}
