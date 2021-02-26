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
      
      state.ifChanged(\.imageSize) { imageSize in
        
        self.containerView.setImageSize(imageSize)
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
  
  final class CropScrollContainerView: UIView {
    
    struct ScrollViewContentSizeDescriptor {
      
    }
    
    private let scrollView = CropScrollView()
    
    init() {
      super.init(frame: .zero)
      
      addSubview(scrollView)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
      super.layoutSubviews()
      
      scrollView.frame = .init(x: 30, y: 30, width: 300, height: 300)
      
    }
    
    func setImageSize(_ size: PixelSize) {
      
      scrollView.setImageSize(size)
      
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
       
      scrollView.setImage(image: _image)
      
    }
    
  }
  
  final class CropScrollView: UIScrollView, UIScrollViewDelegate {
    
    struct State: Equatable {
      var imageSize: PixelSize?
      var visibleRect: CGRect?
    }
                  
    let zoomView: UIImageView = .init()

    private var maxScaleFromMinScale: CGFloat = 3.0
        
    let store: UIStateStore<State, Never> = .init(initialState: .init(), logger: nil)
    
    override init(frame: CGRect) {
      super.init(frame: frame)
      
      initialize()
    }
    
    required init?(coder aDecoder: NSCoder) {
      super.init(coder: aDecoder)
      
      initialize()
    }
    
    private func initialize() {
      showsVerticalScrollIndicator = false
      showsHorizontalScrollIndicator = false
      bouncesZoom = true
      decelerationRate = UIScrollView.DecelerationRate.fast
      delegate = self
      
      zoomView.isUserInteractionEnabled = true
      
      addSubview(zoomView)
    }
    
    private func adjustFrameToCenter() {
      
      var frameToCenter = zoomView.frame
      
      // center horizontally
      if frameToCenter.size.width < bounds.width {
        frameToCenter.origin.x = (bounds.width - frameToCenter.size.width) / 2
      } else {
        frameToCenter.origin.x = 0
      }
      
      // center vertically
      if frameToCenter.size.height < bounds.height {
        frameToCenter.origin.y = (bounds.height - frameToCenter.size.height) / 2
      } else {
        frameToCenter.origin.y = 0
      }
      
      zoomView.frame = frameToCenter
    }
    
    /*
     private func prepareToResize() {
     let boundsCenter = CGPoint(x: bounds.midX, y: bounds.midY)
     pointToCenterAfterResize = convert(boundsCenter, to: zoomView)
     
     scaleToRestoreAfterResize = zoomScale
     
     // If we're at the minimum zoom scale, preserve that by returning 0, which will be converted to the minimum
     // allowable scale when the scale is restored.
     if scaleToRestoreAfterResize <= minimumZoomScale + CGFloat(Float.ulpOfOne) {
     scaleToRestoreAfterResize = 0
     }
     }
     */
    
    /*
     private func recoverFromResizing() {
     setMaxMinZoomScalesForCurrentBounds()
     
     // restore zoom scale, first making sure it is within the allowable range.
     let maxZoomScale = max(minimumZoomScale, scaleToRestoreAfterResize)
     zoomScale = min(maximumZoomScale, maxZoomScale)
     
     // restore center point, first making sure it is within the allowable range.
     
     // convert our desired center point back to our own coordinate space
     let boundsCenter = convert(pointToCenterAfterResize, to: zoomView)
     
     // calculate the content offset that would yield that center point
     var offset = CGPoint(
     x: boundsCenter.x - bounds.size.width / 2.0,
     y: boundsCenter.y - bounds.size.height / 2.0
     )
     
     // restore offset, adjusted to be within the allowable range
     let maxOffset = maximumContentOffset()
     let minOffset = minimumContentOffset()
     
     var realMaxOffset = min(maxOffset.x, offset.x)
     offset.x = max(minOffset.x, realMaxOffset)
     
     realMaxOffset = min(maxOffset.y, offset.y)
     offset.y = max(minOffset.y, realMaxOffset)
     
     contentOffset = offset
     }
     */
    
    /*
     private func maximumContentOffset() -> CGPoint {
     return CGPoint(x: contentSize.width - bounds.width, y: contentSize.height - bounds.height)
     }
     
     private func minimumContentOffset() -> CGPoint {
     return CGPoint.zero
     }
     */
    
    private var oldSize: CGSize?
    
    override func layoutSubviews() {
      super.layoutSubviews()
      
      if oldSize != bounds.size {
        oldSize = bounds.size
        if let imageSize = store.state.imageSize {
          setImageSize(imageSize)
        }
      }
    }
    
    // MARK: - Display image
    
    func setImage(image: UIImage) {
      
      guard let imageSize = store.state.imageSize else {
        assertionFailure("Call configureImageForSize before.")
        return
      }
      
      assert(image.scale == 1)
      assert(image.size == imageSize.cgSize)
      zoomView.image = image
    }
    
    func setImageSize(_ size: PixelSize) {
      store.commit {
        $0.imageSize = size
      }
      zoomView.bounds = .init(origin: .zero, size: size.cgSize)
      contentSize = size.cgSize
      setMaxMinZoomScalesForCurrentBounds(imageSize: size.cgSize)
      zoomScale = minimumZoomScale
      
      let xOffset = contentSize.width < bounds.width ? 0 : (contentSize.width - bounds.width) / 2
      let yOffset = contentSize.height < bounds.height ? 0 : (contentSize.height - bounds.height) / 2
      contentOffset = CGPoint(x: xOffset, y: yOffset)
    }
    
    private func setMaxMinZoomScalesForCurrentBounds(imageSize: CGSize) {
      // calculate min/max zoomscale
      let xScale = bounds.width / imageSize.width // the scale needed to perfectly fit the image width-wise
      let yScale = bounds.height / imageSize.height // the scale needed to perfectly fit the image height-wise
      
      /**
       max meaning scale aspect fill
       */
      var minScale: CGFloat = max(xScale, yScale)
                
      let maxScale = maxScaleFromMinScale * minScale
      
      // don't let minScale exceed maxScale. (If the image is smaller than the screen, we don't want to force it to be zoomed.)
      if minScale > maxScale {
        minScale = maxScale
      }
      
      maximumZoomScale = maxScale
      minimumZoomScale = minScale * 0.999 // the multiply factor to prevent user cannot scroll page while they use this control in UIPageViewController
    }
          
    private func zoomRectForScale(_ scale: CGFloat, center: CGPoint) -> CGRect {
      var zoomRect = CGRect.zero
      
      // the zoom rect is in the content view's coordinates.
      // at a zoom scale of 1.0, it would be the size of the imageScrollView's bounds.
      // as the zoom scale decreases, so more content is visible, the size of the rect grows.
      zoomRect.size.height = frame.size.height / scale
      zoomRect.size.width = frame.size.width / scale
      
      // choose an origin so as to get the right center.
      zoomRect.origin.x = center.x - (zoomRect.size.width / 2.0)
      zoomRect.origin.y = center.y - (zoomRect.size.height / 2.0)
      
      return zoomRect
    }
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      return zoomView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      adjustFrameToCenter()
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
        $0.visibleRect = convert(bounds, to: subviews.first!)
      }
      
    }
  }

}
