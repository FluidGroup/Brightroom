//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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

final class CropAndStraightenView : UIView {

  // MARK: - Properties

  var image: CIImage? {
    didSet {
                  
      let _image: UIImage?
      
      if let cgImage = image?.cgImage {
        _image = UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
      } else {
        // Displaying will be slow in iOS13
        _image = image
          .flatMap { $0.transformed(by: .init(translationX: -$0.extent.origin.x, y: -$0.extent.origin.y)) }
          .flatMap { UIImage(ciImage: $0, scale: UIScreen.main.scale, orientation: .up) }
      }

      if let image = _image {
        imageView.display(image: image)
      } else {
        imageView.zoomView?.removeFromSuperview()
      }
    }
  }

  // return pixel
  var visibleExtent: CGRect {
    get {
      guard let image = image else {
        return .zero
      }

      var visibleRect = imageView.convert(imageView.bounds, to: imageView.subviews.first!)

      let scale = _ratio(
        to: image.extent.size,
        from: imageView.zoomView!.bounds.size
      )

      visibleRect.origin.x *= scale
      visibleRect.origin.y *= scale
      visibleRect.size.width *= scale
      visibleRect.size.height *= scale

      visibleRect.origin.x.round(.up)
      visibleRect.origin.y.round(.up)
      visibleRect.size.width.round(.up)
      visibleRect.size.height.round(.up)

      return visibleRect
    }
    set {

      guard let image = image else { return }

      imageView.zoomScale = 0

      let scale = _ratio(
        to: imageView.zoomView!.bounds.size,
        from: image.extent.size
      )

      var _visibleRect = newValue
      _visibleRect.origin.x *= scale
      _visibleRect.origin.y *= scale
      _visibleRect.size.width *= scale
      _visibleRect.size.height *= scale

      imageView.zoom(to: _visibleRect, animated: false)
    }
  }

  private let imageView: ImageScrollView = {

    let view = ImageScrollView()
    view.imageContentMode = .aspectFill
    view.initialOffset = .center
    return view
  }()

  private var gridLayers: [CALayer] = []

  private let gridContainerLayer = CALayer()

  // MARK: - Initializers

  init() {
    super.init(frame: .zero)

    addSubview(imageView)

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.topAnchor.constraint(equalTo: topAnchor).isActive = true
    imageView.rightAnchor.constraint(equalTo: rightAnchor).isActive = true
    imageView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    imageView.leftAnchor.constraint(equalTo: leftAnchor).isActive = true

    layer.addSublayer(gridContainerLayer)
  }
  
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Functions

  override func layoutSublayers(of layer: CALayer) {
    super.layoutSublayers(of: layer)

    gridContainerLayer.frame = imageView.layer.frame

    gridLayers.forEach { $0.removeFromSuperlayer() }
    gridLayers = []

    let numberOfGrid = 3

    do {

      let width = gridContainerLayer.bounds.width / CGFloat(numberOfGrid)
      for i in 1..<numberOfGrid {
        let x = floor(CGFloat(i) * width)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: gridContainerLayer.bounds.height))
        let lineLayer = CAShapeLayer()
        lineLayer.path = path.cgPath
        lineLayer.strokeColor = UIColor(white: 1, alpha: 0.6).cgColor
        lineLayer.fillColor = UIColor.clear.cgColor
        gridContainerLayer.addSublayer(lineLayer)
        gridLayers.append(lineLayer)
      }

      let height = gridContainerLayer.bounds.height / CGFloat(numberOfGrid)
      for i in 1..<numberOfGrid {
        let y = floor(CGFloat(i) * height)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: gridContainerLayer.bounds.width, y: y))
        let lineLayer = CAShapeLayer()
        lineLayer.path = path.cgPath
        lineLayer.strokeColor = UIColor(white: 1, alpha: 0.6).cgColor
        lineLayer.fillColor = UIColor.clear.cgColor
        gridContainerLayer.addSublayer(lineLayer)
        gridLayers.append(lineLayer)
      }
    }
  }
}


private func _ratio(to: CGSize, from: CGSize) -> CGFloat {

//  assert(to.width / from.width == to.height / from.height)
  return min(to.height / from.height, to.width / from.width)
}
