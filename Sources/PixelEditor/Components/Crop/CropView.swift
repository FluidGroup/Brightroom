//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
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

import CoreImage

import UIKit
import Verge

#if !COCOAPODS
import PixelEngine
#endif

/**
 A view that previews how crops the image.

 The cropping adjustument is avaibleble from 2 ways:
 - Scrolling image
 - Panning guide
 */
public final class CropView: UIView, UIScrollViewDelegate {
  public struct State: Equatable {
    public enum AdjustmentKind: Equatable {
      case scrollView
      case guide
    }

    enum ModifiedSource: Equatable {
      case fromState
      case fromScrollView
      case fromGuide
    }

    public fileprivate(set) var proposedCrop: EditingCrop?

    fileprivate var modifiedSource: ModifiedSource?

    public fileprivate(set) var adjustmentKind: AdjustmentKind?

    public fileprivate(set) var frame: CGRect = .zero
    fileprivate var hasLoaded = false
    fileprivate var isGuideInteractionEnabled: Bool = true
  }

  /**
   A view that covers the area out of cropping extent.
   */
  public private(set) weak var cropOutsideOverlay: UIView?

  public let store: UIStateStore<State, Never> = .init(initialState: .init(), logger: nil)

  /**
   A Boolean value that indicates whether the guide is interactive.
   If false, cropping adjustment is available only way from scrolling image-view.
   */
  public var isGuideInteractionEnabled: Bool {
    get {
      store.state.isGuideInteractionEnabled
    }
    set {
      store.commit {
        $0.isGuideInteractionEnabled = newValue
      }
    }
  }
  
  public let editingStack: EditingStack

  /**
   An image view that displayed in the scroll view.
   */
  #if true
  private let imageView = _ImageView()
  #else
  private let imageView: UIView & HardwareImageViewType = {
    return MetalImageView()
  }()
  #endif
  private let scrollView = _CropScrollView()

  /**
   a guide view that displayed on guide container view.
   */
  private lazy var guideView = _InteractiveCropGuideView(
    containerView: self,
    imageView: self.imageView,
    insetOfGuideFlexibility: contentInset
  )

  private var subscriptions = Set<VergeAnyCancellable>()

  /// A throttling timer to apply guide changed event.
  ///
  /// This's waiting for Combine availability in minimum iOS Version.
  private let throttle = Debounce(interval: 0.8)

  private let contentInset: UIEdgeInsets
  
  private var loadingOverlayFactory: (() -> UIView)?
  private weak var currentLoadingOverlay: UIView?
  
  private var isBinding = false
  
  var isAutoApplyEditingStackEnabled = false
  
  // MARK: - Initializers

  /**
   Creates an instance for using as standalone.

   This initializer offers us to get cropping function without detailed setup.
   To get a result image, call `renderImage()`.
   */
  public convenience init(
    image: UIImage,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) {
    self.init(
      editingStack: .init(
        source: .init(image: image),
        previewSize: .init(width: 1000, height: 1000)
      ),
      contentInset: contentInset
    )
  }

