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
import SwiftUI

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
  
  /**
   Internal scroll view
   */  
  private let scrollView = _CropScrollView()
  
  /**
   A background view for scroll view.
   It provides the frame to scroll view.
   */
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

  private let guideBackdropView = UIView()

  private var subscriptions = Set<AnyCancellable>()

  /// A throttling timer to apply guide changed event.
  ///
  /// This's waiting for Combine availability in minimum iOS Version.
  private let debounce = _BrightroomDebounce(interval: 0.8)

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
  ) throws {
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
    
    guideBackdropView.isUserInteractionEnabled = false
    scrollBackdropView.accessibilityIdentifier = "scrollBackdropView"

    clipsToBounds = false

    addSubview(scrollBackdropView)
    addSubview(scrollView)
    addSubview(guideBackdropView)
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

      editingStack.start()
      
      binding: do {
        store.sinkState(queue: .mainIsolated()) { [weak self] state in
          
          guard let self = self else { return }
          
          state.ifChanged({
            (
              $0.frame,
              $0.layoutVersion
            )
          }).do { (frame, _) in

            guard let crop = state.proposedCrop else {
              return
            }
            
            guard frame != .zero else {
              return
            }
                        
            setupScrollViewOnce: do {
              if self.hasSetupScrollViewCompleted == false {
                self.hasSetupScrollViewCompleted = true

                self.imageView.bounds = .init(origin: .zero, size: crop.scrollViewContentSize())

                let scrollView = self.scrollView

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
            state.ifChanged(\.proposedCrop).do { crop in
              guard let crop = crop else {
                return
              }
              self.editingStack.crop(crop)
            }
          }
          
          state.ifChanged(\.isGuideInteractionEnabled).do { value in
            self.guideView.isUserInteractionEnabled = value
          }
        }
        .store(in: &subscriptions)
        
        var appliedCrop = false
        
        // To restore current crop from editing-stack
        editingStack.sinkState { [weak self] state in
          
          guard let self = self else { return }
                                             
          if let loaded = state.mapIfPresent(\.loadedState) {
            
            loaded.ifChanged(\.imageForCrop).do { image in
              self.setImage(image)
            }
            
            if appliedCrop == false {
              appliedCrop = true
              self.setCrop(loaded.currentEdit.crop)
            }
                        
          }
          
          state.ifChanged(\.isLoading).do { isLoading in
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
  public func renderImage() throws -> BrightRoomImageRenderer.Rendered? {
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
          $0.proposedCrop!.updateCropExtentIfNeeded(toFitAspectRatio: ratio)
        }
        $0.layoutVersion += 1
      }
    }

    guideView.setLockedAspectRatio(nil)
  }

  public func setRotation(_ rotation: EditingCrop.Rotation) {
    _pixeleditor_ensureMainThread()

    store.commit {

      if let crop = $0.proposedCrop {

        $0.proposedCrop?.updateCropExtent(
          crop.cropExtent.rotated((crop.rotation.angle - rotation.angle).radians),
          respectingAspectRatio: nil
        )

        $0.proposedCrop?.rotation = rotation
      }

      $0.layoutVersion += 1
    }

  }

  public func setAdjustmentAngle(_ angle: EditingCrop.AdjustmentAngle) {

    store.commit {
      $0.proposedCrop?.adjustmentAngle = angle
      $0.layoutVersion += 1
    }

  }

  public func setCrop(_ crop: EditingCrop) {
    _pixeleditor_ensureMainThread()
    
    store.commit {
      guard $0.proposedCrop != crop else {
        return
      }

      $0.proposedCrop = crop
      if let ratio = $0.preferredAspectRatio {
        $0.proposedCrop?.updateCropExtentIfNeeded(toFitAspectRatio: ratio)
      }
      $0.layoutVersion += 1
    }
  }

  public func setCroppingAspectRatio(_ ratio: PixelAspectRatio?) {
    _pixeleditor_ensureMainThread()

    store.commit {

      guard $0.preferredAspectRatio != ratio else {
        return
      }

      $0.preferredAspectRatio = ratio
      if let ratio = ratio {
        $0.proposedCrop?.updateCropExtentIfNeeded(toFitAspectRatio: ratio)
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

  public func swapCropRectangleDirection() {

    store.commit {

      guard let crop = $0.proposedCrop else {
        return
      }

      $0.proposedCrop?.updateCropExtentIfNeeded(
        toFitAspectRatio: PixelAspectRatio(crop.cropExtent.size).swapped()
      )
      $0.layoutVersion += 1

    }
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
  private func setImage(_ cgImage: CGImage) {
    imageView.image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
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

        size = aspectRatio.sizeThatFitsWithRounding(in: bounds.size)

        let contentRect = CGRect(
          origin: .init(
            x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
            y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
          ),
          size: size
        )

        let length: CGFloat = 1600
        let frame = CGRect(origin: .zero, size: .init(width: length, height: length))

        scrollView.bounds.size = frame.size
        scrollView.center = .init(x: bounds.midX, y: bounds.midY)

        scrollBackdropView.bounds.size = frame.size
        scrollBackdropView.center = .init(x: bounds.midX, y: bounds.midY)

        guideBackdropView.transform = .identity
        guideBackdropView.frame = contentRect

        guideView.frame = contentRect

        scrollView.transform = CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians)

        updateScrollViewInset(crop: crop)

        // zoom
        do {

          let (min, max) = crop.calculateZoomScale(
            visibleSize: guideView.bounds
              .applying(CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians))
              .size
          )

          scrollView.minimumZoomScale = min
          scrollView.maximumZoomScale = max

          imageView.frame.origin = .zero

          func _zoom() {

            scrollView.customZoom(
              to: crop.zoomExtent(visibleSize: guideView.bounds.size),
              guideSize: guideView.bounds.size,
              adjustmentRotation: crop.aggregatedRotation.radians,
              animated: false
            )

          }

          _zoom()

        }
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
    // flush scheduled debouncing
    debounce.on { /* for debounce */ }
  }

  private func updateScrollViewInset(crop: EditingCrop) {

    // update content inset
    do {

      let rect = guideView
        .convert(
          guideView.bounds.rotated(crop.aggregatedRotation.radians),
          to: scrollBackdropView
        )

      let bounds = scrollBackdropView.bounds

      let insets = UIEdgeInsets.init(
        top: rect.minY,
        left: rect.minX,
        bottom: bounds.maxY - rect.maxY,
        right: bounds.maxX - rect.maxX
      )

      let resolvedInsets = insets

      scrollView.contentInset = resolvedInsets
    }
  }

  @inline(__always)
  private func didChangeGuideViewWithDelay() {

    guard let currentProposedCrop = store.state.proposedCrop else {
      return
    }

    updateScrollViewInset(crop: currentProposedCrop)

    record()

    /// Triggers layout update later
    debounce.on { [weak self] in

      guard let self = self else { return }

      self.store.commit {
        $0.layoutVersion += 1
      }
    }
  }

  private func record() {
    store.commit { state in

      let crop = state.proposedCrop!

      // remove rotation while converting rect
      let current = scrollView.transform

      // rotating support
      let croppingRect = guideView.convert(guideView.bounds, to: guideBackdropView)

      // offsets guide view rect in maximum size
      // for case of adjusted guide view by interaction
      let offsetX = croppingRect.midX - guideBackdropView.bounds.midX
      let offsetY = croppingRect.midY - guideBackdropView.bounds.midY

      // move focusing area to center
      scrollView.transform = CGAffineTransform(rotationAngle: crop.aggregatedRotation.radians)
        .concatenating(.init(translationX: -offsetX, y: -offsetY))
        .concatenating(.init(rotationAngle: -crop.aggregatedRotation.radians))

      // TODO: Find calculation way withoug using convert rect
      // To work correctly, ignoring transform temporarily.

      // move the guide view to center for convert-rect.
      let currentGuideViewCenter = guideView.center
      guideView.center = guideBackdropView.center

      let guideRectInImageView = guideView.convert(guideView.bounds, to: imageView)

      // restore guide view center same as displaying
      guideView.center = currentGuideViewCenter

      // restore rotation
      scrollView.transform = current

      // make crop extent for image
      // converts rectangle for display into image's geometry.
      let resolvedRect = crop.makeCropExtent(
        rect: guideRectInImageView
      )

      // TODO: Might cause wrong cropping if set the invalid size or origin. For example, setting width:0, height: 0 by too zoomed in.
      let preferredAspectRatio = state.preferredAspectRatio
      state.proposedCrop?.updateCropExtent(
        resolvedRect,
        respectingAspectRatio: preferredAspectRatio
      )
    }
  }

  @inline(__always)
  private func didChangeScrollView() {
    record()
  }

  // MARK: UIScrollViewDelegate

  public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return imageView
  }

  public func scrollViewDidZoom(_ scrollView: UIScrollView) {

    // adjustFrameToCenterOnZooming
//    do {
//      var frameToCenter = imageView.frame
//
//      // center horizontally
//      if frameToCenter.size.width < scrollView.bounds.width {
//        frameToCenter.origin.x = (scrollView.bounds.width - frameToCenter.size.width) / 2
//      } else {
//        frameToCenter.origin.x = 0
//      }
//
//      // center vertically
//      if frameToCenter.size.height < scrollView.bounds.height {
//        frameToCenter.origin.y = (scrollView.bounds.height - frameToCenter.size.height) / 2
//      } else {
//        frameToCenter.origin.y = 0
//      }
//
//      imageView.frame = frameToCenter
//    }

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

      guard self.scrollView.isTracking == false else { return }
      
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

extension CGRect {

  /// Return a rect rotated around center
  fileprivate func rotated(_ radians: Double) -> CGRect {

    let rotated = self.applying(.init(rotationAngle: radians))

    return .init(
      x: self.minX - (rotated.width - self.width) / 2,
      y: self.minY - (rotated.height - self.height) / 2,
      width: rotated.width,
      height: rotated.height
    )
  }

}

extension UIScrollView {

  fileprivate func customZoom(
    to rect: CGRect,
    guideSize: CGSize,
    adjustmentRotation: CGFloat,
    animated: Bool
  ) {

    func run() {

      let targetContentSize = rect.size
      let boundSize = guideSize

      let minXScale = boundSize.width / targetContentSize.width
      let minYScale = boundSize.height / targetContentSize.height
      let targetScale = min(minXScale, minYScale)

      setZoomScale(targetScale, animated: false)

      var targetContentOffset = rect
        .rotated(adjustmentRotation)
        .applying(.init(scaleX: targetScale, y: targetScale))
        .origin

      targetContentOffset.x -= contentInset.left
      targetContentOffset.y -= contentInset.top

      let maxContentOffset = CGPoint(
        x: contentSize.width - boundSize.width + contentInset.left,
        y: contentSize.height - boundSize.height + contentInset.top
      )

      let minContentOffset = CGPoint(
        x: -contentInset.left,
        y: -contentInset.top
      )

      targetContentOffset.x = min(max(targetContentOffset.x, minContentOffset.x), maxContentOffset.x)
      targetContentOffset.y = min(max(targetContentOffset.y, minContentOffset.y), maxContentOffset.y)

      setContentOffset(targetContentOffset, animated: false)

#if DEBUG
      print("""
[Zoom]
input: \(rect),
bound: \(boundSize),
targetScale: \(targetScale),
targetContentOffset: \(targetContentOffset),
minContentOffset: \(minContentOffset)
maxContentOffset: \(maxContentOffset)
""")
#endif
    }

    if animated {
      let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1)
      animator.addAnimations { [self] in
        run()
      }
      animator.startAnimation()
    } else {
      run()
    }

  }

}
