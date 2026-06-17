import CoreImage
import Metal

/// Bakes a content `CIImage` (an effects / blur Core Image graph in canvas
/// coordinates) into a persistent GPU texture, returning a texture-backed
/// `CIImage` that is a drop-in for the original.
///
/// ## Why
/// During crop rotation / pan / zoom the canvas re-evaluates the base and
/// adjusted Core Image graphs every frame because its viewport caches are keyed
/// on `visibleContentRect` / `visibleCanvasFrame`, which change each frame. A
/// device Time Profiler trace showed that — once the per-frame source upload was
/// eliminated — the remaining cost was Core Image allocating fresh intermediate
/// IOSurfaces under a barrier lock every frame (`create_intermediate` /
/// `GetSurfaceFromCache`), i.e. re-running the (expensive, blur-heavy) graph.
///
/// The effect *content* is invariant during a gesture (only the viewport moves),
/// so baking base / adjusted into textures ONCE per render-images generation and
/// resampling those textures per frame collapses the per-frame work to a cheap
/// affine resample + composite.
///
/// ## Coordinate / orientation contract
/// The bake renders the image (translated to the origin and scaled down to the
/// cap) into the texture, then wraps it with `CIImage(mtlTexture:)` and maps it
/// back to the original `extent`. The `CIContext.render(to:)` /
/// `CIImage(mtlTexture:)` round-trip is flip-free — the same identity the
/// canvas's other intermediate textures rely on — so no y-flip is applied.
enum EditingCanvasContentBake {

  struct Result {
    let texture: MTLTexture
    let image: CIImage
  }

  /// Renders `image` into a texture whose longest side is at most `cap` pixels,
  /// returning a texture-backed `CIImage` mapped back into `image.extent`.
  ///
  /// `cap` bounds memory and bake cost; detail beyond the editing-source
  /// resolution does not exist, so capping there is visually lossless for a
  /// fit-to-frame preview. Returns `nil` if the extent is degenerate or a Metal
  /// resource cannot be created.
  static func bake(
    _ image: CIImage,
    cap: CGFloat,
    device: MTLDevice,
    commandQueue: MTLCommandQueue,
    ciContext: CIContext,
    pixelFormat: MTLPixelFormat,
    colorSpace: CGColorSpace
  ) -> Result? {
    let extent = image.extent
    guard
      extent.isInfinite == false,
      extent.isEmpty == false,
      extent.width >= 1,
      extent.height >= 1,
      cap >= 1
    else {
      return nil
    }

    let maxSide = max(extent.width, extent.height)
    let scale = maxSide > cap ? cap / maxSide : 1
    let width = max(1, Int((extent.width * scale).rounded()))
    let height = max(1, Int((extent.height * scale).rounded()))

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard
      let texture = device.makeTexture(descriptor: descriptor),
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return nil
    }

    // Clear first so the ≤1px rounding margin between the scaled extent and the
    // texture size never samples uninitialized memory.
    let clearDescriptor = MTLRenderPassDescriptor()
    clearDescriptor.colorAttachments[0].texture = texture
    clearDescriptor.colorAttachments[0].loadAction = .clear
    clearDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    clearDescriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: clearDescriptor)?.endEncoding()

    let renderImage = image
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    ciContext.render(
      renderImage,
      to: texture,
      commandBuffer: commandBuffer,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      colorSpace: colorSpace
    )
    // No CPU wait: the live canvas samples this texture through the SAME
    // `ciContext` / command queue, so GPU-side ordering already guarantees the
    // bake completes before any dependent render (same contract as the other
    // viewport texture caches).
    commandBuffer.commit()

    guard
      let baked = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])
    else {
      return nil
    }
    let restored = baked
      .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
      .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    return Result(texture: texture, image: restored)
  }
}
