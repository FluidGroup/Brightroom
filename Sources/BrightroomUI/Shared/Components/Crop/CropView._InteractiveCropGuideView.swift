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

import UIKit
#if !COCOAPODS
import BrightroomEngine
#endif

extension CropView {
  
  private final class TapExpandedView: PixelEditorCodeBasedView {
    
    let horizontal: CGFloat
    let vertical: CGFloat
    
    init(horizontal: CGFloat, vertical: CGFloat) {
      self.horizontal = horizontal
      self.vertical = vertical
      super.init(frame: .zero)
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      bounds.insetBy(dx: -horizontal, dy: -vertical).contains(point)
    }
  }
  
  final class _InteractiveCropGuideView: PixelEditorCodeBasedView, UIGestureRecognizerDelegate {

    var willChange: () -> Void = {}
    var updating: () -> Void = {}
    var didChange: () -> Void = {}

    var didUpdateAdjustmentKind: (CropView.State.AdjustmentKind) -> Void = { _ in }

    private let topLeftControlPointView = TapExpandedView(horizontal: 16, vertical: 16)
    private let topRightControlPointView = TapExpandedView(horizontal: 16, vertical: 16)
    private let bottomLeftControlPointView = TapExpandedView(horizontal: 16, vertical: 16)
    private let bottomRightControlPointView = TapExpandedView(horizontal: 16, vertical: 16)

    private let topControlPointView = TapExpandedView(horizontal: 0, vertical: 16)
    private let rightControlPointView = TapExpandedView(horizontal: 16, vertical: 0)
    private let leftControlPointView = TapExpandedView(horizontal: 16, vertical: 0)
    private let bottomControlPointView = TapExpandedView(horizontal: 0, vertical: 16)

    private weak var cropInsideOverlay: CropInsideOverlayBase?
    private weak var cropOutsideOverlay: CropOutsideOverlayBase?

    private unowned let containerView: CropView
    private unowned let imageView: UIView

    private lazy var invertedMaskShapeLayerView = MaskView()

    private var maximumRect: CGRect?

    private(set) var lockedAspectRatio: PixelAspectRatio?

    private let minimumSize = CGSize(width: 80, height: 80)
    
    private let insetOfGuideFlexibility: UIEdgeInsets

