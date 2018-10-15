//
//  DrawnPath.swift
//  PixelEngine
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public struct DrawnPath : GraphicsDrawing, Equatable {

  // MARK: - Properties

  public let brush: OvalBrush
  public let bezierPath: UIBezierPath

  // MARK: - Initializers

  public init(
    brush: OvalBrush,
    path: UIBezierPath
    ) {
    self.brush = brush
    self.bezierPath = path
  }

  // MARK: - Functions

  func brushedPath() -> UIBezierPath {

    let _bezierPath = bezierPath.copy() as! UIBezierPath
    _bezierPath.lineJoinStyle = .round
    _bezierPath.lineCapStyle = .round
    _bezierPath.lineWidth = brush.width

    return _bezierPath
  }

  public func draw(in context: CGContext, canvasSize: CGSize) {
    UIGraphicsPushContext(context)
    context.saveGState()
    defer {
      context.restoreGState()
      UIGraphicsPopContext()
    }

    draw()
  }

  private func draw() {

    guard let context = UIGraphicsGetCurrentContext() else {
      return
    }

    context.saveGState()
    defer {
      context.restoreGState()
    }

    brush.color.setStroke()
    let bezierPath = brushedPath()
    bezierPath.stroke(with: brush.blendMode, alpha: brush.alpha)
  }

}
