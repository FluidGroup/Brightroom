import BrightroomParametric

/// Inputs that determine the output of
/// `EditingCanvasRenderImageFactory.makeCropOutputRenderImages`. The source
/// image is compared by identity; `EditingCanvasSource` stores it as an
/// immutable property, so a new editing source always produces a new
/// instance. Strokes are not part of the key: committing one keeps the
/// render images and their bakes.
struct CanvasRenderInputKey: Equatable {
  var adjustmentIdentity: AdjustmentRendering.Identity = AdjustmentRendering.standard.identity
  var sourceImage: ObjectIdentifier
  var effects: ImageEditorFeature.Effects
  var geometry: EditingCanvasCropOutputGeometry
  var mode: EditingCanvasMode
}
