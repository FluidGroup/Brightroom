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
  
  public struct Handlers {
    public var didFinish: () -> Void = {}
  }
  
  private let containerView: _Crop.CropView = .init()

  public let editingStack: EditingStack
  public var handlers = Handlers()

  private var bag = Set<VergeAnyCancellable>()
  
  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = .white

    let topStackView = UIStackView()&>.do {
      let rotateButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Rotate", for: .normal)
        $0.addTarget(self, action: #selector(handleRotateButton), for: .touchUpInside)
      }
      
      let resetButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Reset", for: .normal)
        $0.addTarget(self, action: #selector(handleResetButton), for: .touchUpInside)
      }
      
      $0.addArrangedSubview(rotateButton)
      $0.addArrangedSubview(resetButton)
    }

    let bottomStackView = UIStackView()&>.do {
      let cancelButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Cancel", for: .normal)
        $0.addTarget(self, action: #selector(handleCancelButton), for: .touchUpInside)
      }

      let doneButton = UIButton(type: .system)&>.do {
        // TODO: Localize
        $0.setTitle("Done", for: .normal)
        $0.addTarget(self, action: #selector(handleDoneButton), for: .touchUpInside)
      }
      $0.addArrangedSubview(cancelButton)
      $0.addArrangedSubview(doneButton)
    }

    view.addSubview(containerView)
    view.addSubview(topStackView)
    view.addSubview(bottomStackView)

    topStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: view.topAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
      ])
    }

    containerView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: topStackView.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
      ])
    }

    bottomStackView&>.do {
      $0.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        $0.topAnchor.constraint(equalTo: containerView.bottomAnchor),
        $0.leftAnchor.constraint(equalTo: view.leftAnchor),
        $0.rightAnchor.constraint(equalTo: view.rightAnchor),
        $0.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      ])
    }

    editingStack.sinkState { [weak self] state in

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
    
    containerView.store.sinkState { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.proposedCropAndRotate) { (cropAndRotate) in
        guard let cropAndRotate = cropAndRotate else { return }
        self.editingStack.crop(cropAndRotate)
      }
    }
    .store(in: &bag)
  }

  @objc private func handleRotateButton() {
    let rotation = containerView.store.state.proposedCropAndRotate?.rotation.next()
    rotation.map {
      containerView.setRotation($0)
    }
  }
  
  @objc private func handleResetButton() {
    containerView.resetCropAndRotate()
  }

  @objc private func handleCancelButton() {
    handlers.didFinish()
  }

  @objc private func handleDoneButton() {
    handlers.didFinish()
  }
}

enum _Crop {
  /**
   A view that previews how crops the image.
   */
  public final class CropView: UIView, UIScrollViewDelegate {
    public struct State: Equatable {
      public fileprivate(set) var proposedCropAndRotate: CropAndRotate?
      public fileprivate(set) var frame: CGRect = .zero
      fileprivate var hasLoaded = false
    }

    /**
     An image view that displayed in the scroll view.
     */
    private let imageView = UIImageView()
    private let scrollView = CropScrollView()

    /**
     a guide view that displayed on guide container view.
     */
    private lazy var guideView = InteractiveCropGuideView(containerView: self, imageView: self.imageView)

    public let store: UIStateStore<State, Never> = .init(initialState: .init(), logger: nil)

    private var subscriptions = Set<VergeAnyCancellable>()

    /// A throttling timer to apply guide changed event.
    ///
    /// This's waiting for Combine availability in minimum iOS Version.
    private let throttle = Debounce(interval: 1)

