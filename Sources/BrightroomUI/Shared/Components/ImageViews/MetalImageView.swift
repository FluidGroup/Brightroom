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
import SwiftUI
import UIKit
import BrightroomEngine

public enum ImageDisplayBackground {
  case transparent
  case color(UIColor)

  var metalDisplayBackground: _MetalImageView.DisplayBackground {
    switch self {
    case .transparent:
      return .transparent
    case .color(let color):
      return .color(color)
    }
  }
}

public struct SwiftUIMetalImageView: View {

  private let image: CIImage?
  private let contentMode: UIView.ContentMode
  private let displayBackground: ImageDisplayBackground
  private let postProcessing: (CIImage) -> CIImage

  public init(
    image: CIImage?,
    contentMode: UIView.ContentMode = .scaleAspectFill,
    displayBackground: ImageDisplayBackground = .transparent,
    postProcessing: @escaping (CIImage) -> CIImage = { $0 }
  ) {
    self.image = image
    self.contentMode = contentMode
    self.displayBackground = displayBackground
    self.postProcessing = postProcessing
  }

  public var body: some View {
    MetalImageRepresentable(
      image: image,
      contentMode: contentMode,
      displayBackground: displayBackground,
      postProcessing: postProcessing
    )
  }
}

private struct MetalImageRepresentable: UIViewRepresentable {

  let image: CIImage?
  let contentMode: UIView.ContentMode
  let displayBackground: ImageDisplayBackground
  let postProcessing: (CIImage) -> CIImage

  func makeUIView(context: Context) -> _MetalImageView {
    let view = _MetalImageView()
    view.clipsToBounds = true
    view.contentMode = contentMode
    view.displayBackground = displayBackground.metalDisplayBackground
    view.postProcessing = postProcessing
    return view
  }

  func updateUIView(_ uiView: _MetalImageView, context: Context) {
    uiView.contentMode = contentMode
    uiView.displayBackground = displayBackground.metalDisplayBackground
    uiView.postProcessing = postProcessing
    uiView.display(image: image)
  }
}

/// https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
final class _MetalImageView: MTKView, CIImageDisplaying, MTKViewDelegate {
  enum DisplayBackground {
    case transparent
    case color(UIColor)
  }

  var postProcessing: (CIImage) -> CIImage = { $0 } {
    didSet {
      setNeedsDisplay()
    }
  }

