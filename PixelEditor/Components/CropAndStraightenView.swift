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
      return imageView.image
    }
    set {
      if let image = newValue {
        assert(image.scale == UIScreen.main.scale)
      }
      imageView.image = newValue
    }
  }

  // return pixel
  var visibleExtent: CGRect {
    get {
      guard let image = image else {
        return .zero
      }

      var _visibleRect = imageView.convert(imageView.bounds, to: imageView.subviews.first!)

      let scale = _ratio(
        to: image.size,
        from: imageView.internalImageView.bounds.size
      )
      * image.scale

      _visibleRect.origin.x *= scale
      _visibleRect.origin.y *= scale
      _visibleRect.size.width *= scale
      _visibleRect.size.height *= scale

      return _visibleRect
    }
    set {

      guard let image = image else { return }

      imageView.zoomScale = 0
      let _scale = _ratio(to: imageView.contentSize, from: image.size)

      var _visibleRect = newValue
      _visibleRect.origin.x *= _scale
      _visibleRect.origin.y *= _scale
      _visibleRect.size.width *= _scale
      _visibleRect.size.height *= _scale

      imageView.zoom(to: _visibleRect, animated: false)
    }
  }

  private let imageView: ZoomImageView = {

    let view = ZoomImageView()
    view.zoomMode = .fill
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
  return to.height / from.height
}
