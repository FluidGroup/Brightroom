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

  var blurredImage: UIImage? {
    get {
      return imageView.image
    }
    set {
      imageView.image = newValue
    }
  }

  let imageView = UIImageView()

  let brush: OvalBrush = OvalBrush(color: UIColor.black, width: 30)

  private let maskLayer = MaskLayer()

  private var drawnPaths: [DrawnPath] = []

  // MARK: - Initializers

  override init() {

    super.init()

    backgroundColor = .clear

    addSubview(imageView)

    imageView.layer.mask = maskLayer

    maskLayer.contentsScale = UIScreen.main.scale
    maskLayer.drawsAsynchronously = true
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func willBeginPan(path: UIBezierPath) {
    let drawnPath = DrawnPath(brush: brush, path: path)
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

  func set(drawnPaths: [DrawnPath]) {
    self.drawnPaths = drawnPaths
    updateMask()
  }

  private func updateMask() {

    maskLayer.drawnPaths = drawnPaths
  }
}

extension BlurredMosaicView {
  private class MaskLayer : CALayer {

    var drawnPaths: [DrawnPath] = [] {
      didSet {
        setNeedsDisplay()
      }
    }

    override func draw(in ctx: CGContext) {
      UIGraphicsPushContext(ctx)

      drawnPaths.forEach { $0.draw() }

      UIGraphicsPopContext()
    }
  }
}