  public init(
    editingStack: EditingStack,
    contentInset: UIEdgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
  ) {
    _pixeleditor_ensureMainThread()

    self.editingStack = editingStack
    self.contentInset = contentInset

    super.init(frame: .zero)

    clipsToBounds = false

    addSubview(scrollView)
    addSubview(guideView)

    imageView.isUserInteractionEnabled = true
    scrollView.addSubview(imageView)
    scrollView.delegate = self

    guideView.didChange = { [weak self] in
      guard let self = self else { return }
      self.didChangeGuideViewWithDelay()
    }

    guideView.willChange = { [weak self] in
      guard let self = self else { return }
      self.willChangeGuideView()
    }

    #if false
    store.sinkState { state in
      EditorLog.debug(state.primitive)
    }
    .store(in: &subscriptions)
    #endif
  
    defaultAppearance: do {
      setCropInsideOverlay(CropView.CropInsideOverlayRuleOfThirdsView())
      setCropOutsideOverlay(CropView.CropOutsideOverlayBlurredView())
      setLoadingOverlay(factory: {
        LoadingBlurryOverlayView(effect: UIBlurEffect(style: .dark), activityIndicatorStyle: .whiteLarge)
      })
    }
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Functions
  
  public override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    
    if isBinding == false {
      isBinding = true
      
      binding: do {
        store.sinkState(queue: .mainIsolated()) { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.proposedCrop, \.frame) { crop, frame in
            
            guard frame != .zero else { return }
            
            if let crop = crop, state.modifiedSource != .fromScrollView {
              self.updateScrollContainerView(
                by: crop,
                animated: state.hasLoaded,
                animatesRotation: state.hasChanges(\.proposedCrop?.rotation)
              )
            } else {
              // TODO:
            }
          }
          
          if self.isAutoApplyEditingStackEnabled {
            state.ifChanged(\.proposedCrop) { crop in
              guard let crop = crop else { return }
              self.editingStack.crop(crop)
            }
          }
          
          state.ifChanged(\.isGuideInteractionEnabled) { value in
            self.guideView.isUserInteractionEnabled = value
          }
        }
        .store(in: &subscriptions)
        
        editingStack.sinkState { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged(\.isLoading) { isLoading in
            self.updateLoadingOverlay(displays: isLoading)
          }
          
          state.ifChanged(\.currentEdit.crop) { cropRect in
            
            self.setCrop(cropRect)
          }
          
          state.ifChanged(\.previewImage, \.targetOriginalSizeImage) { previewImage, image in
            
            if let previewImage = previewImage {
              self.setImage(previewImage)
            }
            
            if let image = image {
              self.setImage(image)
            }
          
          }
        }
        .store(in: &subscriptions)
      }
      
    }
    
  }
  
  private func updateLoadingOverlay(displays: Bool) {
    
    if displays, let factory = self.loadingOverlayFactory {
      
      let loadingOverlay = factory()
      self.currentLoadingOverlay = loadingOverlay
      self.addSubview(loadingOverlay)
      AutoLayoutTools.setEdge(loadingOverlay, self.guideView)
      
      loadingOverlay.alpha = 0
      UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
        loadingOverlay.alpha = 1
      }
      .startAnimation()
      
    } else {
      
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
    
  /**
   Renders an image according to the editing.

   - Attension: This operation can be run background-thread.
   */
  public func renderImage() -> UIImage {
    applyEditingStack()
    return editingStack.makeRenderer().render()
  }
  
  /**
   Applies the current state to the EditingStack.
   */
  public func applyEditingStack() {
    
    guard let crop = store.state.proposedCrop else {
      return
    }
    editingStack.crop(crop)
  }

  public func resetCrop() {
    _pixeleditor_ensureMainThread()

    store.commit {
      $0.proposedCrop = $0.proposedCrop?.makeInitial()
      $0.modifiedSource = .fromState
    }

    guideView.setLockedAspectRatio(nil)
  }

  public func setRotation(_ rotation: EditingCrop.Rotation) {
    _pixeleditor_ensureMainThread()

    store.commit {
      $0.proposedCrop?.rotation = rotation
      $0.modifiedSource = .fromState
    }
  }

  public func setCrop(_ crop: EditingCrop) {
    _pixeleditor_ensureMainThread()
    
    store.commit {
      $0.proposedCrop = crop
      $0.modifiedSource = .fromState
    }
  }

  public func setCroppingAspectRatio(_ ratio: PixelAspectRatio) {
    _pixeleditor_ensureMainThread()

    store.commit {
      $0.proposedCrop?.updateCropExtent(by: ratio)
      $0.proposedCrop?.preferredAspectRatio = ratio
      $0.modifiedSource = .fromState
    }
  }

  /**
   Displays a view as an overlay.
   e.g. grid view

   - Parameters:
   - view: In case of no needs to display overlay, pass nil.
   */
  public func setCropInsideOverlay(_ view: CropInsideOverlayBase?) {
    _pixeleditor_ensureMainThread()

    guideView.setCropInsideOverlay(view)
  }

  /**
   Displays an overlay that covers the area out of cropping extent.
   Given view's frame would be adjusted automatically.

   - Attention: view's userIntereactionEnabled turns off
   - Parameters:
   - view: In case of no needs to display overlay, pass nil.
   */
  public func setCropOutsideOverlay(_ view: CropOutsideOverlayBase?) {
    _pixeleditor_ensureMainThread()

    cropOutsideOverlay?.removeFromSuperview()

    guard let view = view else {
      // just removing
      return
    }

    cropOutsideOverlay = view
    view.isUserInteractionEnabled = false

    // TODO: Unstable operation.
    insertSubview(view, aboveSubview: scrollView)

    guideView.setCropOutsideOverlay(view)

    setNeedsLayout()
    layoutIfNeeded()
  }
  
  public func setLoadingOverlay(factory: (() -> UIView)?) {
    _pixeleditor_ensureMainThread()
    loadingOverlayFactory = factory
  }
    
}

// MARK: Internal

extension CropView {
  private func setImage(_ ciImage: CIImage) {
    imageView.display(image: ciImage)
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    DispatchQueue.main.async { [self] in
      store.commit {
        if $0.frame != frame {
          $0.frame = frame
        }
      }
    }

    if let outOfBoundsOverlay = cropOutsideOverlay {
      outOfBoundsOverlay.frame.size = .init(width: 1000, height: 1000)
      outOfBoundsOverlay.center = center
    }
  }

