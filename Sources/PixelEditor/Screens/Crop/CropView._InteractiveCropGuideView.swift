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

import Foundation
import PixelEngine

extension CropView {
  public final class _InteractiveCropGuideView: UIView, UIGestureRecognizerDelegate {
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

    private weak var cropInsideOverlay: CropInsideOverlayBase?
    private weak var cropOutsideOverlay: CropOutsideOverlayBase?

    private unowned let containerView: CropView
    private unowned let imageView: UIView

    private lazy var invertedMaskShapeLayerView = MaskView()

    private var maximumRect: CGRect?

    private var lockedAspectRatio: PixelAspectRatio?

    init(containerView: CropView, imageView: UIView) {
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

    /**
     Displays a view as an overlay.
     e.g. grid view
     */
    public func setCropInsideOverlay(_ newOverlay: CropInsideOverlayBase?) {
      cropInsideOverlay?.removeFromSuperview()

      if let overlay = newOverlay {
        overlay.isUserInteractionEnabled = false
        addSubview(overlay)
        cropInsideOverlay = overlay
      }
    }

    func setCropOutsideOverlay(_ view: CropOutsideOverlayBase) {
      assert(view.superview != nil)
      assert(view.superview is CropView)

      cropOutsideOverlay = view

      setNeedsLayout()
      layoutIfNeeded()
    }

    func setLockedAspectRatio(_ aspectRatio: PixelAspectRatio) {
      lockedAspectRatio = aspectRatio
    }

    override public func layoutSubviews() {
      super.layoutSubviews()

      cropInsideOverlay?.frame = bounds

      if let outOfBoundsOverlayView = cropOutsideOverlay {
        let frame = convert(bounds, to: outOfBoundsOverlayView)

        invertedMaskShapeLayerView.frame = outOfBoundsOverlayView.bounds
        invertedMaskShapeLayerView.setUnmaskRect(frame)

        if outOfBoundsOverlayView.mask == nil {
          outOfBoundsOverlayView.mask = invertedMaskShapeLayerView
        }
      }
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
      minimumSize: do {
        if proposedFrame.width < 100 {
          proposedFrame.origin.x = currentFrame.origin.x
          proposedFrame.size.width = currentFrame.size.width
        }

        if proposedFrame.height < 100 {
          proposedFrame.origin.y = currentFrame.origin.y
          proposedFrame.size.height = currentFrame.size.height
        }
      }

      maximumSize: do {
        assert(self.maximumRect != nil)
        let maximumRect = self.maximumRect!
        proposedFrame = proposedFrame.intersection(maximumRect)
      }
    }

    func willBeginScrollViewAdjustment() {
      onGestureTrackingStarted()
    }

    func didEndScrollViewAdjustment() {
      onGestureTrackingEnded()
    }

    @inline(__always)
    private func updateMaximumRect() {
      maximumRect = imageView.convert(imageView.bounds, to: containerView)
        .intersection(containerView.bounds.insetBy(dx: 20, dy: 20))
    }

    private func onGestureTrackingStarted() {
      updateMaximumRect()
      willChange()
      cropInsideOverlay?.didBeginAdjustment()
      cropOutsideOverlay?.didBeginAdjustment()
    }

    private func onGestureTrackingEnded() {
      didChange()
      cropInsideOverlay?.didEndAdjustment()
      cropOutsideOverlay?.didEndAdjustment()
    }

    @objc
    private func handlePanGestureInTopLeft(gesture: UIPanGestureRecognizer) {
      assert(containerView == superview)

      switch gesture.state {
      case .began:
        onGestureTrackingStarted()
        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        var translation = gesture.translation(in: self)
        if let lockedAspectRatio = lockedAspectRatio {
          let current = translation
          if abs(current.x) > abs(current.y) {
            translation.y = lockedAspectRatio.height(forWidth: current.x)
          } else {
            translation.x = lockedAspectRatio.width(forHeight: current.y)
          }
        }

        let currentFrame = frame

        var nextFrame = currentFrame.resizing(
          to: .init(
            width: currentFrame.width - translation.x,
            height: currentFrame.height - translation.y
          ),
          anchor: .init(x: 1, y: 1)
        )
        

        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.minX, y: nextFrame.minY)) == false {
          nextFrame = currentFrame
        }

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame

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
        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        var translation = gesture.translation(in: self)
        if let lockedAspectRatio = lockedAspectRatio {
          let current = translation
          if abs(current.x) > abs(current.y) {
            translation.y = lockedAspectRatio.height(forWidth: -current.x)
          } else {
            translation.x = lockedAspectRatio.width(forHeight: -current.y)
          }
        }

        let currentFrame = frame

        var nextFrame = currentFrame.resizing(
          to: .init(
            width: currentFrame.width + translation.x,
            height: currentFrame.height - translation.y
          ),
          anchor: .init(x: 0, y: 1)
        )

        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.maxX, y: nextFrame.minY)) == false {
          nextFrame = currentFrame
        }

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame

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
        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        var translation = gesture.translation(in: self)
        if let lockedAspectRatio = lockedAspectRatio {
          let current = translation
          if abs(current.x) > abs(current.y) {
            translation.y = lockedAspectRatio.height(forWidth: -current.x)
          } else {
            translation.x = lockedAspectRatio.width(forHeight: -current.y)
          }
        }

