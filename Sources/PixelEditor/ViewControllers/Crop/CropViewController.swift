//
//  CropViewController.swift
//  PixelEditor
//
//  Created by Muukii on 2021/02/27.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation

import PixelEngine
import Verge

public final class CropViewController: UIViewController {
  
  private let containerView: _Crop.CropScrollContainerView = .init()
  
  public let editingStack: EditingStack
  
  private var bag = Set<VergeAnyCancellable>()
  
  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
    super.init(nibName: nil, bundle: nil)
  }
  
  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  public override func viewDidLoad() {
    super.viewDidLoad()    
    
    view.backgroundColor = .white
    view.addSubview(containerView)
    AutoLayoutTools.setEdge(containerView, view)
        
    editingStack.sinkState { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.cropRect) { cropRect in
        
        self.containerView.setCropAndRotate(cropRect)
      }
      
      state.ifChanged(\.targetOriginalSizeImage) { image in
        guard let image = image else { return }
        self.containerView.setImage(image)
      }
    }
    .store(in: &bag)
  }
  
}

enum _Crop {
  
  final class CropScrollContainerView: UIView, UIScrollViewDelegate {
        
    struct State: Equatable {
      var proposedCropAndRotate: CropAndRotate?
    }
                
    private let imageView = UIImageView()
    private let scrollView = CropScrollView()
    
    private var scrollViewOldSize: CGSize?
    
    let store: UIStateStore<State, Never> = .init(initialState: .init(), logger: nil)
    
    private var subscriptions = Set<VergeAnyCancellable>()
    
    init() {
      super.init(frame: .zero)
      
      addSubview(scrollView)
      
      imageView.isUserInteractionEnabled = true
      scrollView.addSubview(imageView)
      scrollView.delegate = self
      
      #if DEBUG
      store.sinkState { (state) in
        EditorLog.debug(state.primitive)
      }
      .store(in: &subscriptions)
      #endif
      
      store.sinkState { [weak self] (state) in
        
        guard let self = self else { return }
        
        state.ifChanged(\.proposedCropAndRotate) { cropAndRotate in
          
          if let cropAndRotate = cropAndRotate {
            self.updateScrollViewFrame(by: cropAndRotate)
            self.updateScrollViewZoomScale(by: cropAndRotate)
          } else {
            // TODO: consider needs to do something
          }
                  
        }
                       
      }
      .store(in: &subscriptions)
    }
        
    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
          
    private func updateScrollViewZoomScale(by cropAndRotate: CropAndRotate) {
      
      imageView.bounds = .init(origin: .zero, size: cropAndRotate.scrollViewContentSize())
      scrollView.contentSize = cropAndRotate.scrollViewContentSize()
      
      let (min, max) = cropAndRotate.calculateZoomScale(scrollViewBounds: scrollView.bounds)
      
      scrollView.minimumZoomScale = min
      scrollView.maximumZoomScale = max
            
      scrollView.zoom(to: cropAndRotate.cropRect.cgRect, animated: false)
    }
    
    private func updateScrollViewFrame(by cropAndRotate: CropAndRotate) {
      
      let insets = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
      let bounds = self.bounds.inset(by: insets)
      
      let size = cropAndRotate.aspectRatio.sizeThatFits(in: bounds.size)
      
      scrollView.frame = .init(
        origin: .init(
          x: insets.left + ((bounds.width - size.width) / 2) /* centering offset */,
          y: insets.top + ((bounds.height - size.height) / 2) /* centering offset */
        ),
        size: size
      )
            
    }
    
    override func layoutSubviews() {
      super.layoutSubviews()
            
      if scrollViewOldSize != scrollView.bounds.size {
        scrollViewOldSize = scrollView.bounds.size
        store.state.proposedCropAndRotate.map {
          updateScrollViewFrame(by: $0)
          updateScrollViewZoomScale(by: $0)
        }
      }
    }
    
