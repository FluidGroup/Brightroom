//
//  CropAndStraightenView.swift
//  ImageEditor
//
//  Created by muukii on 2016/12/06.
//  Copyright © 2016 muukii. All rights reserved.
//

import UIKit

final class CropAndStraightenView : UIView {

  // MARK: - Properties

  var image: UIImage? {
    get {
      return imageView.zoomView?.image
    }
    set {
      if let image = newValue {
        assert(image.scale == UIScreen.main.scale)
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
        to: CGSize(
          width: image.size.width * image.scale,
          height: image.size.height * image.scale
        ),
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
        from: CGSize(
          width: image.size.width * image.scale,
          height: image.size.height * image.scale
        )
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