    public init() {
      super.init(frame: .zero)

      addSubview(scrollView)
      addSubview(guideView)

      imageView.isUserInteractionEnabled = true
      scrollView.addSubview(imageView)
      scrollView.delegate = self

      let overlay = UIView()&>.do {
        $0.backgroundColor = .init(white: 0, alpha: 0.7)
      }

      guideView.setOverlay(overlay)

      guideView.didChange = { [weak self] in
        guard let self = self else { return }
        self.didChangeGuideViewWithDelay()
      }

      guideView.willChange = { [weak self] in
        guard let self = self else { return }
        self.willChangeGuideView()
      }

      #if DEBUG
      store.sinkState { state in
        EditorLog.debug(state.primitive)
      }
      .store(in: &subscriptions)
      #endif

      store.sinkState(queue: .mainIsolated()) { [weak self] state in

        guard let self = self else { return }

        state.ifChanged(\.proposedCropAndRotate, \.frame) { cropAndRotate, frame in
          
          guard frame != .zero else { return }

          if let cropAndRotate = cropAndRotate {
            self.updateScrollContainerView(
              by: cropAndRotate,
              animated: state.hasLoaded,
              animatesRotation: state.hasChanges(\.proposedCropAndRotate?.rotation)
            )
          } else {
            // TODO:
          }
        }
      }
      .store(in: &subscriptions)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override public func layoutSubviews() {
      super.layoutSubviews()

      store.commit {
        if $0.frame != frame {
          $0.frame = frame
        }
      }
    }

    override public func didMoveToSuperview() {
      super.didMoveToSuperview()

      store.commit {
        $0.hasLoaded = superview != nil
      }
    }

    public func setImage(_ image: CIImage) {
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
    
    public func resetCropAndRotate() {
      store.commit {
        $0.proposedCropAndRotate = $0.proposedCropAndRotate?.makeInitial()
      }
    }

    public func setRotation(_ rotation: CropAndRotate.Rotation) {
      store.commit {
        $0.proposedCropAndRotate?.rotation = rotation
      }
    }

    public func setCropAndRotate(_ cropAndRotate: CropAndRotate) {
      store.commit {
        $0.proposedCropAndRotate = cropAndRotate
      }
    }

    private func updateScrollContainerView(
      by cropAndRotate: CropAndRotate,
      animated: Bool,
      animatesRotation: Bool
    ) {

      func perform() {
        frame: do {
          let insets = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
          let bounds = self.bounds.inset(by: insets)

          let size: CGSize
          switch cropAndRotate.rotation {
          case .angle_0:
            size = cropAndRotate.aspectRatio.sizeThatFits(in: bounds.size)
          case .angle_90:
            size = cropAndRotate.aspectRatio.swapped().sizeThatFits(in: bounds.size)
          case .angle_180:
            size = cropAndRotate.aspectRatio.sizeThatFits(in: bounds.size)
          case .angle_270:
            size = cropAndRotate.aspectRatio.swapped().sizeThatFits(in: bounds.size)
          }

          scrollView.transform = cropAndRotate.rotation.transform

          scrollView.frame = .init(
            origin: .init(
              x: insets.left + ((bounds.width - size.width) / 2) /* centering offset */,
              y: insets.top + ((bounds.height - size.height) / 2) /* centering offset */
            ),
            size: size
          )
        }

        applyLayoutDescendants: do {
          guideView.frame = scrollView.frame
        }

        zoom: do {
          UIView.performWithoutAnimation {
            let currentZoomScale = scrollView.zoomScale
            scrollView.zoomScale = 1
            scrollView.contentSize = cropAndRotate.scrollViewContentSize()
            scrollView.zoomScale = currentZoomScale
          }
          imageView.bounds = .init(origin: .zero, size: cropAndRotate.scrollViewContentSize())

          let (min, max) = cropAndRotate.calculateZoomScale(scrollViewBounds: scrollView.bounds)

          scrollView.minimumZoomScale = min
          scrollView.maximumZoomScale = max

          scrollView.zoom(to: cropAndRotate.cropExtent.cgRect, animated: false)
        }
      }

      if animated {
        layoutIfNeeded()
        
        print("animate")
        
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
            $0.isUserInteractionEnabled = false
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

    private func setImage(image: UIImage) {
      guard let imageSize = store.state.proposedCropAndRotate?.imageSize else {
        assertionFailure("Call configureImageForSize before.")
        return
      }

      assert(image.scale == 1)
      assert(image.size == imageSize.cgSize)
      imageView.image = image
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
          if var crop = $0.proposedCropAndRotate {
            crop.cropExtent = .init(cgRect: rect)
            $0.proposedCropAndRotate = crop
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

        if var crop = $0.proposedCropAndRotate {
          crop.cropExtent = .init(cgRect: rect)
          $0.proposedCropAndRotate = crop
        } else {
          assertionFailure()
        }
      }
    }

    // MARK: UIScrollViewDelegate

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

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate {
        didChangeScrollView()
      }
    }

    func scrollViewDidEndZooming(
      _ scrollView: UIScrollView,
      with view: UIView?,
      atScale scale: CGFloat
    ) {
      didChangeScrollView()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      didChangeScrollView()
    }
  }

  public final class InteractiveCropGuideView: UIView, UIGestureRecognizerDelegate {
    var willChange: () -> Void = {}
    var didChange: () -> Void = {}
    
    private let topLeftControlPointView = UIView()
    private let topRightControlPointView = UIView()
    private let bottomLeftControlPointView = UIView()
    private let bottomRightControlPointView = UIView()
    
    private let topControlPointView = UIView()
    private let rightControlPointView = UIView()
    private let leftControlPointView = UIView()
    private let bottomControlPointView = UIView()

    private weak var overlay: UIView?

    private unowned let containerView: CropView
    private unowned let imageView: UIImageView

    private var maximumRect: CGRect?

    init(containerView: CropView, imageView: UIImageView) {
      self.containerView = containerView
      self.imageView = imageView

      super.init(frame: .zero)

      [
        topLeftControlPointView,
        topRightControlPointView,
        bottomLeftControlPointView,
        bottomRightControlPointView,
        
        topControlPointView,
        rightControlPointView,
        leftControlPointView,
        bottomControlPointView,
      ].forEach { view in
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
      }

      cornerGestures: do {
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInTopLeft(gesture:))
          )
          topLeftControlPointView.addGestureRecognizer(panGesture)
        }
        
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInTopRight(gesture:))
          )
          topRightControlPointView.addGestureRecognizer(panGesture)
        }
        
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInBottomLeft(gesture:))
          )
          bottomLeftControlPointView.addGestureRecognizer(panGesture)
        }
        
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInBottomRight(gesture:))
          )
          bottomRightControlPointView.addGestureRecognizer(panGesture)
        }
        
      }
      
      edgeGestures: do {
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInTop(gesture:))
          )
          topControlPointView.addGestureRecognizer(panGesture)
        }
        
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInRight(gesture:))
          )
          rightControlPointView.addGestureRecognizer(panGesture)
        }
        
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInLeft(gesture:))
          )
          leftControlPointView.addGestureRecognizer(panGesture)
        }
        
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInBottom(gesture:))
          )
          bottomControlPointView.addGestureRecognizer(panGesture)
        }
      }
      
      let length: CGFloat = 40
      
      topLeftControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.leftAnchor.constraint(equalTo: leftAnchor),
          $0.topAnchor.constraint(equalTo: topAnchor),
          $0.heightAnchor.constraint(equalToConstant: length),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }
      
      topRightControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.rightAnchor.constraint(equalTo: rightAnchor),
          $0.topAnchor.constraint(equalTo: topAnchor),
          $0.heightAnchor.constraint(equalToConstant: length),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }
      
      bottomLeftControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.leftAnchor.constraint(equalTo: leftAnchor),
          $0.bottomAnchor.constraint(equalTo: bottomAnchor),
          $0.heightAnchor.constraint(equalToConstant: length),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }
      
      bottomRightControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.rightAnchor.constraint(equalTo: rightAnchor),
          $0.bottomAnchor.constraint(equalTo: bottomAnchor),
          $0.heightAnchor.constraint(equalToConstant: length),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }
      
      topControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.topAnchor.constraint(equalTo: topAnchor, constant: 0),
          $0.leftAnchor.constraint(equalTo: topLeftControlPointView.rightAnchor),
          $0.rightAnchor.constraint(equalTo: topRightControlPointView.leftAnchor),
          $0.heightAnchor.constraint(equalToConstant: length),
        ])
      }
      
      rightControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.topAnchor.constraint(equalTo: topRightControlPointView.bottomAnchor),
          $0.bottomAnchor.constraint(equalTo: bottomRightControlPointView.topAnchor),
          $0.rightAnchor.constraint(equalTo: rightAnchor),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }

      bottomControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
          $0.leftAnchor.constraint(equalTo: bottomLeftControlPointView.rightAnchor),
          $0.rightAnchor.constraint(equalTo: bottomRightControlPointView.leftAnchor),
          $0.heightAnchor.constraint(equalToConstant: length),
        ])
      }
      
      leftControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.topAnchor.constraint(equalTo: topLeftControlPointView.bottomAnchor),
          $0.bottomAnchor.constraint(equalTo: bottomLeftControlPointView.topAnchor),
          $0.leftAnchor.constraint(equalTo: leftAnchor),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }
    
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Functions

    public func setOverlay(_ newOverlay: UIView?) {
      overlay?.removeFromSuperview()

      if let overlay = newOverlay {
        overlay.isUserInteractionEnabled = false
        addSubview(overlay)
        self.overlay = overlay
      }
    }

    override public func layoutSubviews() {
      super.layoutSubviews()
      overlay?.frame = bounds
    }

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      let view = super.hitTest(point, with: event)

      if view == self {
        return nil
      }

      return view
    }

    private func postprocess(
      proposedFrame: inout CGRect,
      currentFrame: CGRect
    ) {
      assert(self.maximumRect != nil)
      let maximumRect = self.maximumRect!

      if proposedFrame.width < 100 {
        proposedFrame.origin.x = currentFrame.origin.x
        proposedFrame.size.width = currentFrame.size.width
      }

      if proposedFrame.height < 100 {
        proposedFrame.origin.y = currentFrame.origin.y
        proposedFrame.size.height = currentFrame.size.height
      }
      proposedFrame = proposedFrame.intersection(maximumRect)
    }

    @inline(__always)
    private func updateMaximumRect() {
      maximumRect = imageView.convert(imageView.bounds, to: containerView)
        .intersection(containerView.frame.insetBy(dx: 20, dy: 20))
    }

    @objc
    private func handlePanGestureInTopLeft(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        let currentFrame = frame
        var nextFrame = currentFrame

        nextFrame.origin.x += translation.x
        nextFrame.origin.y += translation.y
        nextFrame.size.width -= translation.x
        nextFrame.size.height -= translation.y

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame

      case .cancelled,
           .ended:
        didChange()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInTopRight(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let currentFrame = frame
        var nextFrame = currentFrame

        nextFrame.origin.y += translation.y
        nextFrame.size.width += translation.x
        nextFrame.size.height -= translation.y

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame

      case .cancelled,
           .ended:
        didChange()

      default:
        break
      }
    }

    @objc
    private func handlePanGestureInBottomLeft(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let currentFrame = frame
        var nextFrame = currentFrame

        nextFrame.origin.x += translation.x
        nextFrame.size.width -= translation.x
        nextFrame.size.height += translation.y

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame
      case .cancelled,
           .ended:
        didChange()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInBottomRight(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let currentFrame = frame
        var nextFrame = currentFrame

        nextFrame.size.width += translation.x
        nextFrame.size.height += translation.y

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame
      case .cancelled,
           .ended:
        didChange()
      default:
        break
      }
    }
    
    @objc
    private func handlePanGestureInTop(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)
      
      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        let currentFrame = frame
        var nextFrame = currentFrame
        
        nextFrame.origin.y += translation.y
        nextFrame.size.height -= translation.y
        
        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )
        
        frame = nextFrame
        
      case .cancelled,
           .ended:
        didChange()
      default:
        break
      }
    }
    
    @objc
    private func handlePanGestureInRight(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)
      
      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        let currentFrame = frame
        var nextFrame = currentFrame
        
        nextFrame.size.width += translation.x
        
        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )
        
        frame = nextFrame
        
      case .cancelled,
           .ended:
        didChange()
      default:
        break
      }
    }
    
    @objc
    private func handlePanGestureInLeft(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)
      
      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        let currentFrame = frame
        var nextFrame = currentFrame
        
        nextFrame.origin.x += translation.x
        nextFrame.size.width -= translation.x
        
        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )
        
        frame = nextFrame
        
      case .cancelled,
           .ended:
        didChange()
      default:
        break
      }
    }
    
    @objc
    private func handlePanGestureInBottom(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)
      
      switch gesture.state {
      case .began:
        updateMaximumRect()
        willChange()
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        let currentFrame = frame
        var nextFrame = currentFrame
          
        nextFrame.size.height += translation.y
        
        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )
        
        frame = nextFrame
        
      case .cancelled,
           .ended:
        didChange()
      default:
        break
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
      if #available(iOS 11.0, *) {
        contentInsetAdjustmentBehavior = .never
      } else {
        // Fallback on earlier versions
      }
      showsVerticalScrollIndicator = false
      showsHorizontalScrollIndicator = false
      bouncesZoom = true
      decelerationRate = UIScrollView.DecelerationRate.fast
      clipsToBounds = false
      alwaysBounceVertical = true
      alwaysBounceHorizontal = true
    }
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

final class Debounce {
  private var timerReference: DispatchSourceTimer?

  let interval: TimeInterval
  let queue: DispatchQueue

  private var lastSendTime: Date?

  init(interval: TimeInterval, queue: DispatchQueue = .main) {
    self.interval = interval
    self.queue = queue
  }

  func on(handler: @escaping () -> Void) {
    let deadline = DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(interval * 1000.0))

    timerReference?.cancel()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: deadline)

    timer.setEventHandler(handler: { [weak timer, weak self] in
      self?.lastSendTime = nil
      handler()
      timer?.cancel()
      self?.timerReference = nil
    })
    timer.resume()

    timerReference = timer
  }

  func cancel() {
    timerReference = nil
  }
}
