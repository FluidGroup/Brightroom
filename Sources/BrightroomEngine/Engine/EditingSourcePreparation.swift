import CoreImage
import Metal

/// Uploads a freshly-loaded editing source into a persistent GPU texture and
/// returns a texture-backed `CIImage`.
///
/// ## Why
/// The v5 editing canvas re-renders the source `CIImage` into its own viewport
/// texture on every frame, and zoom / pan / rotation invalidate that viewport
/// cache every frame. With a `CIImage(cgImage:)` source, Core Image re-uploads
/// the full source bitmap CPU->GPU on each of those renders
/// (`CIMetalTextureSetBytes` / `replaceRegion:withBytes:`). A device Time
/// Profiler trace of crop rotation showed that upload dominating the main
/// thread (~40% of all main-thread time).
///
/// Holding the source in a GPU-resident texture removes that per-frame upload:
/// every consumer samples a texture that already lives on the GPU.
///
/// ## Avoiding the pitfalls that retired the previous texture path
/// The earlier load-time texture conversion (removed in #297) used
/// `MTKTextureLoader`, which quantized to 8-bit, could not handle 16-bit
/// sources, and needed a y-flip that caused recurring orientation bugs. This
/// path avoids all three:
///
/// - It renders through a `CIContext` into a texture whose depth matches the
///   source: `rgba8Unorm` for an 8-bit source (lossless, half the memory),
///   `rgba16Float` for >8-bit / HDR sources (no 8-bit clamp, EDR-ready).
/// - It encodes in the source's own color space and reads it back through the
///   same space, so the result is colorimetrically equivalent to
///   `CIImage(cgImage:).oriented(orientation)`.
/// - It uses the same `CIContext.render(to:)` / `CIImage(mtlTexture:)`
///   convention the canvas already round-trips its intermediate textures
///   through, which is flip-free — so no manual y-flip is needed.
///
/// Building the texture also primes Core Image's device-wide pipeline cache, so
/// it replaces the separate warm-up render the CGImage path required.
enum EditingSourcePreparation {

  /// The system default device. The editing canvas creates its `MTKView` and
  /// `CIContext` from `MTLCreateSystemDefaultDevice()` as well, so the texture
  /// produced here lives on the same device the canvas samples it from (iOS has
  /// a single GPU; no cross-device concern).
  private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

  /// Dedicated process-wide context for source uploads. Created lazily so the
  /// first call absorbs the context/library compilation cost on the calling
  /// (background) queue rather than on the first frame.
  private static let context: CIContext? = {
    guard let device else { return nil }
    return CIContext(mtlDevice: device, options: [.name: "Brightroom.SourceUpload"])
  }()

  /// Returns an oriented, GPU-resident `CIImage` for `cgImage`, or `nil` if no
  /// Metal device is available or texture creation fails (the caller falls back
  /// to the CPU-backed `CIImage(cgImage:)`).
  ///
  /// The returned image is colorimetrically equivalent to
  /// `CIImage(cgImage:).oriented(orientation)`, with extent origin at zero. The
  /// returned `CIImage` retains the backing texture for its lifetime.
  static func makeGPUResidentSource(
    cgImage: CGImage,
    orientation: CGImagePropertyOrientation
  ) -> CIImage? {
    guard
      let device,
      let context,
      let commandQueue = device.makeCommandQueue()
    else {
      return nil
    }

    let oriented = CIImage(cgImage: cgImage).oriented(orientation)
    let extent = oriented.extent
    guard
      extent.isInfinite == false,
      extent.isEmpty == false,
      extent.width >= 1,
      extent.height >= 1
    else {
      return nil
    }

    let width = Int(extent.width.rounded())
    let height = Int(extent.height.rounded())

    // Match the texture depth to the source. An 8-bit source (the common case)
    // carries no detail beyond 8 bits and no extended-range values, so an
    // `rgba8Unorm` texture is lossless AND uses half the memory of half-float.
    // Reserve `rgba16Float` for >8-bit / float sources (16-bit, HDR), where it
    // preserves precision and out-of-[0,1] range. (`rgba8Unorm`, not the `_srgb`
    // variant: the color space below carries the gamma encoding, so the sampler
    // must store the bytes raw.)
    let pixelFormat: MTLPixelFormat = cgImage.bitsPerComponent > 8 ? .rgba16Float : .rgba8Unorm

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      return nil
    }

    // Encode in the source's own color space. Reading back through the same
    // space reproduces the source exactly; the float texture additionally keeps
    // wide-gamut / out-of-sRGB values intact for >8-bit sources.
    let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let renderBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let normalized = oriented.transformed(
      by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      return nil
    }
    context.render(
      normalized,
      to: texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: colorSpace
    )
    // Wait so the texture is fully filled before it is published and sampled by
    // the canvas's own context. This runs on a background queue at load time, so
    // the wait never touches the main thread; it also gates presentation behind a
    // hot pipeline, matching the previous warm-up's "spinner until ready" behavior.
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    EngineLog.debug(.stack, "Uploaded editing source to GPU texture (\(width)x\(height))")

    return CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])
  }
}
