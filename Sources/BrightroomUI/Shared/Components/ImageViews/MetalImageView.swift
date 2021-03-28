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

import MetalKit
import UIKit
#if !COCOAPODS
import BrightroomEngine
#endif

open class MetalImageView: MTKView, CIImageDisplaying, MTKViewDelegate {
  public var postProcessing: (CIImage) -> CIImage = { $0 } {
    didSet {
      setNeedsDisplay()
    }
  }

  private let defaultColorSpace = CGColorSpaceCreateDeviceRGB()
  private var image: CIImage?

  private lazy var commandQueue: MTLCommandQueue = { [unowned self] in
    self.device!.makeCommandQueue()!
  }()

  private lazy var ciContext: CIContext = {
    [unowned self] in
    CIContext(mtlDevice: self.device!)
  }()

  override open var contentMode: UIView.ContentMode {
    didSet {
      setNeedsDisplay()
    }
  }

  override public init(
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
    isOpaque = false
    backgroundColor = .clear
    framebufferOnly = false
    delegate = self
    enableSetNeedsDisplay = true
    autoResizeDrawable = true
    contentMode = .scaleAspectFill
    clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
    clearsContextBeforeDrawing = true
    
    #if targetEnvironment(simulator)
    #else
    /// For supporting wide-color - extended sRGB
    colorPixelFormat = .bgra10_xr
    #endif
  }

  public required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func display(image: CIImage?) {
    self.image = image
    setNeedsDisplay()
  }

  override open var frame: CGRect {
    didSet {
      setNeedsDisplay()
    }
  }

  public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  public func draw(in view: MTKView) {
    renderImage()
  }

  func renderImage() {
    guard
      let image = image,
      let targetTexture = currentDrawable?.texture
    else {
      return
    }

    #if DEBUG
//    if image.cgImage != nil {
//      EditorLog.debug("[MetalImageView] the backing storage of the image is in CPU, Render by metal might be slow.")
//    }
    #endif
    
    let commandBuffer = commandQueue.makeCommandBuffer()
        
    let bounds = CGRect(
      origin: .zero,
      size: drawableSize
    )
    
    let fixedImage = image.removingExtentOffset()
    
    let resolvedImage = downsample(image: fixedImage, bounds: bounds, contentMode: contentMode)

    let processedImage = postProcessing(resolvedImage)
    
    EditorLog.debug("[MetalImageView] image color-space \(processedImage.colorSpace as Any)")
    
    ciContext.render(
      processedImage,
      to: targetTexture,
      commandBuffer: commandBuffer,
      bounds: bounds,
      colorSpace: fixedImage.colorSpace ?? defaultColorSpace
    )

    commandBuffer?.present(currentDrawable!)
    commandBuffer?.commit()
  }
}