        let currentFrame = frame

        var nextFrame = currentFrame.resizing(
          to: .init(
            width: currentFrame.width - translation.x,
            height: currentFrame.height + translation.y
          ),
          anchor: .init(x: 1, y: 0)
        )

        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.minX, y: nextFrame.maxY)) == false {
          nextFrame = currentFrame
        }

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame
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
        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }
        var translation = gesture.translation(in: self)
        if let lockedAspectRatio = lockedAspectRatio {
          let current = translation
          if abs(current.x) > abs(current.y) {
            translation.y = lockedAspectRatio.height(forWidth: current.x)
          } else {
            translation.x = lockedAspectRatio.width(forHeight: current.y)
          }
        }

        let currentFrame = frame
        var nextFrame = currentFrame.resizing(
          to: .init(
            width: currentFrame.width + translation.x,
            height: currentFrame.height + translation.y
          ),
          anchor: .init(x: 0, y: 0)
        )

        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.maxX, y: nextFrame.maxY)) == false {
          nextFrame = currentFrame
        }

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame
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
        fallthrough
      case .changed:

        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)

        let currentFrame = frame

        let width: CGFloat
        let height = currentFrame.height - translation.y

        if let locked = lockedAspectRatio {
          width = locked.width(forHeight: height)
        } else {
          width = currentFrame.width
        }

        var nextFrame = currentFrame.resizing(
          to: .init(
            width: width,
            height: height
          ),
          anchor: .init(x: 0.5, y: 1)
        )

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.minX, y: nextFrame.minY)) == false {
          nextFrame = currentFrame
        }
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.maxX, y: nextFrame.minY)) == false {
          nextFrame = currentFrame
        }

        frame = nextFrame

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
        fallthrough
      case .changed:
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)
        let currentFrame = frame

        let width = currentFrame.width + translation.x
        let height: CGFloat

        if let locked = lockedAspectRatio {
          height = locked.height(forWidth: width)
        } else {
          height = currentFrame.height
        }

        var nextFrame = currentFrame.resizing(
          to: .init(
            width: width,
            height: height
          ),
          anchor: .init(x: 0, y: 0.5)
        )
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.maxX, y: nextFrame.minY)) == false {
          nextFrame = currentFrame
        }
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.maxX, y: nextFrame.maxY)) == false {
          nextFrame = currentFrame
        }

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame

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
        fallthrough
      case .changed:

        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let translation = gesture.translation(in: self)
        let currentFrame = frame

        let width = currentFrame.width - translation.x
        let height: CGFloat

        if let locked = lockedAspectRatio {
          height = locked.height(forWidth: width)
        } else {
          height = currentFrame.height
        }

        var nextFrame = currentFrame.resizing(
          to: .init(
            width: width,
            height: height
          ),
          anchor: .init(x: 1, y: 0.5)
        )
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.minX, y: nextFrame.minY)) == false {
          nextFrame = currentFrame
        }
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.minX, y: nextFrame.maxY)) == false {
          nextFrame = currentFrame
        }

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame

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
        fallthrough
      case .changed:
        let translation = gesture.translation(in: self)
        defer {
          gesture.setTranslation(.zero, in: self)
        }

        let currentFrame = frame

        let width: CGFloat
        let height = currentFrame.height + translation.y

        if let locked = lockedAspectRatio {
          width = locked.width(forHeight: height)
        } else {
          width = currentFrame.width
        }

        var nextFrame = currentFrame.resizing(
          to: .init(
            width: width,
            height: height
          ),
          anchor: .init(x: 0.5, y: 0)
        )
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.minX, y: nextFrame.maxY)) == false {
          nextFrame = currentFrame
        }
        
        // Keeping aspect ratio
        if maximumRect!.contains(.init(x: nextFrame.maxX, y: nextFrame.maxY)) == false {
          nextFrame = currentFrame
        }

        postprocess(
          proposedFrame: &nextFrame,
          currentFrame: currentFrame
        )

        frame = nextFrame

      case .cancelled,
           .ended,
           .failed:
        onGestureTrackingEnded()
      default:
        break
      }
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

extension CGRect {
  fileprivate func resizing(to size: CGSize, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> CGRect {
    let sizeDelta = CGSize(width: size.width - width, height: size.height - height)
    return CGRect(
      origin: CGPoint(
        x: minX - sizeDelta.width * anchor.x,
        y: minY - sizeDelta.height * anchor.y
      ),
      size: size
    )
  }
}
