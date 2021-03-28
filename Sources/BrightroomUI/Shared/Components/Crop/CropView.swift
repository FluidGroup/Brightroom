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
import BrightroomEngine
#endif

/**
 A view that previews how crops the image.

 The cropping adjustument is avaibleble from 2 ways:
 - Scrolling image
 - Panning guide
 
 - TODO:
   - Implicit animations occurs in first time load with remote image.
 */
public final class CropView: UIView, UIScrollViewDelegate {
  public struct State: Equatable {
    public enum AdjustmentKind: Equatable {
      case scrollView
      case guide
    }

    public fileprivate(set) var proposedCrop: EditingCrop?

    public fileprivate(set) var frame: CGRect = .zero
    
    fileprivate var isGuideInteractionEnabled: Bool = true
    fileprivate var layoutVersion: UInt64 = 0
    
    /**
     Returns aspect ratio.
     Would not be affected by rotation.
     */
    var preferredAspectRatio: PixelAspectRatio?
  }
  
  /**
   A view that covers the area out of cropping extent.
   */
  public private(set) weak var cropOutsideOverlay: UIView?

  public let store: UIStateStore<State, Never>

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

  private let imageView = _ImageView() 
  private let scrollView = _CropScrollView()
  private let scrollBackdropView = UIView()
  private var hasSetupScrollViewCompleted = false

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
  private let debounce = Debounce(interval: 0.8)

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
        imageProvider: .init(image: image)
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
    
    self.store = .init(initialState: .init(), logger: nil)

    super.init(frame: .zero)
    
    scrollBackdropView.accessibilityIdentifier = "scrollBackdropView"

    clipsToBounds = false

    addSubview(scrollBackdropView)
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
          
          state.ifChanged({
            (
              $0.frame,
              $0.layoutVersion
            )
          }, .init(==)) { (frame, _) in
       
            guard let crop = state.proposedCrop else {
              return
            }
            
            guard frame != .zero else {
              return
            }
                        
            setupScrollViewOnce: do {
              if self.hasSetupScrollViewCompleted == false {
                self.hasSetupScrollViewCompleted = true
                
                let scrollView = self.scrollView
                
                self.imageView.bounds = .init(origin: .zero, size: crop.scrollViewContentSize())
                
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
              preferredAspectRatio: state.preferredAspectRatio,
              animated: state.previous?.proposedCrop != nil /* whether first time load */,
              animatesRotation: state.hasChanges(\.proposedCrop?.rotation)
            )
            
          }
          
          if self.isAutoApplyEditingStackEnabled {
            state.ifChanged(\.proposedCrop) { crop in
              guard let crop = crop else {
                return
              }
              self.editingStack.crop(crop)
            }
          }
          
          state.ifChanged(\.isGuideInteractionEnabled) { value in
            self.guideView.isUserInteractionEnabled = value
          }
        }
        .store(in: &subscriptions)
        
        var appliedCrop = false
        
