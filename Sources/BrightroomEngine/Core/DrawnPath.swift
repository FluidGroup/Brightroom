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

import CoreImage
import UIKit

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
    _bezierPath.lineWidth = brush.pixelSize

    return _bezierPath
  }

  public func draw(in context: CGContext) {
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
            
    let boundingBox = context.boundingBoxOfClipPath
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: 0, y: -(boundingBox.maxY + boundingBox.minY))    
    assert(context.boundingBoxOfClipPath == boundingBox)
 
    brush.color.setStroke()
    let bezierPath = brushedPath()
    bezierPath.stroke(with: .normal, alpha: brush.alpha)
  }

}
