import AsyncDisplayKit
@testable import BrightroomEngine
@testable import BrightroomUI
import GlossButtonNode
import MetalKit
import TextureSwiftSupport
import UIKit

final class DemoMTLTextureViewController: StackScrollNodeViewController {

  override init() {
    super.init()
    title = "MTLTexture"
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    stackScrollNode.append(nodes: [

      Components.makeSelectionCell(
        title: "MTKView <- CIImage <- MTLTexture <- CGImage",
        onTap: { [unowned self] in

          let device = MTLCreateSystemDefaultDevice()!
          let loader = MTKTextureLoader(device: device)
          let texture = try! loader.newTexture(cgImage: Asset.l1000316.image.cgImage!, options: [:])
          let sourceImage = CIImage(mtlTexture: texture, options: [:])!

          let controller = _MTLTextureViewController(sourceImage: sourceImage, displayView: SampleMTLTextureDisplayView())

          navigationController?.pushViewController(controller, animated: true)

        }
      ),

      Components.makeSelectionCell(
        title: "MTKView <- CIImage <- CGImage",
        onTap: { [unowned self] in

          let image = CIImage(image: Asset.l1000316.image, options: [:])!

          let controller = _MTLTextureViewController(sourceImage: image, displayView: SampleMTLTextureDisplayView())

          navigationController?.pushViewController(controller, animated: true)

        }
      ),

      Components.makeSelectionCell(
        title: "UIImageView <- CIImage <- MTLTexture <- CGImage",
        onTap: { [unowned self] in

          let device = MTLCreateSystemDefaultDevice()!
          let loader = MTKTextureLoader(device: device)
          let texture = try! loader.newTexture(cgImage: Asset.l1000316.image.cgImage!, options: [:])
          let sourceImage = CIImage(mtlTexture: texture, options: [:])!

          let controller = _MTLTextureViewController(sourceImage: sourceImage, displayView: _ImageView())

          navigationController?.pushViewController(controller, animated: true)

        }
      ),

      Components.makeSelectionCell(
        title: "UIImageView <- CIImage <- CGImage",
        onTap: { [unowned self] in

          let image = CIImage(image: Asset.l1000316.image, options: [:])!

          let controller = _MTLTextureViewController(sourceImage: image, displayView: _ImageView())

          navigationController?.pushViewController(controller, animated: true)

        }
      ),

    ])
  }

}

private final class _MTLTextureViewController: UIViewController {

  private let displayView: CIImageDisplaying & UIView
  private let slider = UISlider()

  private let sourceImage: CIImage

  init(sourceImage: CIImage, displayView: CIImageDisplaying & UIView) {
    self.displayView = displayView
    self.sourceImage = sourceImage
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = .white

    view.addSubview(displayView)
    view.addSubview(slider)

    displayView.edgesToSuperview(
      excluding: .bottom,
      insets: .init(top: 20, left: 20, bottom: 20, right: 20),
      usingSafeArea: true
    )
    displayView.aspectRatio(1)

    slider.topToBottom(of: displayView, offset: 20)
    slider.horizontalToSuperview(insets: .init(top: 0, left: 20, bottom: 0, right: 20))

    slider.addTarget(self, action: #selector(handleValueChanged), for: .valueChanged)
    slider.minimumValue = 0
    slider.maximumValue = 200

    displayView.display(image: sourceImage)
  }

  @objc private func handleValueChanged() {

    let value = slider.value

//    let blurredImage =
//      sourceImage
//      .clampedToExtent()
//      .applyingGaussianBlur(sigma: Double(value))
//      .cropped(to: sourceImage.extent)

    displayView.postProcessing = { sourceImage in
      sourceImage
        .clampedToExtent()
        .applyingGaussianBlur(sigma: Double(value))
        .cropped(to: sourceImage.extent)
    }

//    displayView.display(image: sourceImage)
  }

}


private final class SampleMTLTextureDisplayView: MTKView, MTKViewDelegate, CIImageDisplaying {

  private let defaultColorSpace = CGColorSpaceCreateDeviceRGB()

  func display(image: CIImage?) {
    self.image = image
    setNeedsDisplay()
  }

  var postProcessing: (CIImage) -> CIImage = { $0 } {
    didSet {
      setNeedsDisplay()
    }
  }

  private var image: CIImage?

  private lazy var commandQueue: MTLCommandQueue = { [unowned self] in
    self.device!.makeCommandQueue()!
  }()

  private lazy var ciContext: CIContext = {
    [unowned self] in
    CIContext(mtlDevice: self.device!)
  }()

  public override init(
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
      colorPixelFormat = .bgra10_xr
    #endif
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {

  }

  func draw(in view: MTKView) {

    guard
      let image = image,
      let targetTexture = currentDrawable?.texture
    else {
      return
    }

    let commandBuffer = commandQueue.makeCommandBuffer()

    let bounds = CGRect(
      origin: .zero,
      size: drawableSize
    )

    let fixedImage = image.removingExtentOffset()

    let resolvedImage = downsample(image: fixedImage, bounds: bounds, contentMode: contentMode)

    let processedImage = postProcessing(resolvedImage)

    ciContext.render(
      processedImage,
      to: targetTexture,
      commandBuffer: commandBuffer,
      bounds: bounds,
      colorSpace: image.colorSpace ?? defaultColorSpace
    )

    commandBuffer?.present(currentDrawable!)
    commandBuffer?.commit()

  }

  private func downsample(image: CIImage, bounds: CGRect, contentMode: UIView.ContentMode)
    -> CIImage
  {

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
      // Fixes geometry in Metal
      resolvedImage =
        image
        .transformed(
          by: CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(.init(translationX: 0, y: image.extent.height))
            .concatenating(.init(scaleX: scale, y: scale))
            .concatenating(.init(translationX: targetRect.origin.x, y: targetRect.origin.y))
        )

    #else
      resolvedImage =
        image
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(
          by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y)
        )

    #endif

    return resolvedImage
  }


}