  override public func didMoveToSuperview() {
    super.didMoveToSuperview()

    DispatchQueue.main.async { [self] in
      store.commit {
        $0.hasLoaded = superview != nil
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
        switch crop.rotation {
        case .angle_0:
          size = crop.cropExtent.size.aspectRatio.sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio)
        case .angle_90:
          size = crop.cropExtent.size.aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio?.swapped())
        case .angle_180:
          size = crop.cropExtent.size.aspectRatio.sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio)
        case .angle_270:
          size = crop.cropExtent.size.aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(crop.preferredAspectRatio?.swapped())
        }

        scrollView.transform = crop.rotation.transform

        scrollView.frame = .init(
          origin: .init(
            x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
            y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
          ),
          size: size
        )
      }

      applyLayoutDescendants: do {
        guideView.frame = scrollView.frame
      }

      zoom: do {
        imageView.bounds = .init(origin: .zero, size: crop.scrollViewContentSize())

        let (min, max) = crop.calculateZoomScale(scrollViewBounds: scrollView.bounds)

        scrollView.minimumZoomScale = min
        scrollView.maximumZoomScale = max

        UIView.performWithoutAnimation {
          let currentZoomScale = scrollView.zoomScale
          let contentSize = crop.scrollViewContentSize()
          scrollView.zoomScale = 1
          scrollView.contentSize = contentSize
          scrollView.zoomScale = currentZoomScale
        }
        
        scrollView.zoom(to: crop.cropExtent.cgRect, animated: false)
        // WORKAROUND:
        // Fixes `zoom to rect` does not apply the correct state when restoring the state from first-time displaying view.
        scrollView.zoom(to: crop.cropExtent.cgRect, animated: false)
        
      }
    }
    
    if animated {
      layoutIfNeeded()

      if animatesRotation {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          perform()
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.startAnimation()
        }

        UIViewPropertyAnimator(duration: 0.12, dampingRatio: 1) {
          self.guideView.alpha = 0
        }&>.do {
          $0.isUserInteractionEnabled = false
          $0.addCompletion { _ in
            UIViewPropertyAnimator(duration: 0.5, dampingRatio: 1) {
              self.guideView.alpha = 1
            }
            .startAnimation(afterDelay: 0.8)
          }
          $0.startAnimation()
        }

      } else {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          perform()
          self.layoutIfNeeded()
        }&>.do {
          $0.startAnimation()
        }
      }

    } else {
      UIView.performWithoutAnimation {
        layoutIfNeeded()
        perform()
      }
    }
  }

  @inline(__always)
  private func willChangeGuideView() {
    throttle.on { /* for debounce */ }
  }

  @inline(__always)
  private func didChangeGuideViewWithDelay() {
    throttle.on { [weak self] in

      guard let self = self else { return }

      self.store.commit {
        let rect = self.guideView.convert(self.guideView.bounds, to: self.imageView)
        if var crop = $0.proposedCrop {
          // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
          crop.cropExtent = .init(cgRect: rect)
          $0.proposedCrop = crop
          $0.modifiedSource = .fromGuide
        } else {
          assertionFailure()
        }
      }
    }
  }

  @inline(__always)
  private func didChangeScrollView() {
    store.commit {
      let rect = scrollView.convert(scrollView.bounds, to: imageView)

      if var crop = $0.proposedCrop {
        // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
        crop.cropExtent = .init(cgRect: rect)
        $0.proposedCrop = crop
        $0.modifiedSource = .fromScrollView
      } else {
        assertionFailure()
      }
    }
  }

  // MARK: UIScrollViewDelegate

  public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return imageView
  }

  public func scrollViewDidZoom(_ scrollView: UIScrollView) {
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

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guideView.willBeginScrollViewAdjustment()
  }

  public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    guideView.willBeginScrollViewAdjustment()
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate {
      didChangeScrollView()
      guideView.didEndScrollViewAdjustment()
    }
  }

  public func scrollViewDidEndZooming(
    _ scrollView: UIScrollView,
    with view: UIView?,
    atScale scale: CGFloat
  ) {
    didChangeScrollView()
    guideView.didEndScrollViewAdjustment()
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    didChangeScrollView()
    guideView.didEndScrollViewAdjustment()
  }
}

extension EditingCrop {
  fileprivate func scrollViewContentSize() -> CGSize {
    imageSize.cgSize
  }

  fileprivate func calculateZoomScale(scrollViewBounds: CGRect) -> (min: CGFloat, max: CGFloat) {
    let minXScale = scrollViewBounds.width / imageSize.cgSize.width
    let minYScale = scrollViewBounds.height / imageSize.cgSize.height

    /**
     max meaning scale aspect fill
     */
    let minScale = max(minXScale, minYScale)

    return (min: minScale, max: .greatestFiniteMagnitude)
  }
}
