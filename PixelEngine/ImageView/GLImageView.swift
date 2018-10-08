//
//  GLImageView.swift
//  PixelEngine
//
//  Created by muukii on 10/8/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import GLKit
import AVFoundation

public class GLImageView : GLKView {

  // MARK: - Properties

  let coreImageContext: CIContext

  public var image: CIImage? {
    didSet {
      self.update()
    }
  }

  private var destRect: CGRect {

    let scale = contentScaleFactor
    let destRect = bounds.applying(CGAffineTransform(scaleX: scale, y: scale))

    return CGRect(
      x: round(destRect.origin.x),
      y: round(destRect.origin.y),
      width: round(destRect.width),
      height: round(destRect.height)
    )
  }

  // MARK: - Initializers

  public override convenience init(frame: CGRect) {
    let eaglContext = EAGLContext(api: EAGLRenderingAPI.openGLES2)
    self.init(frame: frame, context: eaglContext!)
  }

  public override init(frame: CGRect, context eaglContext: EAGLContext) {
    coreImageContext = CIContext(eaglContext: eaglContext, options: [:])

    super.init(frame: frame, context: eaglContext)
    backgroundColor = UIColor.clear
    drawableDepthFormat = .format24
    layer.contentsScale = UIScreen.main.scale
  }

  public required init(coder aDecoder: NSCoder) {
    fatalError("")
  }

  // MARK: - Functions

  public override func layoutSubviews() {
    super.layoutSubviews()
    setNeedsDisplay()
  }

  func update() {

    self.setNeedsDisplay()
  }

  public override func draw(_ rect: CGRect) {

    super.draw(rect)

    glClearColor(0, 0, 0, 0)
    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

    guard let image = image, self.window != nil else {
      return
    }

    coreImageContext.draw(image, in: destRect, from: image.extent)
  }
}
