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
  
  final class CropScrollContainerView: UIView, UIScrollViewDelegate {
        
    struct State: Equatable {
      var imageSize: PixelSize?
      var visibleRect: CGRect?
    }
        
    struct ScrollViewContentSizeDescriptor {
      
    }
    
    private let imageView = UIImageView()
    private let scrollView = CropScrollView()
    
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
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
          
    private var scrollViewOldSize: CGSize?
    
    override func layoutSubviews() {
      super.layoutSubviews()
      
      scrollView.frame = .init(x: 30, y: 30, width: 300, height: 300)
      
      if scrollViewOldSize != scrollView.bounds.size {
        scrollViewOldSize = scrollView.bounds.size
        if let imageSize = store.state.imageSize {
          setImageSize(imageSize)
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
        
    func setImage(image: UIImage) {
      
      guard let imageSize = store.state.imageSize else {
        assertionFailure("Call configureImageForSize before.")
        return
      }
      
      assert(image.scale == 1)
      assert(image.size == imageSize.cgSize)
      imageView.image = image
    }
    
    func setImageSize(_ size: PixelSize) {
      store.commit {
        $0.imageSize = size
      }
      imageView.bounds = .init(origin: .zero, size: size.cgSize)
      scrollView.contentSize = size.cgSize
      setMaxMinZoomScalesForCurrentBounds(imageSize: size.cgSize)
      scrollView.zoomScale = scrollView.minimumZoomScale
      
      let contentSize = scrollView.contentSize
      let xOffset = contentSize.width < bounds.width ? 0 : (contentSize.width - bounds.width) / 2
      let yOffset = contentSize.height < bounds.height ? 0 : (contentSize.height - bounds.height) / 2
      
      scrollView.contentOffset = CGPoint(x: xOffset, y: yOffset)
    }
    
    private func setMaxMinZoomScalesForCurrentBounds(imageSize: CGSize) {
      
      let maxScaleFromMinScale: CGFloat = 3.0
      
      // calculate min/max zoomscale
      let xScale = scrollView.bounds.width / imageSize.width // the scale needed to perfectly fit the image width-wise
      let yScale = scrollView.bounds.height / imageSize.height // the scale needed to perfectly fit the image height-wise
      
      /**
       max meaning scale aspect fill
       */
      var minScale: CGFloat = max(xScale, yScale)
      
      let maxScale = maxScaleFromMinScale * minScale
      
      // don't let minScale exceed maxScale. (If the image is smaller than the screen, we don't want to force it to be zoomed.)
      if minScale > maxScale {
        minScale = maxScale
      }
      
      scrollView.maximumZoomScale = maxScale
      scrollView.minimumZoomScale = minScale * 0.999 // the multiply factor to prevent user cannot scroll page while they use this control in UIPageViewController
    }
    
    private func adjustFrameToCenter() {
      
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
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      return imageView
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
        $0.visibleRect = scrollView.convert(scrollView.bounds, to: imageView)
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