        editingStack.sinkState { [weak self] state in
          
          guard let self = self else { return }
                                             
          if let loaded = state._beta_map(\.loadedState) {
            
            loaded.ifChanged(\.editingSourceImage) { image in
              self.setImage(image)
            }
            
            if appliedCrop == false {
              appliedCrop = true
              self.setCrop(loaded.currentEdit.crop)
            }
                        
          }
          
          state.ifChanged(\.isLoading) { isLoading in
            self.updateLoadingState(displays: isLoading)
          }
                              
        }
        .store(in: &subscriptions)
      }
      
    }
    
  }
  
  private func updateLoadingState(displays: Bool) {
    
    if displays, let factory = self.loadingOverlayFactory {
      
      guideView.alpha = 0
      scrollView.alpha = 0
      
      let loadingOverlay = factory()
      self.currentLoadingOverlay = loadingOverlay
      self.addSubview(loadingOverlay)
      AutoLayoutTools.setEdge(loadingOverlay, self)
      
      loadingOverlay.alpha = 0
      UIViewPropertyAnimator(duration: 0.4, dampingRatio: 1) {
        loadingOverlay.alpha = 1
      }
      .startAnimation()
      
    } else {
              
      if let view = currentLoadingOverlay {
        
        layoutIfNeeded()
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          view.alpha = 0
          self.guideView.alpha = 1
          self.scrollView.alpha = 1
        }&>.do {
          $0.addCompletion { _ in
            view.removeFromSuperview()                       
          }
          $0.startAnimation(afterDelay: 0.2)
        }
      }
                 
    }
    
  }
    
  /**
   Renders an image according to the editing.

   - Attension: This operation can be run background-thread.
   */
  public func renderImage() throws -> ImageRenderer.Rendered? {
    applyEditingStack()
    return try editingStack.makeRenderer().render()
  }
  
  /**
   Applies the current state to the EditingStack.
   */
  public func applyEditingStack() {
    guard let crop = store.state.proposedCrop else {
      EditorLog.warn("EditingStack has not completed loading.")
      return
    }
    editingStack.crop(crop)
  }

  public func resetCrop() {
    _pixeleditor_ensureMainThread()

    store.commit {
      if let proposedCrop = $0.proposedCrop {
        $0.proposedCrop = proposedCrop.makeInitial()
        if let ratio = $0.preferredAspectRatio {
          $0.proposedCrop!.updateCropExtentIfNeeded(by: ratio)
        }
        $0.layoutVersion += 1
      }
    }

    guideView.setLockedAspectRatio(nil)
  }

  public func setRotation(_ rotation: EditingCrop.Rotation) {
    _pixeleditor_ensureMainThread()

    store.commit {
      $0.proposedCrop?.rotation = rotation        
      $0.layoutVersion += 1
    }
  }

  public func setCrop(_ crop: EditingCrop) {
    _pixeleditor_ensureMainThread()
    
    store.commit {
      $0.proposedCrop = crop
      if let ratio = $0.preferredAspectRatio {
        $0.proposedCrop?.updateCropExtentIfNeeded(by: ratio)
      }
      $0.layoutVersion += 1
    }
  }

  public func setCroppingAspectRatio(_ ratio: PixelAspectRatio?) {
    _pixeleditor_ensureMainThread()

    store.commit {
      $0.preferredAspectRatio = ratio
      if let ratio = ratio {
        $0.proposedCrop?.updateCropExtentIfNeeded(by: ratio)
      }
      $0.layoutVersion += 1
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
    
    if let outOfBoundsOverlay = cropOutsideOverlay {
      // TODO: Get an optimized size
      outOfBoundsOverlay.frame.size = .init(width: UIScreen.main.bounds.width * 1.5, height: UIScreen.main.bounds.height * 1.5)
      outOfBoundsOverlay.center = center
    }
    
    /// to update masking with cropOutsideOverlay
    guideView.setNeedsLayout()
    
    store.commit {
      if $0.frame != frame {
        $0.frame = frame
      }
    }
       
  }

  private func updateScrollContainerView(
    by crop: EditingCrop,
    preferredAspectRatio: PixelAspectRatio?,
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
          guideView.setLockedAspectRatio(preferredAspectRatio)
        case .angle_90:
          size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(preferredAspectRatio?.swapped())
        case .angle_180:
          size = aspectRatio.sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(preferredAspectRatio)
        case .angle_270:
          size = aspectRatio.swapped().sizeThatFits(in: bounds.size)
          guideView.setLockedAspectRatio(preferredAspectRatio?.swapped())
        }

        scrollView.transform = crop.rotation.transform
        
        scrollView.frame = .init(
          origin: .init(
            x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
            y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
          ),
          size: size
        )
        
        scrollBackdropView.frame = scrollView.frame
      }

      applyLayoutDescendants: do {
        guideView.frame = scrollView.frame
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
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) { [self] in
          perform()
          layoutIfNeeded()
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
    debounce.on { /* for debounce */ }
  }

  @inline(__always)
  private func didChangeGuideViewWithDelay() {
            
    func applyCropRotation(rotation: EditingCrop.Rotation, insets: UIEdgeInsets) -> UIEdgeInsets {
      switch rotation {
      case .angle_0:
        return insets
      case .angle_90:
        return .init(
          top: insets.left,
          left: insets.bottom,
          bottom: insets.right,
          right: insets.top
        )
      case .angle_180:
        return .init(
          top: insets.bottom,
          left: insets.right,
          bottom: insets.top,
          right: insets.left
        )
      case .angle_270:
        return .init(
          top: insets.right,
          left: insets.top,
          bottom: insets.left,
          right: insets.bottom
        )
      }
    }
    
    guard let currentProposedCrop = store.state.proposedCrop else {
      return
    }
    
    let visibleRect = guideView.convert(guideView.bounds, to: imageView)
             
    updateContentInset: do {
      let rect = self.guideView.convert(self.guideView.bounds, to: scrollBackdropView)

      let bounds = scrollBackdropView.bounds
      let insets = UIEdgeInsets.init(
        top: rect.minY,
        left: rect.minX,
        bottom: bounds.maxY - rect.maxY,
        right: bounds.maxX - rect.maxX
      )
            
      let resolvedInsets = applyCropRotation(rotation: currentProposedCrop.rotation, insets: insets)
                  
      scrollView.contentInset = resolvedInsets
    }
    
    EditorLog.debug("[CropView] visbleRect : \(visibleRect), guideViewFrame: \(guideView.frame)")
                          
    store.commit {      
      // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
      $0.proposedCrop?.updateCropExtentNormalizing(visibleRect, respectingAspectRatio: $0.preferredAspectRatio)
    }
        
    /// Triggers layout update later
    debounce.on { [weak self] in

      guard let self = self else { return }

      self.store.commit {
        $0.layoutVersion += 1
      }
    }
  }

  @inline(__always)
  private func didChangeScrollView() {
    store.commit {
      let rect = guideView.convert(guideView.bounds, to: imageView)
      // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
      $0.proposedCrop?.updateCropExtentNormalizing(rect, respectingAspectRatio: $0.preferredAspectRatio)
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
    
    debounce.on { [weak self] in
      
      guard let self = self else { return }
      
      self.store.commit {
        $0.layoutVersion += 1
      }
    }
  }
  
  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    
    debounce.on { [weak self] in
      
      guard let self = self else { return }
      
      self.store.commit {
        $0.layoutVersion += 1
      }
    }
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
