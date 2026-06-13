import CoreGraphics

@testable import BrightroomEngine
@testable import BrightroomParametric

extension BrightRoomImageRenderer.Edit {

  /// Test helper mirroring how `EditingStack.makeRenderer` lowers an edit:
  /// builds the renderer's parametric document from a crop plus ordered global
  /// effects and local adjustments, through the production bridge.
  ///
  /// The resulting document order is `[effects, localAdjustments…, crop]`, which
  /// matches the canonical arrangement the old `(croppingRect, operations)`
  /// construction produced.
  static func make(
    crop: EditingCrop,
    effects: EffectPipeline = .init(),
    localAdjustments: [LocalAdjustmentFeature] = []
  ) -> Self {
    var edit = EditingStack.Edit(crop: crop)
    edit.effects = effects
    edit.localAdjustments = localAdjustments
    return .init(document: edit.makeEditingDocument(orientedImageSize: crop.imageSize))
  }
}
