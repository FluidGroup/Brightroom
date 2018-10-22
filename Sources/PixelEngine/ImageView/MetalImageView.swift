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

#if canImport(MetalKit) && !targetEnvironment(simulator)
import MetalKit

open class MetalImageView : MTKView, HardwareImageViewType {

  public var image: CIImage? {
    didSet {
      renderImage()
    }
  }

  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  private lazy var commandQueue: MTLCommandQueue = { [unowned self] in
    return self.device!.makeCommandQueue()!
    }()

  private lazy var ciContext: CIContext = {
    [unowned self] in
    return CIContext(mtlDevice: self.device!)
    }()

  public override init(
    frame frameRect: CGRect,
    device: MTLDevice?
    ) {
    super.init(
      frame: frameRect,
      device: device ??
        MTLCreateSystemDefaultDevice()
    )
    if super.device == nil {
      fatalError("Device doesn't support Metal")
    }
    framebufferOnly = false
  }

  public required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func renderImage() {
    guard
      let image = image,
      let targetTexture = currentDrawable?.texture else
    {
      return
    }

    let commandBuffer = commandQueue.makeCommandBuffer()

    let bounds = CGRect(
      origin: .zero,
      size: drawableSize
    )

    let targetRect = Geometry.rectThatAspectFill(
      aspectRatio: image.extent.size,
      minimumRect: bounds
    )

    let originX = targetRect.origin.x
    let originY = targetRect.origin.y
    let scaleX = targetRect.width / image.extent.width
    let scaleY = targetRect.height / image.extent.height
    let scale = min(scaleX, scaleY)
    let scaledImage = image
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .transformed(by: CGAffineTransform(translationX: originX, y: originY))

    ciContext.render(
      scaledImage,
      to: targetTexture,
      commandBuffer: commandBuffer,
      bounds: bounds,
      colorSpace: colorSpace
    )

    commandBuffer?.present(currentDrawable!)
    commandBuffer?.commit()
  }
}

private func makeCGAffineTransform(from: CGRect, to: CGRect) -> CGAffineTransform {

  return .init(
    a: to.width / from.width,
    b: 0,
    c: 0,
    d: to.height / from.height,
    tx: to.midX - from.midX,
    ty: to.midY - from.midY
  )
}

#endif
