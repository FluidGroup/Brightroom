import CoreImage
import Metal

/// Primes Core Image's GPU pipeline for a freshly-loaded editing image.
///
/// Loading no longer pre-uploads the source into an `MTLTexture` (Core Image now
/// uploads the `CIImage(cgImage:)` lazily on first render). Without warming, that
/// upload — together with the one-time Metal pipeline-state compilation Core Image
/// performs the first time it renders on a device — would land on the main thread
/// during the editing canvas's first `draw(in:)`, causing a visible hitch.
///
/// Rendering the source once on a background queue here moves that cost off the
/// first frame: the Core Image kernel/pipeline compilation is cached device-wide
/// (so the canvas's own `CIContext` reuses it), and the source bitmap is already
/// decoded, leaving only a cheap CPU→GPU blit for the first real frame.
enum EditingImageWarmUp {

  /// A dedicated, process-wide context used only for warm-up renders. Creating it
  /// lazily means the first `warmUp(_:)` call also absorbs the context/library
  /// compilation cost on the background queue rather than on the first frame.
  private static let context: CIContext? = {
    guard let device = MTLCreateSystemDefaultDevice() else {
      return nil
    }
    return CIContext(
      mtlDevice: device,
      options: [.name: "Brightroom.WarmUp", .cacheIntermediates: false]
    )
  }()

  /// Forces a synchronous GPU render of `image`, sampling it in full so the source
  /// texture is uploaded and the render pipeline is compiled. The output is
  /// discarded. Safe to call from a background queue; the readback is bounded to a
  /// small size to keep the cost negligible.
  static func warmUp(_ image: CIImage) {
    guard let context else {
      return
    }

    let extent = image.extent
    guard extent.isInfinite == false, extent.isEmpty == false else {
      return
    }

    // Downscale so the whole source is sampled (forcing a full upload and the
    // sampling pipeline) while keeping the read-back tiny.
    let maxSide = max(extent.width, extent.height)
    let scale = maxSide > 256 ? 256 / maxSide : 1
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    autoreleasepool {
      _ = context.createCGImage(scaled, from: scaled.extent)
    }

    EngineLog.debug(.stack, "Warmed up Core Image pipeline for editing image")
  }
}
