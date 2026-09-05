import BrightroomEngine
import BrightroomParametric
import CoreImage
import CoreGraphics

enum EditingCanvasRenderImageFactory {
  static func makeRenderImages(
    loadedState: EditingStack.Loaded,
    canvasSize: CGSize,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    makeRenderImages(
      editingSourceImage: loadedState.editingSourceImage,
      effects: loadedState.currentEdit.effects,
      canvasSize: canvasSize,
      mode: mode
    )
  }

  static func makeRenderImages(
    document: CropViewDocumentSnapshot,
    canvasSize: CGSize,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    makeRenderImages(
      editingSourceImage: document.editingSourceImage,
      effects: document.effects,
      canvasSize: canvasSize,
      mode: mode
    )
  }

  private static func makeRenderImages(
    editingSourceImage: CIImage,
    effects: EffectPipeline,
    canvasSize: CGSize,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let previewSourceImage = editingSourceImage.removingExtentOffset()
    let sourceImage = displayOrientedImage(previewSourceImage, canvasSize: previewSourceImage.extent.size)
    let displaySourceExtent = sourceImage.extent
    guard displaySourceExtent.width > 0, displaySourceExtent.height > 0 else {
      return nil
    }

    let scaledSourceImage = scaledImage(sourceImage, canvasSize: canvasSize, canvasRect: canvasRect)
    let scaledPreviewSourceImage = scaledImage(
      previewSourceImage,
      canvasSize: canvasSize,
      canvasRect: canvasRect
    )

    let viewportSourceImage = scaledSourceImage.cropped(to: canvasRect)

    let baseImage: CIImage
    let adjustedImage: CIImage
    let renderEffect: EffectPipeline
    let usesPreparedBaseImage: Bool
    switch mode {
    case .viewportBase:
      baseImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
        effects
        .applyIgnoringFailure(to: viewportSourceImage, radiusReferenceExtent: canvasRect)
        .cropped(to: canvasRect),
        source: viewportSourceImage
      )
      adjustedImage = baseImage
      renderEffect = .init()
      usesPreparedBaseImage = false

    case let .localAdjustment(localEffect):
      // Evaluate the local-adjustment preview at the downsampled SOURCE
      // resolution and upscale the result, rather than applying the effect on
      // the full-canvas (`canvasSize`) image. On very large sources the
      // full-canvas blur intermediate exhausts memory (a 12000×12000 blur ROI
      // OOM-crashes); evaluating at the ~2560 editing source bounds it. The
      // blur radius is a fraction of the chain-entry extent
      // (radiusReferenceExtent = displaySourceExtent here), so applying it at
      // source resolution and upscaling reproduces the same fractional blur
      // the full-resolution export produces — preview and export stay
      // consistent (modulo the inherent downscale/upscale resampling
      // difference).
      let sourceBase = EditingCanvasImageProcessing.clippedToSourceAlpha(
        effects.applyIgnoringFailure(to: sourceImage, radiusReferenceExtent: displaySourceExtent),
        source: sourceImage
      )
      let sourceAdjusted = EditingCanvasImageProcessing.clippedToSourceAlpha(
        localEffect.applyIgnoringFailure(to: sourceBase, radiusReferenceExtent: displaySourceExtent),
        source: sourceImage
      )
      baseImage = scaledImage(sourceBase, canvasSize: canvasSize, canvasRect: canvasRect)
        .cropped(to: canvasRect)
      adjustedImage = scaledImage(sourceAdjusted, canvasSize: canvasSize, canvasRect: canvasRect)
        .cropped(to: canvasRect)
      renderEffect = localEffect
      // The local effect is baked into `adjustedImage`, so route it through the
      // prepared path — the same source-resolution composite ToolSurface and
      // the export renderer use — instead of the cached-source path, which
      // re-applies the effect at drawable/screen resolution and so renders a
      // lower-fidelity, foggier blur preview that diverges from the final
      // result.
      usesPreparedBaseImage = true

    case .renderedEditPreview:
      let previewImage = effects
        .applyIgnoringFailure(to: scaledPreviewSourceImage, radiusReferenceExtent: canvasRect)
        .cropped(to: canvasRect)
      let displayPreviewImage = displayOrientedImage(previewImage, canvasSize: canvasSize)
        .cropped(to: canvasRect)
      baseImage = displayPreviewImage
      adjustedImage = displayPreviewImage
      renderEffect = .init()
      usesPreparedBaseImage = true
    }