    init(
      containerView: CropView,
      imageView: UIView,
      insetOfGuideFlexibility: UIEdgeInsets
    ) {
      self.containerView = containerView
      self.imageView = imageView
      self.insetOfGuideFlexibility = insetOfGuideFlexibility

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
          panGesture.delegate = self
          topLeftControlPointView.addGestureRecognizer(panGesture)
        }

        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInTopRight(gesture:))
          )
          panGesture.delegate = self
          topRightControlPointView.addGestureRecognizer(panGesture)
        }

        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInBottomLeft(gesture:))
          )
          panGesture.delegate = self
          bottomLeftControlPointView.addGestureRecognizer(panGesture)
        }

        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInBottomRight(gesture:))
          )
          panGesture.delegate = self
          bottomRightControlPointView.addGestureRecognizer(panGesture)
        }
      }

      edgeGestures: do {
        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInTop(gesture:))
          )
          panGesture.delegate = self
          topControlPointView.addGestureRecognizer(panGesture)
        }

        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInRight(gesture:))
          )
          panGesture.delegate = self
          rightControlPointView.addGestureRecognizer(panGesture)
        }

        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInLeft(gesture:))
          )
          panGesture.delegate = self
          leftControlPointView.addGestureRecognizer(panGesture)
        }

        do {
          let panGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGestureInBottom(gesture:))
          )
          panGesture.delegate = self
          bottomControlPointView.addGestureRecognizer(panGesture)
        }
      }

      let length: CGFloat = 1

      topLeftControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.leftAnchor.constraint(equalTo: leftAnchor),
          $0.topAnchor.constraint(equalTo: topAnchor),
          $0.heightAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
          $0.widthAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
        ])
      }

      topRightControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.rightAnchor.constraint(equalTo: rightAnchor),
          $0.topAnchor.constraint(equalTo: topAnchor),
          $0.heightAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
          $0.widthAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
        ])
      }

      bottomLeftControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.leftAnchor.constraint(equalTo: leftAnchor),
          $0.bottomAnchor.constraint(equalTo: bottomAnchor),
          $0.heightAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
          $0.widthAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
        ])
      }

      bottomRightControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.rightAnchor.constraint(equalTo: rightAnchor),
          $0.bottomAnchor.constraint(equalTo: bottomAnchor),
          $0.heightAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
          $0.widthAnchor.constraint(equalToConstant: length)&>.do {
            $0.priority = .defaultHigh
          },
        ])
      }

      topControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.topAnchor.constraint(equalTo: topAnchor, constant: 0),
          $0.leftAnchor.constraint(equalTo: topLeftControlPointView.rightAnchor, constant: 16),
          $0.rightAnchor.constraint(equalTo: topRightControlPointView.leftAnchor, constant: -16),
          $0.heightAnchor.constraint(equalToConstant: length),
        ])
      }

      rightControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.topAnchor.constraint(equalTo: topRightControlPointView.bottomAnchor, constant: 16),
          $0.bottomAnchor.constraint(equalTo: bottomRightControlPointView.topAnchor, constant: -16),
          $0.rightAnchor.constraint(equalTo: rightAnchor),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }

      bottomControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
          $0.leftAnchor.constraint(equalTo: bottomLeftControlPointView.rightAnchor, constant: 16),
          $0.rightAnchor.constraint(equalTo: bottomRightControlPointView.leftAnchor, constant: -16),
          $0.heightAnchor.constraint(equalToConstant: length),
        ])
      }

      leftControlPointView&>.do {
        NSLayoutConstraint.activate([
          $0.topAnchor.constraint(equalTo: topLeftControlPointView.bottomAnchor, constant: 16),
          $0.bottomAnchor.constraint(equalTo: bottomLeftControlPointView.topAnchor, constant: -16),
          $0.leftAnchor.constraint(equalTo: leftAnchor),
          $0.widthAnchor.constraint(equalToConstant: length),
        ])
      }
    }

    // MARK: - Functions

    /**
     Displays a view as an overlay.
     e.g. grid view
     */
    func setCropInsideOverlay(_ newOverlay: CropInsideOverlayBase?) {
      cropInsideOverlay?.removeFromSuperview()

      if let overlay = newOverlay {
        overlay.isUserInteractionEnabled = false
        addSubview(overlay)
        cropInsideOverlay = overlay
      }
    }

    func setCropOutsideOverlay(_ view: CropOutsideOverlayBase?) {
      defer {
        setNeedsLayout()
        layoutIfNeeded()
      }
      
      guard let view = view else {
        cropOutsideOverlay = nil
        return
      }
      
      assert(view.superview != nil)

      cropOutsideOverlay = view
   
    }

    func setLockedAspectRatio(_ aspectRatio: PixelAspectRatio?) {
      lockedAspectRatio = aspectRatio
    }

    override func layoutSubviews() {
      super.layoutSubviews()

      cropInsideOverlay?.frame = bounds

      if let outOfBoundsOverlayView = cropOutsideOverlay {
        // Take care `outOfBoundsOverlayView` has the latest layout.
        let frame = convert(bounds, to: outOfBoundsOverlayView)
        invertedMaskShapeLayerView.frame = outOfBoundsOverlayView.bounds
        invertedMaskShapeLayerView.setUnmaskRect(frame)

        if outOfBoundsOverlayView.mask == nil {
          outOfBoundsOverlayView.mask = invertedMaskShapeLayerView
        }
      }
    
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      bounds.insetBy(dx: -16, dy: -16).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      
      let view = super.hitTest(point, with: event)
 
      if view == self {
        return nil
      }

      return view
    }

    func willBeginScrollViewAdjustment() {
      cropInsideOverlay?.didBeginAdjustment(kind: .scrollView)
      cropOutsideOverlay?.didBeginAdjustment(kind: .scrollView)
      didUpdateAdjustmentKind(.scrollView)
    }

    func didEndScrollViewAdjustment() {
      cropInsideOverlay?.didEndAdjustment(kind: .scrollView)
      cropOutsideOverlay?.didEndAdjustment(kind: .scrollView)
      didUpdateAdjustmentKind([])
    }

    @inline(__always)
    private func updateMaximumRect() {

      let insets = containerView.remainingScroll

      let reversedInsets = UIEdgeInsets(
        top: -insets.top,
        left: -insets.left,
        bottom: -insets.bottom,
        right: -insets.right
      )

      let r = self.frame
        .inset(by: reversedInsets)
        .intersection(containerView.bounds.inset(by: insetOfGuideFlexibility))

      maximumRect = r

      leftMaxConstraint?.constant = r.minX
      rightMaxConstraint?.constant = maximumRect!.maxX - superview!.bounds.maxX
      topMaxConstraint?.constant = r.minY
      bottomMaxConstraint?.constant = maximumRect!.maxY - superview!.bounds.maxY

    }

    private var isTracking = false

    private func onGestureTrackingStarted() {

      isTracking = true

      translatesAutoresizingMaskIntoConstraints = false

      updateMaximumRect()
      willChange()
      cropInsideOverlay?.didBeginAdjustment(kind: .guide)
      cropOutsideOverlay?.didBeginAdjustment(kind: .guide)
      didUpdateAdjustmentKind(.guide)
    }

    private func onGestureTrackingChanged() {
      updating()
      updateMaximumRect()
    }

    private func onGestureTrackingEnded() {

      isTracking = false

      deactivateAllConstraints()
      didChange()
      cropInsideOverlay?.didEndAdjustment(kind: .guide)
      cropOutsideOverlay?.didEndAdjustment(kind: .guide)
      didUpdateAdjustmentKind([])
    }

    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    private var leftMaxConstraint: NSLayoutConstraint?
    private var rightMaxConstraint: NSLayoutConstraint?
    private var topMaxConstraint: NSLayoutConstraint?
    private var bottomMaxConstraint: NSLayoutConstraint?

    private var activeConstraints: [NSLayoutConstraint] = []

    private func activateRightConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      activeConstraints.append(
        rightAnchor.constraint(
          equalTo: superview!.rightAnchor,
          constant: frame.maxX - superview!.bounds.maxX
        )&>.do {
          $0.isActive = true
        }
      )
    }

    private func activateLeftMaxConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      leftMaxConstraint = leftAnchor.constraint(
        greaterThanOrEqualTo: superview!.leftAnchor,
        constant: maximumRect!.minX
      )&>.do {
        $0.isActive = true
      }

      activeConstraints.append(
        leftMaxConstraint!
      )
    }

    private func activateRightMaxConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      rightMaxConstraint = rightAnchor.constraint(
        lessThanOrEqualTo: superview!.rightAnchor,
        constant: maximumRect!.maxX - superview!.bounds.maxX
      )&>.do {
        $0.isActive = true
      }

      activeConstraints.append(
        rightMaxConstraint!
      )
    }

    private func activateTopMaxConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      topMaxConstraint = topAnchor.constraint(
        greaterThanOrEqualTo: superview!.topAnchor,
        constant: maximumRect!.minY
      )&>.do {
        $0.isActive = true
      }

      activeConstraints.append(
        topMaxConstraint!
      )
    }

    private func activateBottomMaxConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      bottomMaxConstraint = bottomAnchor.constraint(
        lessThanOrEqualTo: superview!.bottomAnchor,
        constant: maximumRect!.maxY - superview!.bounds.maxY
      )&>.do {
        $0.isActive = true
      }

      activeConstraints.append(
        bottomMaxConstraint!
      )
    }

    private func activateLeftConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      activeConstraints.append(
        leftAnchor.constraint(
          equalTo: superview!.leftAnchor,
          constant: frame.minX - superview!.bounds.minX
        )&>.do {
          $0.isActive = true
        }
      )
    }

    private func activateBottomConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      activeConstraints.append(
        bottomAnchor.constraint(
          equalTo: superview!.bottomAnchor,
          constant: frame.maxY - superview!.bounds.maxY
        )&>.do {
          $0.isActive = true
        }
      )
    }

    private func activateTopConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      activeConstraints.append(
        topAnchor.constraint(
          equalTo: superview!.topAnchor,
          constant: frame.minY - superview!.bounds.minY
        )&>.do {
          $0.isActive = true
        }
      )
    }

    private func activateCenterXConstraint() {
      activeConstraints.append(
        centerXAnchor.constraint(
          equalTo: superview!.centerXAnchor,
          constant: frame.midX - superview!.bounds.midX
        )&>.do {
          $0.priority = .defaultLow
          $0.isActive = true
        }
      )
    }

    private func activateCenterYConstraint() {
      activeConstraints.append(
        centerYAnchor.constraint(
          equalTo: superview!.centerYAnchor,
          constant: frame.midY - superview!.bounds.midY
        )&>.do {
          $0.priority = .defaultLow
          $0.isActive = true
        }
      )
    }

    private func activateWidthConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      widthConstraint = widthAnchor.constraint(equalToConstant: bounds.width)&>.do {
        $0.priority = .defaultLow
        $0.isActive = true
      }

      activeConstraints.append(
        widthAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.width)&>.do {
          $0.isActive = true
        }
      )
    }

    private func activateHeightConstraint() {
      translatesAutoresizingMaskIntoConstraints = false

      heightConstraint = heightAnchor.constraint(equalToConstant: bounds.height)&>.do {
        $0.priority = .defaultLow
        $0.isActive = true
      }

      activeConstraints.append(
        heightAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.height)&>.do {
          $0.isActive = true
        }
      )
    }
    
    
    private func activateAspectRatioConstraint() {
      if let aspectRatio = lockedAspectRatio {
        activeConstraints.append(widthAnchor.constraint(
          equalTo: heightAnchor,
          multiplier: aspectRatio.width / aspectRatio.height,
          constant: 1
        )&>.do {
          $0.isActive = true
        })
      }
    }

    private func deactivateAllConstraints() {
      translatesAutoresizingMaskIntoConstraints = true

      NSLayoutConstraint.deactivate([
        widthConstraint,
        heightConstraint,

      ].compactMap { $0 } + activeConstraints)
      
      layoutIfNeeded()
    }

    @objc
    private func handlePanGestureInTopLeft(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()

          activateTopMaxConstraint()
          activateLeftMaxConstraint()

          activateBottomConstraint()
          activateRightConstraint()
          activateWidthConstraint()
          activateHeightConstraint()
        }

        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)
                
        widthConstraint.constant -= translation.x
        heightConstraint.constant -= translation.y

        onGestureTrackingChanged()

      case .cancelled,
           .ended,
           .failed:

        onGestureTrackingEnded()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInTopRight(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:

        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()

          activateTopMaxConstraint()
          activateRightMaxConstraint()

          activateBottomConstraint()
          activateLeftConstraint()

          activateWidthConstraint()
          activateHeightConstraint()
        }

        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        let translation = gesture.translation(in: self)

        widthConstraint.constant += translation.x
        heightConstraint.constant -= translation.y

        onGestureTrackingChanged()
      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()

      default:
        break
      }
    }

    @objc
    private func handlePanGestureInBottomLeft(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()

          activateBottomMaxConstraint()
          activateLeftMaxConstraint()

          activateTopConstraint()
          activateRightConstraint()

          activateWidthConstraint()
          activateHeightConstraint()
        }

        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)

        widthConstraint.constant -= translation.x
        heightConstraint.constant += translation.y

        onGestureTrackingChanged()
      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInBottomRight(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()

          activateBottomMaxConstraint()
          activateRightMaxConstraint()

          activateTopConstraint()
          activateLeftConstraint()

          activateWidthConstraint()
          activateHeightConstraint()
        }

        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)

        widthConstraint.constant += translation.x
        heightConstraint.constant += translation.y

        onGestureTrackingChanged()

      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInTop(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()

          activateTopMaxConstraint()
          activateCenterXConstraint()
          
          activateRightMaxConstraint()
          activateLeftMaxConstraint()
          
          activateBottomConstraint()

          if lockedAspectRatio == nil {
            activateWidthConstraint()
          }
          activateHeightConstraint()
        }

        fallthrough
      case .changed:

        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)

        heightConstraint.constant -= translation.y

        onGestureTrackingChanged()
      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInRight(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()
          
          activateRightMaxConstraint()
          activateCenterYConstraint()
          
          activateTopMaxConstraint()
          activateBottomMaxConstraint()
          
          activateLeftConstraint()
          
          activateWidthConstraint()
          if lockedAspectRatio == nil {
            activateHeightConstraint()
          }
        }

        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)

        widthConstraint.constant += translation.x

        onGestureTrackingChanged()
      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInLeft(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()
          
          activateLeftMaxConstraint()
          activateCenterYConstraint()
          
          activateTopMaxConstraint()
          activateBottomMaxConstraint()
          
          activateRightConstraint()
          
          activateWidthConstraint()
          if lockedAspectRatio == nil {
            activateHeightConstraint()
          }
        }

        fallthrough
      case .changed:

        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)

        widthConstraint.constant -= translation.x

        onGestureTrackingChanged()
      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()
      default:
        break
      }
    }

    @objc
    private func handlePanGestureInBottom(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()

        activateConstraints: do {
          activateAspectRatioConstraint()
          
          activateBottomMaxConstraint()
          activateCenterXConstraint()
          
          activateRightMaxConstraint()
          activateLeftMaxConstraint()
          
          activateTopConstraint()
          
          if lockedAspectRatio == nil {
            activateWidthConstraint()
          }
          activateHeightConstraint()
        }

        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)

        heightConstraint.constant += translation.y

        onGestureTrackingChanged()
      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()
      default:
        break
      }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      return isTracking == false
    }

  }

}

