import CoreGraphics

@testable import BrightroomEngine
@testable import BrightroomParametric

extension CropFeature {

  /// Test helper mirroring the old `EditingCrop(imageSize:cropRect:rotation:)`:
  /// builds a crop from a y-down display rect through the shared engine snapper
  /// (`CropFeature(displayCropRect:imageSize:…)`), so tests author crops in the
  /// same top-left-origin space they used before the parametric migration.
  static func test(
    imageSize: CGSize,
    cropRect: CGRect? = nil,
    rotation: QuarterTurn = .zero,
    straighten: Double = 0
  ) -> CropFeature {
    CropFeature(
      displayCropRect: cropRect ?? CGRect(origin: .zero, size: imageSize),
      imageSize: imageSize,
      rotation: rotation,
      straighten: straighten
    )
  }
}

extension EditingStack.Edit {

  /// Test helper: the canonical default edit for an image of `imageSize`,
  /// optionally with a non-default final crop rect (y-down display space).
  static func test(imageSize: CGSize, cropRect: CGRect? = nil) -> Self {
    .init(
      crop: CropFeature.test(imageSize: imageSize, cropRect: cropRect),
      orientedImageSize: imageSize
    )
  }
}

extension BrightRoomImageRenderer.Edit {

  /// Test helper mirroring how `EditingStack.makeRenderer` lowers an edit:
  /// builds the renderer's parametric document from a crop plus ordered global
  /// effects and local adjustments, through the production bridge.
  ///
  /// The resulting document order is `[effects, localAdjustments…, crop]`, which
  /// matches the canonical arrangement the old `(croppingRect, operations)`
  /// construction produced.
  static func make(
    crop: CropFeature,
    orientedImageSize: CGSize,
    effects: EffectPipeline = .init(),
    localAdjustments: [LocalAdjustmentFeature] = []
  ) -> Self {
    var edit = EditingStack.Edit(crop: crop, orientedImageSize: orientedImageSize)
    edit.effects = effects
    edit.localAdjustments = localAdjustments
    return .init(document: edit.makeEditingDocument(orientedImageSize: orientedImageSize))
  }
}
