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

// The demo's `CIImage` display view. It used to be BrightroomUI's public
// `SwiftUIMetalImageView`; the editor never used it, so it lives here now.

enum ImageDisplayBackground {
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

struct SwiftUIMetalImageView: View {

  private let image: CIImage?
  private let contentMode: UIView.ContentMode
  private let displayBackground: ImageDisplayBackground
  private let postProcessing: (CIImage) -> CIImage

  init(
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

  var body: some View {
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
final class _MetalImageView: MTKView, MTKViewDelegate {
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

  /// CIContext creation costs ~100ms+ on device; instances of this view are
  /// created per cell in places like the filter-preset list, so the context is
  /// shared per Metal device instead of per view. CIContext is thread-safe.
  private static let sharedCIContextLock = NSLock()
  // Guarded by sharedCIContextLock; the lock makes access race-free, so opt out
  // of the Swift 6 global-mutable-state check rather than re-isolating.
  private nonisolated(unsafe) static var sharedCIContexts: [ObjectIdentifier: CIContext] = [:]

  private static func sharedCIContext(for device: MTLDevice) -> CIContext {
    sharedCIContextLock.lock()
    defer { sharedCIContextLock.unlock() }

    let key = ObjectIdentifier(device)
    if let cached = sharedCIContexts[key] {
      return cached
    }
    // The context now outlives the views; keep intermediate caching off so it
    // does not accumulate render caches for the process lifetime.
    let context = CIContext(
      mtlDevice: device,
      options: [
        .name: "MetalImageView.shared",
        .cacheIntermediates: false,
      ]
    )
    sharedCIContexts[key] = context
    return context
  }

  private lazy var ciContext: CIContext = {
    [unowned self] in
    Self.sharedCIContext(for: self.device!)
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

    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: _MetalImageView, _) in
      view.setNeedsDisplay()
    }

    #if targetEnvironment(simulator)
    #else
      /// For supporting wide-color - extended sRGB

    let metalLayer = layer as! CAMetalLayer

    metalLayer.wantsExtendedDynamicRangeContent = true

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

    let bounds = CGRect(
      origin: .zero,
      size: drawableSize
    )

    let fixedImage = image.transformed(
      by: CGAffineTransform(
        translationX: -image.extent.origin.x,
        y: -image.extent.origin.y
      )
    )

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
      targetRect = bounds.aspectFillRect(for: image.extent.size)
    case .scaleAspectFit:
      targetRect = bounds.aspectFitRect(for: image.extent.size)
    default:
      targetRect = bounds.aspectFitRect(for: image.extent.size)
      assertionFailure("ContentMode:\(contentMode) is not supported.")
    }

    let pixelAlignedTargetRect = targetRect.pixelAlignedForDisplay()
    let scaleX = pixelAlignedTargetRect.width / image.extent.width
    let scaleY = pixelAlignedTargetRect.height / image.extent.height
    let scale = min(scaleX, scaleY)
    let clampedImage = image.clampedToExtent()

    return clampedImage
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .transformed(
        by: CGAffineTransform(
          translationX: pixelAlignedTargetRect.origin.x,
          y: pixelAlignedTargetRect.origin.y
        )
      )
      .cropped(to: pixelAlignedTargetRect)
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

  /// The rectangle of `aspectRatio` centered in this one and covering it, with
  /// its size rounded up to whole points.
  func aspectFillRect(for aspectRatio: CGSize) -> CGRect {
    let widthRatio = width / aspectRatio.width
    let heightRatio = height / aspectRatio.height
    var size = self.size

    if widthRatio > heightRatio {
      size.height = width / aspectRatio.width * aspectRatio.height
    } else if heightRatio > widthRatio {
      size.width = height / aspectRatio.height * aspectRatio.width
    }

    return centered(CGSize(width: ceil(size.width), height: ceil(size.height)))
  }

  /// The rectangle of `aspectRatio` centered in this one and fitting inside
  /// it, with its size rounded up to whole points.
  func aspectFitRect(for aspectRatio: CGSize) -> CGRect {
    let widthRatio = width / aspectRatio.width
    let heightRatio = height / aspectRatio.height
    var size = self.size

    if widthRatio < heightRatio {
      size.height = width / aspectRatio.width * aspectRatio.height
    } else if heightRatio < widthRatio {
      size.width = height / aspectRatio.height * aspectRatio.width
    }

    return centered(CGSize(width: ceil(size.width), height: ceil(size.height)))
  }

  private func centered(_ size: CGSize) -> CGRect {
    CGRect(
      x: minX + (width - size.width) / 2,
      y: minY + (height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

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
}
