import BrightroomEngine
import CoreImage
import CoreGraphics

enum EditingCanvasRenderImageFactory {
  static func makeRenderImages(
    loadedState: EditingStack.Loaded,
    canvasSize: CGSize,
    displayedContentRect: CGRect? = nil,
    mode: EditingCanvasMode
  ) -> EditingCanvasRenderImages? {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let renderBounds = sanitizedRenderBounds(
      displayedContentRect,
      canvasRect: canvasRect
    )
    let previewSourceImage = loadedState.editingSourceImage.removingExtentOffset()
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

    let viewportSourceImage = scaledSourceImage.cropped(to: renderBounds)

    let baseImage: CIImage
    let adjustedImage: CIImage
    let renderEffect: EditingStack.Edit.LocalAdjustmentEffect
    let usesPreparedBaseImage: Bool
    switch mode {
    case .viewportBase:
      baseImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
        loadedState.currentEdit.filters
        .apply(to: viewportSourceImage)
        .cropped(to: renderBounds),
        source: viewportSourceImage
      )
      adjustedImage = baseImage
      renderEffect = .gaussianBlur(radius: 0)
      usesPreparedBaseImage = false

    case let .localAdjustment(localEffect):
      baseImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
        loadedState.currentEdit.filters
        .apply(to: viewportSourceImage)
        .cropped(to: renderBounds),
        source: viewportSourceImage
      )
      if localEffect.usesEditingCanvasShaderCompositeExposure {
        adjustedImage = baseImage
      } else {
        adjustedImage = EditingCanvasImageProcessing.clippedToSourceAlpha(
          localEffect.apply(to: baseImage, previewScale: 1),
          source: viewportSourceImage
        )
      }
      renderEffect = localEffect
      usesPreparedBaseImage = false

    case .renderedEditPreview, .preview:
      // The compatibility local-adjustment path rasterizes saved masks in the
      // image's zero-origin coordinate space. Keep that full-image pipeline
      // intact, then clip to the displayed crop as the final step.
      let previewImage = loadedState.currentEdit
        .makePreviewImage(from: scaledPreviewSourceImage, purpose: .editing)
        .cropped(to: canvasRect)
      let displayPreviewImage = displayOrientedImage(previewImage, canvasSize: canvasSize)
        .cropped(to: renderBounds)
      baseImage = displayPreviewImage
      adjustedImage = displayPreviewImage
      renderEffect = .gaussianBlur(radius: 0)
      usesPreparedBaseImage = true
    }

    return .init(
      source: viewportSourceImage,
      filters: loadedState.currentEdit.filters,
      base: baseImage,
      adjusted: adjustedImage,
      localEffect: renderEffect,
      usesPreparedBaseImage: usesPreparedBaseImage
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

  private static func sanitizedRenderBounds(
    _ rect: CGRect?,
    canvasRect: CGRect
  ) -> CGRect {
    guard let rect else {
      return canvasRect
    }

    let finiteRect = rect.standardized
    guard
      finiteRect.isNull == false,
      finiteRect.isInfinite == false,
      finiteRect.width > 0,
      finiteRect.height > 0
    else {
      return canvasRect
    }

    let intersection = finiteRect.intersection(canvasRect)
    guard intersection.isNull == false, intersection.isEmpty == false else {
      return canvasRect
    }

    return intersection
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

extension EditingStack.Edit.LocalAdjustmentEffect {
  enum EditingCanvasEffectIdentity: Equatable {
    case blur
    case exposure
  }

  var usesEditingCanvasShaderCompositeExposure: Bool {
    switch self {
    case .gaussianBlur:
      return false
    case .exposure:
      return true
    }
  }

  var editingCanvasEffectIdentity: EditingCanvasEffectIdentity {
    switch self {
    case .gaussianBlur:
      return .blur
    case .exposure:
      return .exposure
    }
  }
}
