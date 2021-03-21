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
import PixelEngine
#endif
import Verge

public final class BlurryMaskingView: PixelEditorCodeBasedView, UIScrollViewDelegate {

  private struct State: Equatable {
    
    fileprivate(set) var frame: CGRect = .zero
    fileprivate(set) var bounds: CGRect = .zero
    
    fileprivate var hasLoaded = false
    
    fileprivate(set) var proposedCrop: EditingCrop
    
    fileprivate(set) var brushSize: CanvasView.BrushSize  = .point(30)
    
    fileprivate let contentInset: UIEdgeInsets = .zero
    
    func scrollViewFrame() -> CGRect {
      
      let bounds = self.bounds.inset(by: contentInset)
      
      let size: CGSize
      let aspectRatio = PixelAspectRatio(proposedCrop.cropExtent.size)
      switch proposedCrop.rotation {
      case .angle_0:
        size = aspectRatio.sizeThatFits(in: bounds.size)
      case .angle_90:
        size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
      case .angle_180:
        size = aspectRatio.sizeThatFits(in: bounds.size)
      case .angle_270:
        size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
      }
      
      return .init(
        origin: .init(
          x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
          y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
        ),
        size: size
      )
    }
    
    func brushPixelSize() -> CGFloat {
      
      let (min, _) = proposedCrop.calculateZoomScale(scrollViewSize: scrollViewFrame().size)
      
      switch brushSize {
      case .point(let points):
        return points / min
      case .pixel(let pixels):
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
      backdropImageView.isHidden
    }
    set {
      backdropImageView.isHidden = newValue
    }
  }
      
  private let scrollView = CropView._CropScrollView()
  
  private let containerView = ContainerView()
  
  private let backdropImageView = _ImageView()
  
  private let blurryImageView = _ImageView()
  
  private let drawingView = SmoothPathDrawingView()
  
  private let canvasView = CanvasView()
  
  private var subscriptions = Set<VergeAnyCancellable>()
  
  private let editingStack: EditingStack
  private let imageSize: CGSize
  private var crop: EditingCrop
  
  private var hasSetupScrollViewCompleted = false
  
  private let store: UIStateStore<State, Never>
  
  private var currentBrush: OvalBrush?
  
  private var isBinding = false
  
  // MARK: - Initializers
  
  public init(editingStack: EditingStack) {
    
    self.editingStack = editingStack
    self.store = .init(initialState: .init(proposedCrop: editingStack.state.currentEdit.crop), logger: nil)
        
    let state = editingStack.state
    
    imageSize = state.imageSize
    crop = state.currentEdit.crop
    
    super.init(frame: .zero)
    
    setUp: do {
      backgroundColor = .clear
      
      addSubview(scrollView)
      
      scrollView.clipsToBounds = true
      scrollView.delegate = self
      scrollView.isScrollEnabled = false
      
      scrollView.addSubview(containerView)
      
      containerView.addContent(backdropImageView)
      containerView.addContent(blurryImageView)
      containerView.addContent(canvasView)
      containerView.addContent(drawingView)
      
      backdropImageView.accessibilityIdentifier = "backdropImageView"
      backdropImageView.isUserInteractionEnabled = false
      backdropImageView.contentMode = .scaleAspectFit
      
      blurryImageView.accessibilityIdentifier = "blurryImageView"
      blurryImageView.isUserInteractionEnabled = false
      blurryImageView.contentMode = .scaleAspectFit
      
      blurryImageView.mask = canvasView  
      clipsToBounds = true
    }
    
    drawingView.handlers = drawingView.handlers&>.modify {
      $0.willBeginPan = { [unowned self] path in
        
        currentBrush = .init(color: .black, pixelSize: store.state.primitive.brushPixelSize())
        
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
    
    editingStack.sinkState { [weak self] state in
      
      guard let self = self else { return }
      
      state.ifChanged(\.currentEdit.crop) { cropRect in
        
        /**
         To avoid running pending layout operations from User Initiated actions.
         */
        if cropRect != self.store.state.proposedCrop {
          self.store.commit {
            $0.proposedCrop = cropRect
          }
        }
      }
      
      state.ifChanged(\.currentEdit.drawings.blurredMaskPaths) { paths in
        self.canvasView.setResolvedDrawnPaths(paths)
      }
    }
    .store(in: &subscriptions)
    
  }
  
  override public func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    
    if isBinding == false {
      isBinding = true
      
      editingStack.start()
      
      binding: do {
        store.sinkState(queue: .mainIsolated()) { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.frame, \.proposedCrop) { frame, crop in
            
            guard frame != .zero else { return }
            
              setupScrollViewOnce: do {
                if self.hasSetupScrollViewCompleted == false {
                  self.hasSetupScrollViewCompleted = true
                  
                  let scrollView = self.scrollView
                  
                  self.containerView.bounds = .init(
                    origin: .zero,
                    size: crop.scrollViewContentSize()
                  )
                  
                  // Do we need this? it seems ImageView's bounds changes contentSize automatically. not sure.
                  UIView.performWithoutAnimation {
                    let currentZoomScale = scrollView.zoomScale
                    let contentSize = crop.scrollViewContentSize()
                    if scrollView.contentSize != contentSize {
                      scrollView.contentInset = .zero
                      scrollView.zoomScale = 1
                      scrollView.contentSize = contentSize
                      scrollView.zoomScale = currentZoomScale
                    }
                  }
                }
              }
              
              self.updateScrollContainerView(
                by: crop,
                animated: state.hasLoaded,
                animatesRotation: state.hasChanges(\.proposedCrop.rotation)
              )
          
          }
                             
        }
        .store(in: &subscriptions)
        
        editingStack.sinkState { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.isLoading) { isLoading in
            
            // FIXME: Loading
            //          self.updateLoadingOverlay(displays: isLoading)
          }
          
          state.ifChanged(\.placeholderImage, \.editingPreviewImage) { previewImage, image in
            
            if let previewImage = previewImage {
              self.backdropImageView.display(image: previewImage)
              self.blurryImageView.display(image: BlurredMask.blur(image: previewImage))
            }
            
            if let image = image {
              self.backdropImageView.display(image: image)
              self.blurryImageView.display(image: BlurredMask.blur(image: image))
            }
          }
        }
        .store(in: &subscriptions)
      }
    }
  }
  