  var displayBackground: DisplayBackground = .transparent {
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

  override var contentMode: UIView.ContentMode {
    didSet {
      setNeedsDisplay()
    }
  }

  override init(
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

    if #available(iOS 17, *) {
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: _MetalImageView, _) in
        view.setNeedsDisplay()
      }
    }

    #if targetEnvironment(simulator)
    #else
      /// For supporting wide-color - extended sRGB

    let metalLayer = layer as! CAMetalLayer

    if #available(iOS 16, *) {
      metalLayer.wantsExtendedDynamicRangeContent = true
    }

    let hasP3Display = traitCollection.displayGamut == .P3

    if hasP3Display {
      metalLayer.pixelFormat = .bgr10a2Unorm
    }

    #endif

  }

  required init(
    coder: NSCoder
  ) {
    fatalError("init(coder:) has not been implemented")
  }

  func display(image: CIImage?) {
    self.image = image
    setNeedsDisplay()
  }

  override var frame: CGRect {
    didSet {
      setNeedsDisplay()
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
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

    EditorLog.debug(.imageView, "[_MetalImageView] Render")

    #if DEBUG
      //    if image.cgImage != nil {
      //      EditorLog.debug("[_MetalImageView] the backing storage of the image is in CPU, Render by metal might be slow.")
      //    }
    #endif

    let bounds = CGRect(
      origin: .zero,
      size: drawableSize
    )

    let fixedImage = image.removingExtentOffset()

    let resolvedImage = downsample(image: fixedImage, bounds: bounds, contentMode: contentMode)

    let processedImage = postProcessing(resolvedImage)
    let displayImage = processedImage.compositedOverDisplayBackground(
      displayBackground,
      bounds: bounds,
      traitCollection: traitCollection
    )

    clearContents: do {

      //      renderPassDescriptor.colorAttachments[0].texture = drawable.texture
      renderPassDescriptor.colorAttachments[0].clearColor = displayBackground.clearColor(
        traitCollection: traitCollection
      )
      renderPassDescriptor.colorAttachments[0].loadAction = .clear
      renderPassDescriptor.colorAttachments[0].storeAction = .store

      let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
      commandEncoder.endEncoding()
    }

    EditorLog.debug(.imageView, "ColorSpace => \(displayImage.colorSpace as Any)")

    ciContext.render(
      displayImage,
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

    let pixelAlignedTargetRect = targetRect.pixelAlignedForDisplay()
    let scaleX = pixelAlignedTargetRect.width / image.extent.width
    let scaleY = pixelAlignedTargetRect.height / image.extent.height
    let scale = min(scaleX, scaleY)
    let clampedImage = image.clampedToExtent()

    let resolvedImage: CIImage

    #if targetEnvironment(simulator)

    if #available(iOS 17, *) {
      // Fixes geometry in Metal
      resolvedImage = clampedImage
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(
          by: CGAffineTransform(
            translationX: pixelAlignedTargetRect.origin.x,
            y: pixelAlignedTargetRect.origin.y
          )
        )
        .cropped(to: pixelAlignedTargetRect)

    } else {
      // Fixes geometry in Metal
      resolvedImage = clampedImage
        .transformed(
          by: CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(.init(translationX: 0, y: image.extent.height))
            .concatenating(.init(scaleX: scale, y: scale))
            .concatenating(
              .init(
                translationX: pixelAlignedTargetRect.origin.x,
                y: pixelAlignedTargetRect.origin.y
              )
            )
        )
        .cropped(to: pixelAlignedTargetRect)

    }


    #else
      resolvedImage =
        clampedImage
        //        .resizedSmooth(targetSize: targetRect.size)
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(
          by: CGAffineTransform(
            translationX: pixelAlignedTargetRect.origin.x,
            y: pixelAlignedTargetRect.origin.y
          )
        )
        .cropped(to: pixelAlignedTargetRect)

    #endif

    return resolvedImage
  }

}

private extension _MetalImageView.DisplayBackground {

  func resolvedColor(traitCollection: UITraitCollection) -> UIColor? {
    switch self {
    case .transparent:
      return nil
    case .color(let color):
      return color.resolvedColor(with: traitCollection)
    }
  }

  func clearColor(traitCollection: UITraitCollection) -> MTLClearColor {
    guard let color = resolvedColor(traitCollection: traitCollection) else {
      return .init(red: 0, green: 0, blue: 0, alpha: 0)
    }

    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
      return .init(red: 0, green: 0, blue: 0, alpha: 0)
    }

    return .init(
      red: Double(red),
      green: Double(green),
      blue: Double(blue),
      alpha: Double(alpha)
    )
  }
}

private extension CGRect {

  func pixelAlignedForDisplay() -> CGRect {
    guard
      minX.isFinite,
      minY.isFinite,
      maxX.isFinite,
      maxY.isFinite
    else {
      return self
    }

    let minX = self.minX.rounded(.toNearestOrAwayFromZero)
    let minY = self.minY.rounded(.toNearestOrAwayFromZero)
    let maxX = self.maxX.rounded(.toNearestOrAwayFromZero)
    let maxY = self.maxY.rounded(.toNearestOrAwayFromZero)

    return CGRect(
      x: minX,
      y: minY,
      width: max(maxX - minX, 1),
      height: max(maxY - minY, 1)
    )
  }
}

private extension CIImage {

  func compositedOverDisplayBackground(
    _ displayBackground: _MetalImageView.DisplayBackground,
    bounds: CGRect,
    traitCollection: UITraitCollection
  ) -> CIImage {
    guard let color = displayBackground.resolvedColor(traitCollection: traitCollection) else {
      return self
    }

    let backgroundImage = CIImage(color: CIColor(color: color))
      .cropped(to: bounds)

    return composited(over: backgroundImage)
  }

  func resizedSmooth(targetSize: CGSize) -> CIImage {

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