private final class MaskView: PixelEditorCodeBasedView {
  private let topView = UIView()
  private let rightView = UIView()
  private let leftView = UIView()
  private let bottomView = UIView()

  init() {
    super.init(frame: .zero)

    backgroundColor = .clear
    [
      topView,
      rightView,
      leftView,
      bottomView,
    ].forEach {
      addSubview($0)
      $0.backgroundColor = .white
    }
  }

  func setUnmaskRect(_ rect: CGRect) {
    topView.frame = .init(origin: .zero, size: .init(width: bounds.width, height: rect.minY))
    rightView.frame = .init(
      origin: .init(x: rect.maxX, y: rect.minY),
      size: .init(width: bounds.width - rect.maxX, height: rect.height)
    )
    leftView.frame = .init(
      origin: .init(x: 0, y: rect.minY),
      size: .init(width: rect.minX, height: rect.height)
    )
    bottomView.frame = .init(
      origin: .init(x: 0, y: rect.maxY),
      size: .init(width: bounds.width, height: bounds.height - rect.maxY)
    )
  }
}

/*
extension UIPanGestureRecognizer {
  
  func pointTranslation(in view: UIView?) -> CGPoint {
    
    let translation = self.translation(in: view)

    var point = CGPoint()
    
    if abs(translation.x) >= 1 {
      point.x = translation.x
      self.setTranslation(.init(x: 0, y: translation.y), in: view)
    }
    
    if abs(translation.y) >= 1 {
      point.y = translation.y
      self.setTranslation(.init(x: translation.x, y: 0), in: view)
    }
            
    return point
    
  }
  
}
*/
