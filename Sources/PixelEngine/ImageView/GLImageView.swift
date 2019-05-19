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

import Foundation

import GLKit
import AVFoundation

public class GLImageView : GLKView, HardwareImageViewType {

  // MARK: - Properties

  let coreImageContext: CIContext

  public var image: CIImage? {
    didSet {
      self.update()
    }
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

    var _bounds = bounds
    _bounds.size.width *= contentScaleFactor
    _bounds.size.height *= contentScaleFactor

    let targetRect = Geometry.rectThatAspectFill(
      aspectRatio: image.extent.size,
      minimumRect: _bounds
    )

    coreImageContext.draw(image, in: targetRect, from: image.extent)
  }
}
