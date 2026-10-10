import BrightroomEngine
import BrightroomParametric
import CoreImage
import CoreGraphics

/// Builds the content-space image recipes an editing canvas renders.
///
/// The document is authored in the full-resolution oriented source domain.
/// These factories evaluate the downsampled editing source and scale it up to
/// that domain (or to the crop output), stating the chain-entry extent for
/// every effect they apply.
enum EditingCanvasRenderImageFactory {

  /// Render images for a canvas sized to the oriented source.
  ///
  /// - Parameters:
  ///   - editingSourceImage: The oriented, downsampled editing source.
  ///   - effects: The global effects, or nil when there are none.
  ///   - canvasSize: The oriented source size the canvas displays.
  ///   - mode: Whether a local adjustment is composited.
  static func makeRenderImages(
    editingSourceImage: CIImage,
    effects: AnyImageEffect?,
    canvasSize: CGSize,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let previewSourceImage = ImageGeometry.removingExtentOffset(editingSourceImage)
    let sourceImage = displayOrientedImage(previewSourceImage, canvasSize: previewSourceImage.extent.size)
    let displaySourceExtent = sourceImage.extent
    guard displaySourceExtent.width > 0, displaySourceExtent.height > 0 else {
      return nil
    }

    let scaledSourceImage = scaledImage(sourceImage, canvasSize: canvasSize, canvasRect: canvasRect)

    let viewportSourceImage = scaledSourceImage.cropped(to: canvasRect)

    // Evaluate the global effects (and the local effect) at the downsampled
    // editing source resolution and upscale the result, rather than applying
    // them to the full-canvas (`canvasSize`) image. On very large sources the
    // full-canvas intermediate exhausts memory (a 12000×12000 blur ROI
    // OOM-crashes); evaluating at the ~2560 editing source bounds it. A
    // proportional radius is a fraction of the chain-entry extent
    // (chainEntryExtent = displaySourceExtent here), so applying it at source
    // resolution and upscaling reproduces the same fractional radius the
    // full-resolution export produces — preview and export stay consistent
    // (modulo the inherent downscale/upscale resampling difference).
    let sourceBase = EditingCanvasImageProcessing.clippedToSourceAlpha(
      applying(effects, to: sourceImage, chainEntryExtent: displaySourceExtent),
      source: sourceImage
    )

    let baseImage = scaledImage(sourceBase, canvasSize: canvasSize, canvasRect: canvasRect)
      .cropped(to: canvasRect)

    let adjustedImage: CIImage
    let hasLocalEffect: Bool
    let usesPreparedBaseImage: Bool
    switch mode {
    case .viewportBase:
      adjustedImage = baseImage
      hasLocalEffect = false
      usesPreparedBaseImage = false

    case let .localAdjustment(localEffect):
      let sourceAdjusted = EditingCanvasImageProcessing.clippedToSourceAlpha(
        localEffect.applyIgnoringFailure(to: sourceBase, chainEntryExtent: displaySourceExtent),
        source: sourceImage
      )
      adjustedImage = scaledImage(sourceAdjusted, canvasSize: canvasSize, canvasRect: canvasRect)
        .cropped(to: canvasRect)
      hasLocalEffect = true
      // The local effect is baked into `adjustedImage`, so route it through the
      // prepared path — the same source-resolution composite ToolSurface and
      // the export renderer use — instead of the cached-source path, which
      // re-applies the effect at drawable/screen resolution and so renders a
      // lower-fidelity, foggier blur preview that diverges from the final
      // result.
      usesPreparedBaseImage = true
    }

    return .init(
      source: viewportSourceImage,
      base: baseImage,
      adjusted: adjustedImage,
      hasGlobalEffects: effects != nil,
      hasLocalEffect: hasLocalEffect,
      usesPreparedBaseImage: usesPreparedBaseImage
    )
  }