    return .init(
      source: viewportSourceImage,
      effects: effects,
      base: baseImage,
      adjusted: adjustedImage,
      localEffect: renderEffect,
      usesPreparedBaseImage: usesPreparedBaseImage
    )
  }

  static func makeCropOutputRenderImages(
    loadedState: EditingStack.Loaded,
    geometry: EditingCanvasCropOutputGeometry,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    makeCropOutputRenderImages(
      editingSourceImage: loadedState.editingSourceImage,
      effects: loadedState.currentEdit.effects,
      geometry: geometry,
      mode: mode
    )
  }

  static func makeCropOutputRenderImages(
    document: CropViewDocumentSnapshot,
    geometry: EditingCanvasCropOutputGeometry,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    makeCropOutputRenderImages(
      editingSourceImage: document.editingSourceImage,
      effects: document.effects,
      geometry: geometry,
      mode: mode
    )
  }

  private static func makeCropOutputRenderImages(
    editingSourceImage: CIImage,
    effects: EffectPipeline,
    geometry: EditingCanvasCropOutputGeometry,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    let canvasRect = geometry.outputBounds
    let sourceRect = CGRect(origin: .zero, size: geometry.sourceImageSize)
    let previewSourceImage = editingSourceImage.removingExtentOffset()
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

    let baseImage: CIImage
    let adjustedImage: CIImage
    let renderEffect: EffectPipeline
    switch mode {
    case .viewportBase:
      // The input is the CROPPED output, but the radius basis stays the
      // source-domain chain entry: the document applies global effects
      // pre-crop, so resolving against the crop rect would diverge from the
      // export the moment a proportional radius appears in `effects`.
      baseImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
        effects.applyIgnoringFailure(to: cropOutputSourceImage, radiusReferenceExtent: sourceRect)
          .cropped(to: canvasRect),
        source: cropOutputSourceImage
      )
      adjustedImage = baseImage
      renderEffect = .init()

    case let .localAdjustment(localEffect):
      // Evaluate effects + the local effect at the native (downsampled) source
      // resolution BEFORE upscaling to the crop-output source size, so a huge
      // source (`geometry.sourceImageSize == crop.imageSize`) never
      // materializes a full-resolution blur intermediate (OOM). The blur radius
      // is a fraction of the chain-entry extent at this evaluation scale
      // (the display source extent), so it upscales to the same fractional
      // blur the full-resolution export produces.
      let displayFiltered = EditingCanvasImageProcessing.clippedToSourceAlpha(
        effects.applyIgnoringFailure(
          to: displaySourceImage,
          radiusReferenceExtent: displaySourceImage.extent
        ),
        source: displaySourceImage
      )
      let displayAdjusted = EditingCanvasImageProcessing.clippedToSourceAlpha(
        localEffect.applyIgnoringFailure(
          to: displayFiltered,
          radiusReferenceExtent: displaySourceImage.extent
        ),
        source: displaySourceImage
      )
      let filteredSourceImage = scaledImage(
        displayFiltered,
        canvasSize: geometry.sourceImageSize,
        canvasRect: sourceRect
      )
      let adjustedSourceImage = scaledImage(
        displayAdjusted,
        canvasSize: geometry.sourceImageSize,
        canvasRect: sourceRect
      )

      baseImage = cropOutputImage(filteredSourceImage, geometry: geometry)
        .cropped(to: canvasRect)
      adjustedImage = cropOutputImage(adjustedSourceImage, geometry: geometry)
        .cropped(to: canvasRect)
      renderEffect = localEffect

    case .renderedEditPreview:
      let filteredSourceImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
        effects
          .applyIgnoringFailure(to: sourceImage, radiusReferenceExtent: sourceRect)
          .cropped(to: sourceExtent),
        source: sourceImage
      )
      let previewImage = filteredSourceImage
        .cropped(to: sourceExtent)
      let displayPreviewImage = cropOutputImage(previewImage, geometry: geometry)
        .cropped(to: canvasRect)
      baseImage = displayPreviewImage
      adjustedImage = displayPreviewImage
      renderEffect = .init()
    }

    return .init(
      source: cropOutputSourceImage,
      effects: effects,
      base: baseImage,
      adjusted: adjustedImage,
      localEffect: renderEffect,
      usesPreparedBaseImage: true
    )
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
      .transformed(by: geometry.sourceToOutputTransform)
      .cropped(to: geometry.outputBounds)
  }

  private static func displayOrientedImage(
    _ image: CIImage,
    canvasSize: CGSize
  ) -> CIImage {
    image
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: canvasSize.height))
      .removingExtentOffset()
      .cropped(to: CGRect(origin: .zero, size: canvasSize))
  }
}