    func setImage(_ image: CIImage) {
          
      let _image: UIImage
      
      if let cgImage = image.cgImage {
        _image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
      } else {
        // Displaying will be slow in iOS13
        _image = UIImage(
          ciImage: image.transformed(
            by: .init(
              translationX: -image.extent.origin.x,
              y: -image.extent.origin.y
            )),
          scale: 1,
          orientation: .up
        )
        
      }
       
      setImage(image: _image)
      
    }
    
    func setRotation() {
      // FIXME
    }
            
    func setCropAndRotate(_ cropAndRotate: CropAndRotate) {
      
      store.commit {
        $0.proposedCropAndRotate = cropAndRotate
      }
          
    }
      
    private func setImage(image: UIImage) {
      
      guard let imageSize = store.state.proposedCropAndRotate?.imageSize else {
        assertionFailure("Call configureImageForSize before.")
        return
      }
      
      assert(image.scale == 1)
      assert(image.size == imageSize.cgSize)
      imageView.image = image
      
    }
           
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      return imageView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      
      func adjustFrameToCenterOnZooming() {
        
        var frameToCenter = imageView.frame
        
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
        
        imageView.frame = frameToCenter
      }
      
      adjustFrameToCenterOnZooming()
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate {
        updateState()
      }
    }
    
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
      updateState()
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      updateState()
    }
    
    @inline(__always)
    private func updateState() {
      
      store.commit {
        
        var rect = scrollView.convert(scrollView.bounds, to: imageView)
        rect.origin.x.round(.up)
        rect.origin.y.round(.up)
        rect.size.width.round(.up)
        rect.size.height.round(.up)
        
        if var crop = $0.proposedCropAndRotate {
          crop.cropRect = .init(cgRect: rect)
          $0.proposedCropAndRotate = crop
        } else {
          assertionFailure()
        }
        
      }
            
    }
    
  }
  
  final class CropScrollView: UIScrollView {
                           
    override init(frame: CGRect) {
      super.init(frame: frame)
      
      initialize()
    }
    
    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
      fatalError()
    }
    
    private func initialize() {
      showsVerticalScrollIndicator = false
      showsHorizontalScrollIndicator = false
      bouncesZoom = true
      decelerationRate = UIScrollView.DecelerationRate.fast
    }
                             
//    private func zoomRectForScale(_ scale: CGFloat, center: CGPoint) -> CGRect {
//      var zoomRect = CGRect.zero
//
//      // the zoom rect is in the content view's coordinates.
//      // at a zoom scale of 1.0, it would be the size of the imageScrollView's bounds.
//      // as the zoom scale decreases, so more content is visible, the size of the rect grows.
//      zoomRect.size.height = frame.size.height / scale
//      zoomRect.size.width = frame.size.width / scale
//
//      // choose an origin so as to get the right center.
//      zoomRect.origin.x = center.x - (zoomRect.size.width / 2.0)
//      zoomRect.origin.y = center.y - (zoomRect.size.height / 2.0)
//
//      return zoomRect
//    }
        
  }

}

extension CropAndRotate {
  
  fileprivate func scrollViewContentSize() -> CGSize {
    imageSize.cgSize
  }
  
  fileprivate func calculateZoomScale(scrollViewBounds: CGRect) -> (min: CGFloat, max: CGFloat) {
            
    let minXScale = scrollViewBounds.width / imageSize.cgSize.width
    let minYScale = scrollViewBounds.height / imageSize.cgSize.height
    
    let maxXScale = imageSize.cgSize.width / scrollViewBounds.width
    let maxYScale = imageSize.cgSize.height / scrollViewBounds.height
    
    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)
    let maxScale = max(maxXScale, maxYScale)
    
    // don't let minScale exceed maxScale. (If the image is smaller than the screen, we don't want to force it to be zoomed.)
    if minScale > maxScale {
      return (min: maxScale, max: maxScale)
    }
    
    return (min: minScale, max: maxScale)
  }
  
  
}