  /// Render images for a canvas sized to the crop output.
  ///
  /// - Parameters:
  ///   - editingSourceImage: The oriented, downsampled editing source.
  ///   - effects: The global effects, or nil when there are none.
  ///   - geometry: Maps the oriented source to the crop output.
  ///   - mode: Whether a local adjustment is composited.
  static func makeCropOutputRenderImages(
    editingSourceImage: CIImage,
    effects: AnyImageEffect?,
    geometry: EditingCanvasCropOutputGeometry,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    let canvasRect = geometry.outputBounds
    let sourceRect = CGRect(origin: .zero, size: geometry.sourceImageSize)
    let previewSourceImage = ImageGeometry.removingExtentOffset(editingSourceImage)
    let displaySourceImage = displayOrientedImage(previewSourceImage, canvasSize: previewSourceImage.extent.size)
    let sourceImage = scaledImage(
      displaySourceImage,
      canvasSize: geometry.sourceImageSize,
      canvasRect: sourceRect
    )
    let sourceExtent = sourceImage.extent
    guard sourceExtent.width > 0, sourceExtent.height > 0 else {
      return nil
    }

    let cropOutputSourceImage = cropOutputImage(sourceImage, geometry: geometry)
      .cropped(to: canvasRect)

    // The document evaluates its effects before the final crop, so evaluate
    // them (and the local effect) on the whole oriented source, then crop. An
    // effect that reads its input extent (a preset's vignette) or the pixels
    // beyond the crop edge (a sharpen) then sees what the export sees. Evaluate at the
    // native (downsampled) source resolution BEFORE upscaling to the
    // crop-output source size, so a huge source
    // (`geometry.sourceImageSize == crop.imageSize`) never materializes a
    // full-resolution intermediate (OOM). A proportional radius is a fraction
    // of the chain-entry extent at this evaluation scale (the display source
    // extent), so it upscales to the same fractional radius the
    // full-resolution export produces.
    let displayFiltered = EditingCanvasImageProcessing.clippedToSourceAlpha(
      applying(
        effects,
        to: displaySourceImage,
        chainEntryExtent: displaySourceImage.extent
      ),
      source: displaySourceImage
    )
    let filteredSourceImage = scaledImage(
      displayFiltered,
      canvasSize: geometry.sourceImageSize,
      canvasRect: sourceRect
    )

    let baseImage = cropOutputImage(filteredSourceImage, geometry: geometry)
      .cropped(to: canvasRect)

    let adjustedImage: CIImage
    let hasLocalEffect: Bool
    switch mode {
    case .viewportBase:
      adjustedImage = baseImage
      hasLocalEffect = false

    case let .localAdjustment(localEffect):
      let displayAdjusted = EditingCanvasImageProcessing.clippedToSourceAlpha(
        localEffect.applyIgnoringFailure(
          to: displayFiltered,
          chainEntryExtent: displaySourceImage.extent
        ),
        source: displaySourceImage
      )
      let adjustedSourceImage = scaledImage(
        displayAdjusted,
        canvasSize: geometry.sourceImageSize,
        canvasRect: sourceRect
      )

      adjustedImage = cropOutputImage(adjustedSourceImage, geometry: geometry)
        .cropped(to: canvasRect)
      hasLocalEffect = true
    }

    return .init(
      source: cropOutputSourceImage,
      base: baseImage,
      adjusted: adjustedImage,
      hasGlobalEffects: effects != nil,
      hasLocalEffect: hasLocalEffect,
      usesPreparedBaseImage: true
    )
  }

  /// Applies the global effects, or returns `image` when there are none.
  private static func applying(
    _ effects: AnyImageEffect?,
    to image: CIImage,
    chainEntryExtent: CGRect
  ) -> CIImage {
    guard let effects else {
      return image
    }
    return effects.applyIgnoringFailure(to: image, chainEntryExtent: chainEntryExtent)
  }

  private static func scaledImage(
    _ image: CIImage,
    canvasSize: CGSize,
    canvasRect: CGRect
  ) -> CIImage {
    let extent = image.extent
    if abs(extent.width - canvasSize.width) > 0.5
      || abs(extent.height - canvasSize.height) > 0.5
    {
      return image
        .transformed(
          by: CGAffineTransform(
            scaleX: canvasSize.width / extent.width,
            y: canvasSize.height / extent.height
          )
        )
        .cropped(to: canvasRect)
    } else {
      return image.cropped(to: canvasRect)
    }
  }

  private static func cropOutputImage(
    _ image: CIImage,
    geometry: EditingCanvasCropOutputGeometry
  ) -> CIImage {
    image
      .transformed(by: geometry.inputToOutputTransform)
      .cropped(to: geometry.outputBounds)
  }

  private static func displayOrientedImage(
    _ image: CIImage,
    canvasSize: CGSize
  ) -> CIImage {
    let flipped = image
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: canvasSize.height))
    return ImageGeometry.removingExtentOffset(flipped)
      .cropped(to: CGRect(origin: .zero, size: canvasSize))
  }
}
