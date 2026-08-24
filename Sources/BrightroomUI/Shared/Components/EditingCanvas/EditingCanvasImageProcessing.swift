import CoreGraphics
import CoreImage
import Metal

enum EditingCanvasImageProcessing {

  // MARK: - Color contract
  //
  // The editing canvas crosses the Metal<->Core Image boundary many times
  // (source bake, prepared base/adjusted, mask, drawable). Each crossing has a
  // DISTINCT color-space role; collapsing them into one constant is what made
  // the canvas clamp Display-P3 to sRGB. The four contracts below keep wide
  // gamut intact while avoiding double color management:
  //
  //   working      == intermediate   (extended-linear Display-P3)
  //     -> every intermediate texture is WRITTEN and READ BACK in this same
  //        space, so each hop round-trips losslessly through a float texture.
  //   drawable     == CAMetalLayer.colorspace (Display-P3, SDR)
  //     -> the single linear->display conversion happens only at the final
  //        drawable write; the layer interprets the same space (no re-convert).
  //   mask                             (sRGB — a [0,1] selection field, not color)
  //     -> pinned independently so changing the color contract never perturbs
  //        the brush feather fed to CIBlendWithAlphaMask.

  /// Core Image working (math) space. Extended-linear so wide-gamut and
  /// out-of-sRGB chroma survive filtering instead of being gamut-clamped.
  static let workingColorSpace =
    CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()

  /// Encoding for every intermediate COLOR texture, used by BOTH the
  /// `ciContext.render(...)` that writes it and the `CIImage(mtlTexture:)` that
  /// reads it back. MUST equal `workingColorSpace` for a lossless round-trip.
  static let intermediateColorSpace =
    CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()

  /// Encoding of the final drawable write. MUST equal the CAMetalLayer's
  /// colorspace (Display-P3, SDR); a mismatch double-manages color.
  static let drawableColorSpace =
    CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

  /// The brush mask is a [0,1] selection field, not color content. Kept on a
  /// fixed space independent of the color contract so the feather is
  /// deterministic and unaffected by wide-gamut changes (behavior-preserving).
  static let maskColorSpace =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  /// Core Image working precision — half-float so the working buffer carries
  /// extended-range / wide-gamut values without 8-bit clamping or banding.
  static let workingFormat: CIFormat = .RGBAh

  /// Pixel format for intermediate COLOR textures (source / base / adjusted).
  /// Float so the extended-linear-Display-P3 round-trip stays lossless (and is
  /// EDR-ready). The mask texture stays `.rgba8Unorm` — a [0,1] field needs no float.
  static let colorTextureFormat: MTLPixelFormat = .rgba16Float

  /// Longest-side cap (in pixels) for the per-generation base/adjusted content
  /// bake, bounding the texture memory the bake holds for a gesture's duration.
  ///
  /// Numerically this matches the engine's editing-source value
  /// (`EditingStack.editingImageMaxPixelSize`, currently also 2560), but the two
  /// are not the same measurement: the engine caps the SHORT side, so its source
  /// is at least this large on the long side (a 4032×3024 photo loads at
  /// 3413×2560). Baking at this cap is therefore visually lossless only for
  /// square content; for other aspect ratios it resamples the fit-to-frame
  /// preview modestly below the editing source — acceptable because the preview
  /// is displayed fit-to-frame, but a real difference rather than an identity.
  /// If one value moves, move both — the modules can't enforce the relation at
  /// compile time.
  static let contentBakeMaxPixelSize: CGFloat = 2560

  /// Pixel format for the final drawable written by the editing canvas.
  ///
  /// Device builds use a 10-bit unorm drawable for Display-P3 SDR with less
  /// banding than an 8-bit surface. Simulator builds intentionally fall back to
  /// `.bgra8Unorm`: recent Simulator runtimes can create the view with
  /// `.bgr10a2Unorm` but present a black drawable, while the color math is still
  /// covered by the wide-gamut working and intermediate contracts above.
  #if targetEnvironment(simulator)
  static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm
  #else
  static let drawablePixelFormat: MTLPixelFormat = .bgr10a2Unorm
  #endif

  static func clippedToSourceAlpha(_ image: CIImage, source: CIImage) -> CIImage {
    let extent = image.extent
    guard extent.isEmpty == false, extent.isNull == false else {
      return image
    }

    let sourceAlphaMask = source
      .cropped(to: extent)
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]
      )
      .cropped(to: extent)

    let clearBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: extent)

    return image
      .applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [
          kCIInputBackgroundImageKey: clearBackground,
          kCIInputMaskImageKey: sourceAlphaMask,
        ]
      )
      .cropped(to: extent)
  }
}

extension CGPoint {
  func distance(to point: CGPoint) -> CGFloat {
    hypot(x - point.x, y - point.y)
  }

  func midpoint(to point: CGPoint) -> CGPoint {
    CGPoint(
      x: (x + point.x) / 2,
      y: (y + point.y) / 2
    )
  }

  func interpolate(to point: CGPoint, progress: CGFloat) -> CGPoint {
    CGPoint(
      x: x + (point.x - x) * progress,
      y: y + (point.y - y) * progress
    )
  }
}
