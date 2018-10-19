// ZoomImageView.swift
//
// Copyright (c) 2016 muukii
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

open class ZoomImageView : UIScrollView, UIScrollViewDelegate {

  public enum ZoomMode {
    case fit
    case fill
  }

  // MARK: - Properties

  public let internalImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.layer.allowsEdgeAntialiasing = true
    return imageView
  }()

  public var zoomMode: ZoomMode = .fit {
    didSet {
      updateImageView()
      scrollToCenter()
    }
  }

  open var image: UIImage? {
    get {
      return internalImageView.image
    }
    set {
      let oldImage = internalImageView.image
      internalImageView.image = newValue

      if oldImage?.size != newValue?.size {
        oldSize = nil
        updateImageView()
      }
      scrollToCenter()
    }
  }

  open override var intrinsicContentSize: CGSize {
    return internalImageView.intrinsicContentSize
  }

  private var oldSize: CGSize?

  // MARK: - Initializers

  public override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  public init(image: UIImage) {
    super.init(frame: CGRect.zero)
    self.image = image
    setup()
  }

  public required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    setup()
  }

  // MARK: - Functions

  open func scrollToCenter() {

    let centerOffset = CGPoint(
      x: contentSize.width > bounds.width ? (contentSize.width / 2) - (bounds.width / 2) : 0,
      y: contentSize.height > bounds.height ? (contentSize.height / 2) - (bounds.height / 2) : 0
    )

    contentOffset = centerOffset
  }

  open func setup() {

    #if swift(>=3.2)
    if #available(iOS 11, *) {
      contentInsetAdjustmentBehavior = .never
    }
    #endif

    backgroundColor = UIColor.clear
    delegate = self
    internalImageView.contentMode = .scaleAspectFill
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    addSubview(internalImageView)

    let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTapGesture.numberOfTapsRequired = 2
    addGestureRecognizer(doubleTapGesture)
  }

  open override func didMoveToSuperview() {
    super.didMoveToSuperview()
  }

  open override func layoutSubviews() {

    super.layoutSubviews()

    if internalImageView.image != nil && oldSize != bounds.size {

      updateImageView()
      oldSize = bounds.size
    }

    if internalImageView.frame.width <= bounds.width {
      internalImageView.center.x = bounds.width * 0.5
    }

    if internalImageView.frame.height <= bounds.height {
      internalImageView.center.y = bounds.height * 0.5
    }
  }

  open override func updateConstraints() {
    super.updateConstraints()
    updateImageView()
  }

  private func updateImageView() {

    func fitSize(aspectRatio: CGSize, boundingSize: CGSize) -> CGSize {

      let widthRatio = (boundingSize.width / aspectRatio.width)
      let heightRatio = (boundingSize.height / aspectRatio.height)

      var boundingSize = boundingSize

      if widthRatio < heightRatio {
        boundingSize.height = boundingSize.width / aspectRatio.width * aspectRatio.height
      }
      else if (heightRatio < widthRatio) {
        boundingSize.width = boundingSize.height / aspectRatio.height * aspectRatio.width
      }
      return CGSize(width: ceil(boundingSize.width), height: ceil(boundingSize.height))
    }

    func fillSize(aspectRatio: CGSize, minimumSize: CGSize) -> CGSize {
      let widthRatio = (minimumSize.width / aspectRatio.width)
      let heightRatio = (minimumSize.height / aspectRatio.height)

      var minimumSize = minimumSize

      if widthRatio > heightRatio {
        minimumSize.height = minimumSize.width / aspectRatio.width * aspectRatio.height
      }
      else if (heightRatio > widthRatio) {
        minimumSize.width = minimumSize.height / aspectRatio.height * aspectRatio.width
      }
      return CGSize(width: ceil(minimumSize.width), height: ceil(minimumSize.height))
    }

    guard let image = internalImageView.image else { return }

    var size: CGSize

    switch zoomMode {
    case .fit:
      size = fitSize(aspectRatio: image.size, boundingSize: bounds.size)
    case .fill:
      size = fillSize(aspectRatio: image.size, minimumSize: bounds.size)
    }

    size.height = round(size.height)
    size.width = round(size.width)

    zoomScale = 1

    maximumZoomScale = max(image.size.width / size.width, 1)
    internalImageView.bounds.size = size
    contentSize = size
    internalImageView.center = ZoomImageView.contentCenter(forBoundingSize: bounds.size, contentSize: contentSize)
  }

  @objc private func handleDoubleTap(_ gestureRecognizer: UITapGestureRecognizer) {
    if self.zoomScale == 1 {
      zoom(
        to: zoomRectFor(
          scale: max(1, maximumZoomScale / 3),
          with: gestureRecognizer.location(in: gestureRecognizer.view)),
        animated: true
      )
    } else {
      setZoomScale(1, animated: true)
    }
  }

  // This function is borrowed from: https://stackoverflow.com/questions/3967971/how-to-zoom-in-out-photo-on-double-tap-in-the-iphone-wwdc-2010-104-photoscroll
  private func zoomRectFor(scale: CGFloat, with center: CGPoint) -> CGRect {
    let center = internalImageView.convert(center, from: self)

    var zoomRect = CGRect()
    zoomRect.size.height = bounds.height / scale
    zoomRect.size.width = bounds.width / scale
    zoomRect.origin.x = center.x - zoomRect.width / 2.0
    zoomRect.origin.y = center.y - zoomRect.height / 2.0

    return zoomRect
  }

  // MARK: - UIScrollViewDelegate
  @objc dynamic public func scrollViewDidZoom(_ scrollView: UIScrollView) {
    internalImageView.center = ZoomImageView.contentCenter(forBoundingSize: bounds.size, contentSize: contentSize)
  }

  @objc dynamic public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {

  }

  @objc dynamic public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {

  }

  @objc dynamic public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    return internalImageView
  }

  @inline(__always)
  private static func contentCenter(forBoundingSize boundingSize: CGSize, contentSize: CGSize) -> CGPoint {

    /// When the zoom scale changes i.e. the image is zoomed in or out, the hypothetical center
    /// of content view changes too. But the default Apple implementation is keeping the last center
    /// value which doesn't make much sense. If the image ratio is not matching the screen
    /// ratio, there will be some empty space horizontaly or verticaly. This needs to be calculated
    /// so that we can get the correct new center value. When these are added, edges of contentView
    /// are aligned in realtime and always aligned with corners of scrollview.
    let horizontalOffest = (boundingSize.width > contentSize.width) ? ((boundingSize.width - contentSize.width) * 0.5): 0.0
    let verticalOffset = (boundingSize.height > contentSize.height) ? ((boundingSize.height - contentSize.height) * 0.5): 0.0

    return CGPoint(x: contentSize.width * 0.5 + horizontalOffest,  y: contentSize.height * 0.5 + verticalOffset)
  }
}

