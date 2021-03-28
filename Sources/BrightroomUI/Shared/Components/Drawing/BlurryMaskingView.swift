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
    fileprivate(set) var frame: CGRect = .zero
    fileprivate(set) var bounds: CGRect = .zero
    
    fileprivate var hasLoaded = false
    
    fileprivate(set) var proposedCrop: EditingCrop?
    
    fileprivate(set) var brushSize: CanvasView.BrushSize = .point(30)
    
    fileprivate let contentInset: UIEdgeInsets = .zero
    
    func scrollViewFrame() -> CGRect? {
      
      guard let proposedCrop = proposedCrop else {
        return nil
      }
      
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
    
    func brushPixelSize() -> CGFloat? {
      
      guard let proposedCrop = proposedCrop, let size = scrollViewFrame()?.size else {
        return nil
      }
      
      let (min, _) = proposedCrop.calculateZoomScale(scrollViewSize: size)
      
      switch brushSize {
      case let .point(points):
        return points / min
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
      backdropImageView.isHidden
    }
    set {
      backdropImageView.isHidden = newValue
    }
  }
  
  public var isblurryImageViewHidden: Bool {
    get {
      blurryImageView.isHidden
    }
    set {
      blurryImageView.isHidden = newValue
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
   
  private var hasSetupScrollViewCompleted = false
  
  private let store: UIStateStore<State, Never>
  
  private var currentBrush: OvalBrush?
  
  private var loadingOverlayFactory: (() -> UIView)?
  private weak var currentLoadingOverlay: UIView?
  
  private var isBinding = false
  
  // MARK: - Initializers
  
  public init(editingStack: EditingStack) {
    
    self.editingStack = editingStack
    store = .init(
      initialState: .init(),
      logger: nil
    )
            
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
      
      if let state = state._beta_map(\.loadedState) {
        
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
      }
      
    }
    .store(in: &subscriptions)
    
    defaultAppearance: do {
      setLoadingOverlay(factory: {
        LoadingBlurryOverlayView(effect: UIBlurEffect(style: .dark), activityIndicatorStyle: .whiteLarge)
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
        store.sinkState(queue: .mainIsolated()) { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.frame, \.proposedCrop) { frame, crop in
            
            guard let crop = crop else { return }
            
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
              animatesRotation: state.hasChanges(\.proposedCrop?.rotation)
            )
          }
        }
        .store(in: &subscriptions)
        
        editingStack.sinkState { [weak self] (state: Changes<EditingStack.State>) in
          
          guard let self = self else { return }
          
          state.ifChanged(\.isLoading) { isLoading in
            self.updateLoadingOverlay(displays: isLoading)
          }
          
          if let state = state._beta_map(\.loadedState) {
            
            state.ifChanged(\.editingPreviewImage) { image in
              self.backdropImageView.display(image: image)
              self.blurryImageView.display(image: BlurredMask.blur(image: image))
            }
            
            state.ifChanged(\.currentEdit.drawings.blurredMaskPaths) { paths in
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
  
  private func updateLoadingOverlay(displays: Bool) {
    
    if displays, let factory = self.loadingOverlayFactory {
      
      scrollView.isHidden = true
      
      let loadingOverlay = factory()
      self.currentLoadingOverlay = loadingOverlay
      self.addSubview(loadingOverlay)
      AutoLayoutTools.setEdge(loadingOverlay, self)
      
      loadingOverlay.alpha = 0
      UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
        loadingOverlay.alpha = 1
      }
      .startAnimation()
      
    } else {
      
      scrollView.isHidden = false
      
      if let view = currentLoadingOverlay {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          view.alpha = 0
        }&>.do {
          $0.addCompletion { _ in
            view.removeFromSuperview()
          }
          $0.startAnimation()
        }
      }
      
    }
    
  }
  
  
  private func updateScrollContainerView(
    by crop: EditingCrop,
    animated: Bool,
    animatesRotation: Bool
  ) {
    
    func perform() {
      
      guard let scrollViewFrame = store.state.primitive.scrollViewFrame() else {
        return
      }
      
      frame: do {
        scrollView.transform = crop.rotation.transform
        scrollView.frame = scrollViewFrame
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
        
        disableZooming: do {
          let zoomedScale = scrollView.zoomScale
          scrollView.minimumZoomScale = zoomedScale
          scrollView.maximumZoomScale = zoomedScale
        }
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
