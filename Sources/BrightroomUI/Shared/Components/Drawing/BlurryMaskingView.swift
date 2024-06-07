//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

#if !COCOAPODS
import BrightroomEngine
#endif
import Verge

public final class BlurryMaskingView: PixelEditorCodeBasedView, UIScrollViewDelegate {

  private struct State: Equatable {
    fileprivate(set) var bounds: CGRect = .zero

    fileprivate(set) var proposedCrop: EditingCrop?
    
    fileprivate(set) var brushSize: CanvasView.BrushSize = .point(30)

    func brushPixelSize() -> CGFloat? {

      guard let proposedCrop = proposedCrop else {
        return nil
      }

      let aspectRatio = PixelAspectRatio(proposedCrop.cropExtent.size)
      let size = aspectRatio.sizeThatFits(in: bounds.size)
      
      let (min, _) = proposedCrop.calculateZoomScale(visibleSize: size)

      let scale = proposedCrop.scaleForDrawing()

      switch brushSize {
      case let .point(points):
        return points / scale / min
      case let .pixel(pixels):
        return pixels
      }
    }
  }
  
  private final class ContainerView: PixelEditorCodeBasedView {
    func addContent(_ view: UIView) {
      addSubview(view)
      view.frame = bounds
      view.autoresizingMask = [.flexibleHeight, .flexibleWidth]
    }
  }
  
  public var isBackdropImageViewHidden: Bool {
    get {
      backingView.isImageViewHidden
    }
    set {
      backingView.isImageViewHidden = newValue
    }
  }
  
  public var isBlurryImageViewHidden: Bool {
    get {
      blurryImageView.isHidden
    }
    set {
      blurryImageView.isHidden = newValue
    }
  }

  private let backingView: CropView

  private let containerView = ContainerView()

  private let blurryImageView = _ImageView()
  
  private let drawingView = SmoothPathDrawingView()
  
  private let canvasView = CanvasView()
  
  private var subscriptions = Set<AnyCancellable>()
  
  private let editingStack: EditingStack

  private let store: UIStateStore<State, Never>
  
  private var currentBrush: OvalBrush?
  
  private var loadingOverlayFactory: (() -> UIView)?
  private weak var currentLoadingOverlay: UIView?
  
  private var isBinding = false
  
  // MARK: - Initializers
  
  public init(editingStack: EditingStack) {
    
    self.editingStack = editingStack
    self.backingView = .init(
      editingStack: editingStack,
      contentInset: .zero
    )
    self.backingView.areAnimationsEnabled = false
    self.backingView.accessibilityIdentifier = "BlurryMasking"

    store = .init(
      initialState: .init(),
      logger: nil
    )
            
    super.init(frame: .zero)
    
    setUp: do {
      backgroundColor = .clear
      
      addSubview(backingView)
      backingView.isGuideInteractionEnabled = false
      backingView.clipsToGuide = true
      backingView.setCropOutsideOverlay(nil)
      backingView.setCropInsideOverlay(nil)
      backingView.setOverlayInImageView(containerView)
      backingView.isScrollEnabled = false
      backingView.isZoomEnabled = false
      backingView.isAutoApplyEditingStackEnabled = false

      containerView.addContent(blurryImageView)
      containerView.addContent(canvasView)
      containerView.addContent(drawingView)
      
      blurryImageView.accessibilityIdentifier = "blurryImageView"
      blurryImageView.isUserInteractionEnabled = false
      blurryImageView.contentMode = .scaleAspectFit
      
      blurryImageView.mask = canvasView
      clipsToBounds = true
    }
    
    drawingView.handlers = drawingView.handlers&>.modify {
      $0.willBeginPan = { [unowned self] path in
        
        guard let pixelSize = store.state.primitive.brushPixelSize() else {
          assertionFailure("It seems currently loading state.")
          return
        }
        
        currentBrush = .init(color: .black, pixelSize: pixelSize)

        let drawnPath = DrawnPath(brush: currentBrush!, path: path)
        canvasView.previewDrawnPath = drawnPath
      }
      $0.panning = { [unowned self] path in
        canvasView.updatePreviewDrawing()
      }
      $0.didFinishPan = { [unowned self] path in
        canvasView.updatePreviewDrawing()
        
        let _path = (path.copy() as! UIBezierPath)
        
        let drawnPath = DrawnPath(brush: currentBrush!, path: _path)
        
        canvasView.previewDrawnPath = nil
        editingStack.append(blurringMaskPaths: CollectionOfOne(drawnPath))
        
        currentBrush = nil
      }
    }
    
    editingStack.sinkState { [weak self] (state: Changes<EditingStack.State>) in
      
      guard let self = self else { return }
      
      if let state = state.mapIfPresent(\.loadedState) {

        state.ifChanged(\.currentEdit.crop).do { cropRect in

          // scaling for drawing paths
          [self.canvasView, self.drawingView].forEach { view in
            view.bounds = .init(origin: .zero, size: cropRect.imageSize)
            let scale = Geometry.diagonalRatio(to: cropRect.scrollViewContentSize(), from: cropRect.imageSize)
            view.transform = .init(scaleX: scale, y: scale)
            view.frame.origin = .zero
          }

          /**
           To avoid running pending layout operations from User Initiated actions.
           */
          if cropRect != self.store.state.proposedCrop {
            self.store.commit {
              $0.proposedCrop = cropRect
            }
          }
        }
      }
      
    }
    .store(in: &subscriptions)
    
    defaultAppearance: do {
      setLoadingOverlay(factory: {
        LoadingBlurryOverlayView(effect: UIBlurEffect(style: .dark), activityIndicatorStyle: .large)
      })
    }
  }

