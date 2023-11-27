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

/// https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
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
      device: device ?? MTLCreateSystemDefaultDevice()
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

    let metalLayer = layer as! CAMetalLayer

    if #available(iOS 16, *) {
      metalLayer.wantsExtendedDynamicRangeContent = true
    }

    let hasP3Display = traitCollection.displayGamut == .P3

    if hasP3Display {
      metalLayer.pixelFormat = .bgra10_xr
    }

    #endif

  }

  public required init(
    coder: NSCoder
  ) {
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
      let targetTexture = currentDrawable?.texture,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let renderPassDescriptor = currentRenderPassDescriptor,
      let drawable = currentDrawable
    else {
      return
    }

    EditorLog.debug(.imageView, "[MetalImageView] Render")

    #if DEBUG
      //    if image.cgImage != nil {
      //      EditorLog.debug("[MetalImageView] the backing storage of the image is in CPU, Render by metal might be slow.")
      //    }
    #endif

    let bounds = CGRect(
      origin: .zero,
      size: drawableSize
    )

    let fixedImage = image.removingExtentOffset()

    let resolvedImage = downsample(image: fixedImage, bounds: bounds, contentMode: contentMode)

    let processedImage = postProcessing(resolvedImage)

    clearContents: do {

      //      renderPassDescriptor.colorAttachments[0].texture = drawable.texture
      renderPassDescriptor.colorAttachments[0].clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
      renderPassDescriptor.colorAttachments[0].loadAction = .clear
      renderPassDescriptor.colorAttachments[0].storeAction = .store

      let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
      commandEncoder.endEncoding()
    }

    EditorLog.debug(.imageView, "ColorSpace => \(processedImage.colorSpace as Any)")

    ciContext.render(
      processedImage,
      to: targetTexture,
      commandBuffer: commandBuffer,
      bounds: bounds,
      colorSpace: defaultColorSpace
    )

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  func downsample(image: CIImage, bounds: CGRect, contentMode: UIView.ContentMode) -> CIImage {

    let targetRect: CGRect

    switch contentMode {
    case .scaleAspectFill:
      targetRect = Geometry.rectThatAspectFill(
        aspectRatio: image.extent.size,
        minimumRect: bounds
      )
    case .scaleAspectFit:
      targetRect = Geometry.rectThatAspectFit(
        aspectRatio: image.extent.size,
        boundingRect: bounds
      )
    default:
      targetRect = Geometry.rectThatAspectFit(
        aspectRatio: image.extent.size,
        boundingRect: bounds
      )
      assertionFailure("ContentMode:\(contentMode) is not supported.")
    }

    let scaleX = targetRect.width / image.extent.width
    let scaleY = targetRect.height / image.extent.height
    let scale = min(scaleX, scaleY)

    let resolvedImage: CIImage

    #if targetEnvironment(simulator)

    if #available(iOS 17, *) {
      // Fixes geometry in Metal
      resolvedImage = image
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y))

    } else {
      // Fixes geometry in Metal
      resolvedImage = image
        .transformed(
          by: CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(.init(translationX: 0, y: image.extent.height))
            .concatenating(.init(scaleX: scale, y: scale))
            .concatenating(.init(translationX: targetRect.origin.x, y: targetRect.origin.y))
        )

    }


    #else
      resolvedImage =
        image
        //        .resizedSmooth(targetSize: targetRect.size)
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y))

    #endif

    return resolvedImage
  }

}

extension CIImage {

  fileprivate func resizedSmooth(targetSize: CGSize) -> CIImage {

    let resizeFilter = CIFilter(name: "CILanczosScaleTransform")!

    let scale = targetSize.height / (extent.height)
    let aspectRatio = targetSize.width / ((extent.width) * scale)

    resizeFilter.setValue(self, forKey: kCIInputImageKey)
    resizeFilter.setValue(scale, forKey: kCIInputScaleKey)
    resizeFilter.setValue(aspectRatio, forKey: kCIInputAspectRatioKey)
    let outputImage = resizeFilter.outputImage

    return outputImage!
  }
}