  public func setBrushSize(_ size: CanvasView.BrushSize) {
    store.commit {
      $0.brushSize = size
    }
  }
  
  private func updateScrollContainerView(
    by crop: EditingCrop,
    animated: Bool,
    animatesRotation: Bool
  ) {
    
    func perform() {
      
      frame: do {
        scrollView.transform = crop.rotation.transform
        scrollView.frame = store.state.primitive.scrollViewFrame()
      }
      
      zoom: do {
        let (min, max) = crop.calculateZoomScale(scrollViewSize: scrollView.bounds.size)
        
        scrollView.minimumZoomScale = min
        scrollView.maximumZoomScale = max
        
        scrollView.contentInset = .zero
        scrollView.zoom(to: crop.cropExtent, animated: false)
        // WORKAROUND:
        // Fixes `zoom to rect` does not apply the correct state when restoring the state from first-time displaying view.
        scrollView.zoom(to: crop.cropExtent, animated: false)
      }
    }
    
    if animated {
      layoutIfNeeded()
      
      UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [self] in
        perform()
        layoutIfNeeded()
      }&>.do {
        $0.startAnimation()
      }
      
    } else {
      UIView.performWithoutAnimation {
        layoutIfNeeded()
        perform()
      }
    }
  }
  
  override public func layoutSubviews() {
    super.layoutSubviews()
    
    store.commit {
      if $0.frame != frame {
        $0.frame = frame
      }
      if $0.bounds != bounds {
        $0.bounds = bounds
      }
    }
    
    //    maskLayer.frame = blurryImageView.bounds
  }
  
  // MARK: UIScrollViewDelegate
  
  public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return containerView
  }
  
  public func scrollViewDidZoom(_ scrollView: UIScrollView) {
    func adjustFrameToCenterOnZooming() {
      var frameToCenter = containerView.frame
      
      // center horizontally
      if frameToCenter.size.width < scrollView.bounds.width {
        frameToCenter.origin.x = (scrollView.bounds.width - frameToCenter.size.width) / 2
      } else {
        frameToCenter.origin.x = 0
      }
      
      // center vertically
      if frameToCenter.size.height < scrollView.bounds.height {
        frameToCenter.origin.y = (scrollView.bounds.height - frameToCenter.size.height) / 2
      } else {
        frameToCenter.origin.y = 0
      }
      
      containerView.frame = frameToCenter
    }
    
    adjustFrameToCenterOnZooming()
  }
}
