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
    fileprivate var hasLoaded = false
    fileprivate(set) var proposedCrop: EditingCrop?
  }
  
  private final class ContainerView: PixelEditorCodeBasedView {
    func addContent(_ view: UIView) {
      addSubview(view)
      view.frame = bounds
      view.autoresizingMask = [.flexibleHeight, .flexibleWidth]
    }
  }
  
  var brush = OvalBrush(color: UIColor.black, pixelSize: 30)
  
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
  
  private let store: UIStateStore<State, Never> = .init(initialState: .init(), logger: nil)
  
  private let contentInset: UIEdgeInsets = .zero
  
  private var isBinding = false
  
  // MARK: - Initializers
  
  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
    editingStack.start()
    
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
      
      //      blurryImageView.layer.mask = maskLayer
      //      maskLayer.contentsScale = UIScreen.main.scale
      //      maskLayer.drawsAsynchronously = true
      
      clipsToBounds = true
    }
    
    drawingView.handlers = drawingView.handlers&>.modify {
      $0.willBeginPan = { [unowned self] path in
        let drawnPath = DrawnPathInRect(path: DrawnPath(brush: brush, path: path), in: bounds)
        canvasView.previewDrawnPaths = [drawnPath]
      }
      $0.panning = { [unowned self] path in
        canvasView.update()
      }
      $0.didFinishPan = { [unowned self] path in
        canvasView.update()
        
        let _path = (path.copy() as! UIBezierPath)
        
        let drawnPath = DrawnPathInRect(path: DrawnPath(brush: brush, path: _path), in: bounds)
        
        canvasView.previewDrawnPaths = []
        editingStack.append(blurringMaskPaths: CollectionOfOne(drawnPath))
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
        if self.canvasView.resolvedDrawnPaths != paths {
          self.canvasView.resolvedDrawnPaths = paths
        }
      }
    }
    .store(in: &subscriptions)
    
  }
  
  override public func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    
    if isBinding == false {
      isBinding = true
      
      binding: do {
        store.sinkState(queue: .mainIsolated()) { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.frame, \.proposedCrop) { frame, crop in
            
            guard frame != .zero else { return }
            
            if let crop = crop {
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
            } else {
              // TODO:
            }
          }
        }
        .store(in: &subscriptions)
        
        editingStack.sinkState { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.isLoading) { isLoading in
            //          self.updateLoadingOverlay(displays: isLoading)
          }
          
          state.ifChanged(\.placeholderImage, \.editingSourceImage) { previewImage, image in
            
            if let previewImage = previewImage {
              self.backdropImageView.display(image: previewImage)
            }
            
            if let image = image {
              self.backdropImageView.display(image: image)
            }
          }
        }
        .store(in: &subscriptions)
      }
    }
  }
  
  private func updateScrollContainerView(
    by crop: EditingCrop,
    animated: Bool,
    animatesRotation: Bool
  ) {
    func perform() {
      frame: do {
        let bounds = self.bounds.inset(by: contentInset)
        
        let size: CGSize
        let aspectRatio = PixelAspectRatio(crop.cropExtent.size)
        switch crop.rotation {
        case .angle_0:
          size = aspectRatio.sizeThatFits(in: bounds.size)
        case .angle_90:
          size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
        case .angle_180:
          size = aspectRatio.sizeThatFits(in: bounds.size)
        case .angle_270:
          size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
        }
        
        scrollView.transform = crop.rotation.transform
        
        scrollView.frame = .init(
          origin: .init(
            x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
            y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
          ),
          size: size
        )
        
        //        scrollBackdropView.frame = scrollView.frame
      }
      
      zoom: do {
        let (min, max) = crop.calculateZoomScale(scrollViewBounds: scrollView.bounds)
        
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

extension BlurryMaskingView {
  
  private final class CanvasView: PixelEditorCodeBasedView {
    
    override class var layerClass: AnyClass {
      #if false
      return CATiledLayer.self
      #else
      return CALayer.self
      #endif
    }
    
    private let resolvedShapeLayer = CAShapeLayer()
    private let shapeLayer = CAShapeLayer()
    
    override init(frame: CGRect) {
      super.init(frame: frame)
      isOpaque = false
      
      if let tiledLayer = layer as? CATiledLayer {
        tiledLayer.tileSize = .init(width: 512, height: 512)
      }
      
      [
        resolvedShapeLayer,
        shapeLayer,
      ]
      .forEach {
        
        $0.lineWidth = 100
        $0.strokeColor = UIColor.blue.cgColor
        $0.lineCap = .round
        $0.fillColor = UIColor.clear.cgColor
        
        layer.addSublayer($0)
      }
      
    }
    
    var previewDrawnPaths: [DrawnPathInRect] = [] {
      didSet {
        update()
      }
    }
    
    var resolvedDrawnPaths: [DrawnPathInRect] = [] {
      didSet {
        
        let path = UIBezierPath()
        
        resolvedDrawnPaths.forEach {
          path.append($0.path.bezierPath)
        }
        
        let cgPath = path.cgPath
        resolvedShapeLayer.path = cgPath
      }
    }
    
    func update() {
      
      let path = UIBezierPath()
      
      previewDrawnPaths.forEach {
        path.append($0.path.bezierPath)
      }
      
      shapeLayer.path = path.cgPath
    }
    
    override func layoutSubviews() {
      super.layoutSubviews()
      resolvedShapeLayer.frame = bounds
      shapeLayer.frame = bounds
    }
    
  }
}
