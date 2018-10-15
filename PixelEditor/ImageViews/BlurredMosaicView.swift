//
//  BlurredMosaicView.swift
//  PixelEditor
//
//  Created by muukii on 10/12/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import PixelEngine

final class BlurredMosaicView : DryDrawingView {

  private var displayingImageExtent: CGRect?

  var image: CIImage? {
    get {
      return imageView.image?.ciImage
    }
    set {

      displayingImageExtent = newValue?.extent

      let blurredImage = newValue
        .flatMap { $0.transformed(by: .init(translationX: -$0.extent.origin.x, y: -$0.extent.origin.y)) }
        .flatMap { BlurredMask.blur(image: $0) }
        .flatMap { UIImage(ciImage: $0, scale: UIScreen.main.scale, orientation: .up) }

      imageView.image = blurredImage
    }
  }

  private let imageView = UIImageView()

  private let brush: OvalBrush = OvalBrush(color: UIColor.black, width: 30)

  private let maskLayer = MaskLayer()

  var drawnPaths: [DrawnPathInRect] = [] {
    didSet {
      updateMask()
    }
  }

  // MARK: - Initializers

  override init() {

    super.init()

    backgroundColor = .clear

    addSubview(imageView)

    imageView.contentMode = .scaleAspectFill
    imageView.layer.mask = maskLayer

    maskLayer.contentsScale = UIScreen.main.scale
    maskLayer.drawsAsynchronously = true
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func willBeginPan(path: UIBezierPath) {

//    guard let extent = displayingImageExtent else { return }

    // TODO: Don't use bounds
    let drawnPath = DrawnPathInRect(path: DrawnPath(brush: brush, path: path), in: bounds)
    drawnPaths.append(drawnPath)
  }

  override func panning(path: UIBezierPath) {
    updateMask()
  }

  override func didFinishPan(path: UIBezierPath) {
    updateMask()
  }

  override func layoutSublayers(of layer: CALayer) {
    super.layoutSublayers(of: layer)

    maskLayer.frame = bounds
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
  }

  private func updateMask() {

    maskLayer.drawnPaths = drawnPaths
  }
}

extension BlurredMosaicView {
  private class MaskLayer : CALayer {

    var drawnPaths: [GraphicsDrawing] = [] {
      didSet {
        setNeedsDisplay()
      }
    }

    override func draw(in ctx: CGContext) {
      drawnPaths.forEach { $0.draw(in: ctx, canvasSize: bounds.size) }
    }
  }
}