  override public func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    
    guard newSuperview != nil else { return }
    
    if isBinding == false {
      isBinding = true
      
      editingStack.start()
      
      binding: do {

        editingStack.sinkState { [weak self] (state: Changes<EditingStack.State>) in
          
          guard let self = self else { return }        
          
          if let state = state.mapIfPresent(\.loadedState) {
            
            state.ifChanged(\.editingPreviewImage).do { image in
              self.blurryImageView.display(image: BlurredMask.blur(image: image))
            }
            
            state.ifChanged(\.currentEdit.drawings.blurredMaskPaths).do { paths in
              self.canvasView.setResolvedDrawnPaths(paths)
            }
            
          }
       
        }
        .store(in: &subscriptions)
      }
    }
  }
  
  public func setLoadingOverlay(factory: (() -> UIView)?) {
    _pixeleditor_ensureMainThread()
    loadingOverlayFactory = factory
  }
    
  public func setBrushSize(_ size: CanvasView.BrushSize) {
    store.commit {
      $0.brushSize = size
    }
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    backingView.frame = bounds

    store.commit {
      if $0.bounds != bounds {
        $0.bounds = bounds
      }
    }
    
  }
}

import SwiftUI

public struct SwiftUIBlurryMaskingView: UIViewControllerRepresentable {

  public typealias UIViewControllerType = _PixelEditor_WrapperViewController<BlurryMaskingView>

  private let editingStack: EditingStack

  private var _brushSize: CanvasView.BrushSize?

  private var _isBackdropImageViewHidden: Bool?
  private var _isBlurryImageViewHidden: Bool?

  public init(
    editingStack: EditingStack
  ) {
    self.editingStack = editingStack
  }
  
  public func makeUIViewController(context: Context) -> _PixelEditor_WrapperViewController<BlurryMaskingView> {

    let view = BlurryMaskingView(editingStack: editingStack)

    let controller = _PixelEditor_WrapperViewController.init(bodyView: view)

    return controller
  }

  public func updateUIViewController(_ uiViewController: _PixelEditor_WrapperViewController<BlurryMaskingView>, context: Context) {

    if let _brushSize {
      uiViewController.bodyView.setBrushSize(_brushSize)
    }
    if let _isBackdropImageViewHidden {
      uiViewController.bodyView.isBackdropImageViewHidden = _isBackdropImageViewHidden
    }
    if let _isBlurryImageViewHidden {
      uiViewController.bodyView.isBlurryImageViewHidden = _isBlurryImageViewHidden
    }
  }

  public func blushSize(_ brushSize: CanvasView.BrushSize) -> Self {

    var modified = self
    modified._brushSize = brushSize
    return modified
  }

  public func hideBackdropImageView(_ isBackdropImageViewHidden: Bool) -> Self {

    var modified = self
    modified._isBackdropImageViewHidden = isBackdropImageViewHidden
    return modified
  }

  public func hideBlurryImageView(_ isBlurryImageViewHidden: Bool) -> Self {

    var modified = self
    modified._isBlurryImageViewHidden = isBlurryImageViewHidden
    return modified
  }

}
