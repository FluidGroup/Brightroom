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
import SwiftUI
import UIKit
import Verge

#if !COCOAPODS
import BrightroomEngine
#endif

/// A view that previews how crops the image.
///
/// The cropping adjustument is avaibleble from 2 ways:
/// - Scrolling image
/// - Panning guide
///
/// - TODO:
///   - Implicit animations occurs in first time load with remote image.
public final class CropView: UIView, UIScrollViewDelegate {

  public struct State: Equatable {

    public struct AdjustmentKind: OptionSet {

      public var rawValue: Int = 0

      public init(rawValue: Int) {
        self.rawValue = rawValue
      }

      public static let scrollView = AdjustmentKind(rawValue: 1 << 0)
      public static let guide = AdjustmentKind(rawValue: 1 << 1)

    }

    public fileprivate(set) var proposedCrop: EditingCrop?

    public fileprivate(set) var frame: CGRect = .zero

    public fileprivate(set) var adjustmentKind: AdjustmentKind = []

    fileprivate var layoutVersion: UInt64 = 0

    /**
     Returns aspect ratio.
     Would not be affected by rotation.
     */
    public fileprivate(set) var preferredAspectRatio: PixelAspectRatio?
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
      guideView.isUserInteractionEnabled
    }
    set {
      self.guideView.isUserInteractionEnabled = newValue
    }
  }

  /**
   Clips ScrollView to guide view.
   */
  public var clipsToGuide: Bool = false {
    didSet {
      store.commit {
        $0.layoutVersion += 1
      }
    }
  }

  public var areAnimationsEnabled: Bool = true

  public var isImageViewHidden: Bool {
    get {
      imagePlatterView.imageView.isHidden
    }
    set {
      imagePlatterView.imageView.isHidden = newValue
    }
  }

  public var isZoomEnabled: Bool = true {
    didSet {
      store.commit {
        $0.layoutVersion += 1
      }
    }
  }

  public var isScrollEnabled: Bool {
    get {
      scrollView.isScrollEnabled
    }
    set {
      scrollView.isScrollEnabled = newValue
    }
  }

  public let editingStack: EditingStack

  /**
   An image view that displayed in the scroll view.
   */
  private let imagePlatterView = ImagePlatterView()

  private let scrollPlatterView = UIView()

  #if DEBUG
  private let _debug_shapeLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.strokeColor = UIColor.red.cgColor
    layer.fillColor = UIColor.clear.cgColor
    layer.lineWidth = 2
    return layer
  }()
  #endif

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
    imageView: self.imagePlatterView,
    insetOfGuideFlexibility: contentInset
  )

  private let guideMaximumView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "maximumView"
    return view
  }()

  // for now, for debugging
  private let guideShadowingView: UIView = {
    let view = UIView()
    //    #if DEBUG
    //    view.backgroundColor = .systemYellow.withAlphaComponent(0.5)
    //    #endif
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "guideShadowingView"
    return view
  }()

  private let guideBackdropView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "guideBackdropView"
    return view
  }()

  private let guideOutsideContainerView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.accessibilityIdentifier = "guideOutsideContainerView"
    return view
  }()

  private var subscriptions = Set<AnyCancellable>()

  /// A throttling timer to apply guide changed event.
  ///
  /// This's waiting for Combine availability in minimum iOS Version.
  private let debounce = _BrightroomDebounce(interval: 0.8)

  private let contentInset: UIEdgeInsets

  private var loadingOverlayFactory: (() -> UIView)?
  private weak var currentLoadingOverlay: UIView?

  private var isBinding = false

  private var stateHandler: @MainActor (Verge.Changes<CropView.State>) -> Void = { _ in }

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

    scrollBackdropView.accessibilityIdentifier = "scrollBackdropView"

    clipsToBounds = false

    addSubview(scrollPlatterView)
    scrollPlatterView.addSubview(scrollBackdropView)
    scrollPlatterView.addSubview(scrollView)

    addSubview(guideOutsideContainerView)
    addSubview(guideMaximumView)
    addSubview(guideShadowingView)
    addSubview(guideBackdropView)
    addSubview(guideView)

    imagePlatterView.isUserInteractionEnabled = true
    scrollView.addSubview(imagePlatterView)
    scrollView.delegate = self

    guideView.willChange = { [weak self] in
      guard let self = self else { return }
      self.willChangeGuideView()
    }

    guideView.didChange = { [weak self] in
      guard let self = self else { return }
      self.didChangeGuideViewWithDelay()
    }

    guideView.didUpdateAdjustmentKind = { [weak self] kind in
      guard let self else { return }
      self.store.commit {
        $0.adjustmentKind = kind
      }
    }

    #if false
    store.sinkState { state in
      EditorLog.debug(state.primitive)
    }
    .store(in: &subscriptions)
    #endif

    // apply defaultAppearance
    do {
      setCropInsideOverlay(CropView.CropInsideOverlayRuleOfThirdsView())
      setCropOutsideOverlay(CropView.CropOutsideOverlayBlurredView())
      setLoadingOverlay(factory: {
        LoadingBlurryOverlayView(effect: UIBlurEffect(style: .dark), activityIndicatorStyle: .large)
      })
    }

    store.sinkState { [weak self] state in
      self?.stateHandler(state)
    }
    .storeWhileSourceActive()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Functions

  func setStateHandler(_ handler: @escaping @MainActor (Verge.Changes<State>) -> Void) {
    self.stateHandler = handler
  }

  public func setOverlayInImageView(_ overlay: UIView) {
    imagePlatterView.overlay = overlay
  }

  public override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)

    if isBinding == false {
      isBinding = true

      editingStack.start()

      binding: do {
        store.sinkState(queue: .mainIsolated()) { [weak self, areAnimationsEnabled] state in

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

                self.imagePlatterView.bounds = .init(
                  origin: .zero,
                  size: crop.scrollViewContentSize()
                )

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
              animated: areAnimationsEnabled && state.previous?.proposedCrop != nil /* whether first time load */,
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

        }
        .store(in: &subscriptions)

        // To restore current crop from editing-stack
        editingStack.sinkState { [weak self] state in

          guard let self = self else { return }

          if let loaded = state.mapIfPresent(\.loadedState) {

            loaded.ifChanged(\.imageForCrop).do { image in
              self.setImage(image)
            }

            loaded.ifChanged(\.currentEdit.crop).do { crop in
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
        $0.preferredAspectRatio = nil
        $0.layoutVersion += 1
      }
    }

    guideView.setLockedAspectRatio(nil)
  }

  public func setRotation(_ rotation: EditingCrop.Rotation) {
    _pixeleditor_ensureMainThread()

    store.commit {

      guard $0.proposedCrop?.rotation != rotation else {
        return
      }

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

    let records = store.commit {

      guard $0.proposedCrop?.adjustmentAngle != angle else {
        return false
      }

      $0.proposedCrop?.adjustmentAngle = angle
      $0.layoutVersion += 1

      return true
    }

    if records {
      record()
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

    guideView.setLockedAspectRatio(ratio)
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

    guideOutsideContainerView.addSubview(view)

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
    imagePlatterView.image = UIImage(
      cgImage: cgImage,
      scale: 1,
      orientation: .up
    )
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    // TODO: Get an optimized size
    guideOutsideContainerView.frame.size = .init(
      width: UIScreen.main.bounds.width * 1.5,
      height: UIScreen.main.bounds.height * 1.5
    )
    guideOutsideContainerView.center = center

    if let cropOutsideOverlay {
      cropOutsideOverlay.frame = guideOutsideContainerView.bounds
    }

    /// to update masking with cropOutsideOverlay
    guideView.setNeedsLayout()

    store.commit {
      if $0.frame != frame {
        $0.frame = frame
      }
    }

    #if DEBUG
    scrollPlatterView.layer.addSublayer(_debug_shapeLayer)
    #endif

  }

  private func updateScrollContainerView(
    by crop: EditingCrop,
    preferredAspectRatio: PixelAspectRatio?,
    animated: Bool,
    animatesRotation: Bool
  ) {
    func perform() {

      frame: do {

        let contentRect: CGRect = {

          let bounds = self.bounds.inset(by: contentInset)

          let size = PixelAspectRatio(crop.cropExtent.size)
            .sizeThatFits(in: bounds.size)

          return .init(
            origin: .init(
              x: contentInset.left + ((bounds.width - size.width) / 2) /* centering offset */,
              y: contentInset.top + ((bounds.height - size.height) / 2) /* centering offset */
            ),
            size: size
          )
        }()

        let length: CGFloat = 1600
        let scrollViewFrame = CGRect(
          origin: .zero,
          size: .init(width: length, height: length)
        )

        if clipsToGuide {
          scrollPlatterView.bounds.size = contentRect.size
          scrollPlatterView.clipsToBounds = true
        } else {
          scrollPlatterView.bounds.size = scrollViewFrame.size
          scrollPlatterView.clipsToBounds = false
        }

        scrollPlatterView.center = .init(x: self.bounds.midX, y: self.bounds.midY)

        scrollView.bounds.size = scrollViewFrame.size
        scrollView.center = CGPoint(
          x: scrollPlatterView.bounds.midX,
          y: scrollPlatterView.bounds.midY
        )

        scrollBackdropView.bounds.size = scrollViewFrame.size
        scrollBackdropView.center = CGPoint(
          x: scrollPlatterView.bounds.midX,
          y: scrollPlatterView.bounds.midY
        )

        guideMaximumView.frame = contentRect
        guideBackdropView.frame = contentRect

        guideShadowingView.frame = {

          let bounds = self.bounds.inset(by: contentInset)

          let size = PixelAspectRatio(crop.cropExtent.size)
            .sizeThatFits(in: bounds.size)

          return .init(
            origin: .init(
              x: ((contentInset.left + contentInset.right) / 2)
                + ((bounds.width - size.width) / 2) /* centering offset */,
              y: ((contentInset.top + contentInset.bottom) / 2)
                + ((bounds.height - size.height) / 2) /* centering offset */
            ),
            size: size
          )
        }()

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

          imagePlatterView.frame.origin = .zero

          func _zoom() {

            scrollView.customZoom(
              to: crop.zoomExtent(visibleSize: guideView.bounds.size),
              guideSize: guideView.bounds.size,
              adjustmentRotation: crop.aggregatedRotation.radians,
              animated: false
            )

            if isZoomEnabled == false {
              let scale = scrollView.zoomScale
              scrollView.minimumZoomScale = scale
              scrollView.maximumZoomScale = scale
            }

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
    debounce.on { /* for debounce */  }
  }

  private func makeScrollViewInset(aggregatedRotaion: CGFloat) -> UIEdgeInsets {

    let o: CGPoint = {

      let base =
        guideBackdropView
        .convert(
          guideBackdropView.bounds,
          to: scrollBackdropView
        )

      let actualRect =
        guideView
        .convert(
          guideView.bounds,
          to: scrollBackdropView
        )

      return CGPoint(
        x: base.midX - actualRect.midX,
        y: base.midY - actualRect.midY
      )

    }()

    let anchorOffset = CGPoint(
      x: (guideView.bounds.width) / 2 + o.x,
      y: (guideView.bounds.height) / 2 + o.y
    )

    let actualRect =
      guideView
      .convert(
        guideView.bounds.applying(
          CGAffineTransform(translationX: -anchorOffset.x, y: -anchorOffset.y)
            .concatenating(.init(rotationAngle: -aggregatedRotaion))
            .concatenating(.init(translationX: anchorOffset.x, y: anchorOffset.y))
        ),
        to: scrollBackdropView
      )

    let bounds = scrollBackdropView.bounds

    let insetsForActual = UIEdgeInsets.init(
      top: actualRect.minY,
      left: actualRect.minX,
      bottom: bounds.maxY - actualRect.maxY,
      right: bounds.maxX - actualRect.maxX
    )

    return insetsForActual
  }

  private func updateScrollViewInset(crop: EditingCrop) {
    scrollView.contentInset = makeScrollViewInset(
      aggregatedRotaion: crop.aggregatedRotation.radians
    )
  }

  @inline(__always)
  private func didChangeGuideViewWithDelay() {

    guard let currentProposedCrop = store.state.proposedCrop else {
      return
    }

    record()

    updateScrollViewInset(crop: currentProposedCrop)

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

      guard let crop = state.proposedCrop else {
        return
      }

      // remove rotation while converting rect
      let current = scrollView.transform
      let currentGuideViewCenter = guideView.center

      do {
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
        guideView.center = guideBackdropView.center
      }

      // calculate
      let guideRectInImageView = guideView.convert(guideView.bounds, to: imagePlatterView)

      do {
        // restore guide view center same as displaying
        guideView.center = currentGuideViewCenter

        // restore rotation
        scrollView.transform = current
      }

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
    return imagePlatterView
  }

  public func scrollViewDidZoom(_ scrollView: UIScrollView) {

    // TODO: consider if we need this.
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

      guard let self = self else {
        return
      }

      guard self.scrollView.isTracking == false else {
        return
      }

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

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool)
  {
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

  var remainingScroll: UIEdgeInsets {

    guard let crop = store.state.proposedCrop else { 
      return .zero
    }

    let sourceInsets: UIEdgeInsets = {

      let guideViewRectInPlatter = guideView.convert(guideView.bounds, to: imagePlatterView)

      let scale = Geometry.diagonalRatio(to: guideView.bounds.size, from: guideViewRectInPlatter.size)

      print(scale)

      let outbound = imagePlatterView.bounds

      let value = UIEdgeInsets(
        top: guideViewRectInPlatter.minY - outbound.minY,
        left: guideViewRectInPlatter.minX - outbound.minX,
        bottom: outbound.maxY - guideViewRectInPlatter.maxY,
        right: outbound.maxX - guideViewRectInPlatter.maxX
      )

#if false

      let maxRectInPlatter = imagePlatterView.convert(
        guideViewRectInPlatter.inset(by: value.inversed()),
        to: imagePlatterView
      )

      let path = UIBezierPath()
      path.append(.init(rect: guideViewRectInPlatter))
      path.append(.init(rect: maxRectInPlatter))

      imagePlatterView._debug_setPath(path: path)

#endif

      return value.multiplied(scale)

    }()

    var patternAngleDegree = crop.aggregatedRotation.degrees.truncatingRemainder(dividingBy: 360)
    if patternAngleDegree > 0 {
      patternAngleDegree -= 360
    }

    print(patternAngleDegree)

    var resolvedInsets: UIEdgeInsets {
      switch patternAngleDegree {

      case 0:
        return sourceInsets
      case -90:

        return .init(
          top: sourceInsets.right,
          left: sourceInsets.top,
          bottom: sourceInsets.left,
          right: sourceInsets.bottom
        )

      case -180:

        return .init(
          top: sourceInsets.bottom,
          left: sourceInsets.right,
          bottom: sourceInsets.top,
          right: sourceInsets.left
        )

      case -270:

        return .init(
          top: sourceInsets.left,
          left: sourceInsets.bottom,
          bottom: sourceInsets.right,
          right: sourceInsets.top
        )

      case -90..<0:

        return .init(
          top: min(sourceInsets.top, sourceInsets.right),
          left: min(sourceInsets.top, sourceInsets.left),
          bottom: min(sourceInsets.bottom, sourceInsets.left),
          right: min(sourceInsets.bottom, sourceInsets.right)
        )

      case -180..<(-90):

        return .init(
          top: min(sourceInsets.bottom, sourceInsets.right),
          left: min(sourceInsets.top, sourceInsets.right),
          bottom: min(sourceInsets.top, sourceInsets.left),
          right: min(sourceInsets.bottom, sourceInsets.left)
        )

      case -270..<(-180):

        return .init(
          top: min(sourceInsets.bottom, sourceInsets.left),
          left: min(sourceInsets.bottom, sourceInsets.right),
          bottom: min(sourceInsets.top, sourceInsets.right),
          right: min(sourceInsets.top, sourceInsets.left)
        )

      case -360..<(-270):

        return .init(
          top: min(sourceInsets.top, sourceInsets.left),
          left: min(sourceInsets.bottom, sourceInsets.left),
          bottom: min(sourceInsets.bottom, sourceInsets.right),
          right: min(sourceInsets.top, sourceInsets.right)
        )

      default:
        return sourceInsets
      }

    }

    return resolvedInsets

  }
}

extension UIEdgeInsets {
  fileprivate func inversed() -> Self {
    .init(
      top: -top,
      left: -left,
      bottom: -bottom,
      right: -right
    )
  }

  fileprivate func multiplied(_ value: CGFloat) -> Self {
    .init(
      top: top * value,
      left: left * value,
      bottom: bottom * value,
      right: right * value
    )
  }

  fileprivate func minZero() -> Self {
    .init(
      top: max(0, top),
      left: max(0, left),
      bottom: max(0, bottom),
      right: max(0, right)
    )
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

  fileprivate var maxContentOffset: CGPoint {
    CGPoint(
      x: contentSize.width - bounds.width + contentInset.right,
      y: contentSize.height - bounds.height + contentInset.bottom
    )
  }

  fileprivate var minContentOffset: CGPoint {
    CGPoint(
      x: -contentInset.left,
      y: -contentInset.top
    )
  }

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

      var targetContentOffset =
        rect
        .rotated(adjustmentRotation)
        .applying(.init(scaleX: targetScale, y: targetScale))
        .origin

      targetContentOffset.x -= contentInset.left
      targetContentOffset.y -= contentInset.top

      let maxContentOffset = self.maxContentOffset

      let minContentOffset = self.minContentOffset

      targetContentOffset.x = min(
        max(targetContentOffset.x, minContentOffset.x),
        maxContentOffset.x
      )
      targetContentOffset.y = min(
        max(targetContentOffset.y, minContentOffset.y),
        maxContentOffset.y
      )

      setContentOffset(targetContentOffset, animated: false)

      #if DEBUG
      print(
        """
        [Zoom]
        input: \(rect),
        bound: \(boundSize),
        targetScale: \(targetScale),
        targetContentOffset: \(targetContentOffset),
        minContentOffset: \(minContentOffset)
        maxContentOffset: \(maxContentOffset)
        """
      )
      #endif
    }

    if animated {
      let animator = UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1)
      animator.addAnimations {
        run()
      }
      animator.startAnimation()
    } else {
      run()
    }

  }

}
