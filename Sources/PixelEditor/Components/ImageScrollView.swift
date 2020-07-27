//
//  ImageScrollView.swift
//  Beauty
//
//  Created by Nguyen Cong Huy on 1/19/16.
//  Copyright © 2016 Nguyen Cong Huy. All rights reserved.
//

import UIKit

final class ImageScrollView: UIScrollView {

  @objc enum ScaleMode: Int {
    case aspectFill
    case aspectFit
    case widthFill
    case heightFill
  }

  @objc enum Offset: Int {
    case beginning
    case center
  }

  static let kZoomInFactorFromMinWhenDoubleTap: CGFloat = 2

  @objc var imageContentMode: ScaleMode = .widthFill
  @objc var initialOffset: Offset = .beginning

  @objc private(set) var zoomView: UIImageView? = nil

  var imageSize: CGSize = CGSize.zero
  private var pointToCenterAfterResize: CGPoint = CGPoint.zero
  private var scaleToRestoreAfterResize: CGFloat = 1.0
  var maxScaleFromMinScale: CGFloat = 3.0

  override var frame: CGRect {
    willSet {
      if frame.equalTo(newValue) == false && newValue.equalTo(CGRect.zero) == false && imageSize.equalTo(CGSize.zero) == false {
        prepareToResize()
      }
    }

    didSet {
      if frame.equalTo(oldValue) == false && frame.equalTo(CGRect.zero) == false && imageSize.equalTo(CGSize.zero) == false {
        recoverFromResizing()
      }
    }
  }

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

//    NotificationCenter.default.addObserver(self, selector: #selector(ImageScrollView.changeOrientationNotification), name: UIDevice.orientationDidChangeNotification, object: nil)
  }

  @objc func adjustFrameToCenter() {

    guard let unwrappedZoomView = zoomView else {
      return
    }

    var frameToCenter = unwrappedZoomView.frame

    // center horizontally
    if frameToCenter.size.width < bounds.width {
      frameToCenter.origin.x = (bounds.width - frameToCenter.size.width) / 2
    }
    else {
      frameToCenter.origin.x = 0
    }

    // center vertically
    if frameToCenter.size.height < bounds.height {
      frameToCenter.origin.y = (bounds.height - frameToCenter.size.height) / 2
    }
    else {
      frameToCenter.origin.y = 0
    }

    unwrappedZoomView.frame = frameToCenter
  }

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

  private func recoverFromResizing() {
    setMaxMinZoomScalesForCurrentBounds()

    // restore zoom scale, first making sure it is within the allowable range.
    let maxZoomScale = max(minimumZoomScale, scaleToRestoreAfterResize)
    zoomScale = min(maximumZoomScale, maxZoomScale)

    // restore center point, first making sure it is within the allowable range.

    // convert our desired center point back to our own coordinate space
    let boundsCenter = convert(pointToCenterAfterResize, to: zoomView)

    // calculate the content offset that would yield that center point
    var offset = CGPoint(x: boundsCenter.x - bounds.size.width/2.0, y: boundsCenter.y - bounds.size.height/2.0)

    // restore offset, adjusted to be within the allowable range
    let maxOffset = maximumContentOffset()
    let minOffset = minimumContentOffset()

    var realMaxOffset = min(maxOffset.x, offset.x)
    offset.x = max(minOffset.x, realMaxOffset)

    realMaxOffset = min(maxOffset.y, offset.y)
    offset.y = max(minOffset.y, realMaxOffset)

    contentOffset = offset
  }

  private func maximumContentOffset() -> CGPoint {
    return CGPoint(x: contentSize.width - bounds.width,y:contentSize.height - bounds.height)
  }

  private func minimumContentOffset() -> CGPoint {
    return CGPoint.zero
  }

  // MARK: - Display image

  @objc func display(image: UIImage) {

    if let zoomView = zoomView {
      zoomView.removeFromSuperview()
    }

    zoomView = UIImageView(image: image)
    zoomView!.isUserInteractionEnabled = true
    addSubview(zoomView!)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ImageScrollView.doubleTapGestureRecognizer(_:)))
    tapGesture.numberOfTapsRequired = 2
    zoomView!.addGestureRecognizer(tapGesture)

    configureImageForSize(image.size)
  }

  private func configureImageForSize(_ size: CGSize) {
    imageSize = size
    contentSize = imageSize
    setMaxMinZoomScalesForCurrentBounds()
    zoomScale = minimumZoomScale

    switch initialOffset {
    case .beginning:
      contentOffset =  CGPoint.zero
    case .center:
      let xOffset = contentSize.width < bounds.width ? 0 : (contentSize.width - bounds.width)/2
      let yOffset = contentSize.height < bounds.height ? 0 : (contentSize.height - bounds.height)/2

      switch imageContentMode {
      case .aspectFit:
        contentOffset =  CGPoint.zero
      case .aspectFill:
        contentOffset = CGPoint(x: xOffset, y: yOffset)
      case .heightFill:
        contentOffset = CGPoint(x: xOffset, y: 0)
      case .widthFill:
        contentOffset = CGPoint(x: 0, y: yOffset)
      }
    }
  }

  private func setMaxMinZoomScalesForCurrentBounds() {
    // calculate min/max zoomscale
    let xScale = bounds.width / imageSize.width    // the scale needed to perfectly fit the image width-wise
    let yScale = bounds.height / imageSize.height   // the scale needed to perfectly fit the image height-wise

    var minScale: CGFloat = 1

    switch imageContentMode {
    case .aspectFill:
      minScale = max(xScale, yScale)
    case .aspectFit:
      minScale = min(xScale, yScale)
    case .widthFill:
      minScale = xScale
    case .heightFill:
      minScale = yScale
    }


    let maxScale = maxScaleFromMinScale*minScale

    // don't let minScale exceed maxScale. (If the image is smaller than the screen, we don't want to force it to be zoomed.)
    if minScale > maxScale {
      minScale = maxScale
    }

    maximumZoomScale = maxScale
    minimumZoomScale = minScale * 0.999 // the multiply factor to prevent user cannot scroll page while they use this control in UIPageViewController
  }

  // MARK: - Gesture

  @objc func doubleTapGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
    // zoom out if it bigger than middle scale point. Else, zoom in
    if zoomScale >= maximumZoomScale / 2.0 {
      setZoomScale(minimumZoomScale, animated: true)
    }
    else {
      let center = gestureRecognizer.location(in: gestureRecognizer.view)
      let zoomRect = zoomRectForScale(ImageScrollView.kZoomInFactorFromMinWhenDoubleTap * minimumZoomScale, center: center)
      zoom(to: zoomRect, animated: true)
    }
  }

  private func zoomRectForScale(_ scale: CGFloat, center: CGPoint) -> CGRect {
    var zoomRect = CGRect.zero

    // the zoom rect is in the content view's coordinates.
    // at a zoom scale of 1.0, it would be the size of the imageScrollView's bounds.
    // as the zoom scale decreases, so more content is visible, the size of the rect grows.
    zoomRect.size.height = frame.size.height / scale
    zoomRect.size.width  = frame.size.width  / scale

    // choose an origin so as to get the right center.
    zoomRect.origin.x    = center.x - (zoomRect.size.width  / 2.0)
    zoomRect.origin.y    = center.y - (zoomRect.size.height / 2.0)

    return zoomRect
  }

  func refresh() {
    if let image = zoomView?.image {
      display(image: image)
    }
  }

  // MARK: - Actions

//  @objc func changeOrientationNotification() {
//    configureImageForSize(imageSize)
//  }
}

extension ImageScrollView: UIScrollViewDelegate {

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return zoomView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    adjustFrameToCenter()
  }

}
