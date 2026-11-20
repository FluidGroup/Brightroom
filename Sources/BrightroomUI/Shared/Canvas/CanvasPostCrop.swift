import BrightroomParametric
import CoreGraphics

/// The post-crop pass of one displayed frame: the effect the feature
/// evaluates after its final crop, and where the crop output lies on the
/// canvas. See `EditingCanvasRenderer.setPostCrop(effect:frame:chainEntry:)`.
struct CanvasPostCrop: Equatable {
  let effect: AnyImageEffect
  /// The crop output on the canvas, in canvas points.
  let frame: CGRect
  /// The whole source in the surface's content coordinates.
  let chainEntry: CGRect

  /// The pass on a tool surface, whose content is the crop output: the
  /// frame is the content's bounds where the viewport places them.
  init?(
    effect: AnyImageEffect?,
    geometry: EditingCanvasCropOutputGeometry,
    viewport: CanvasViewport
  ) {
    guard let effect else { return nil }
    self.effect = effect
    self.frame = geometry.outputBounds.applying(viewport.contentToCanvasTransform)
    self.chainEntry = CGRect(origin: .zero, size: geometry.sourceImageSize)
      .applying(geometry.inputToOutputTransform)
  }

  /// The pass on the crop surface, whose content is the source: the crop
  /// output is what the crop guide frames.
  ///
  /// - Parameter guideFrame: The crop guide on the canvas, sampled with the
  ///   viewport of the same frame.
  init?(effect: AnyImageEffect?, guideFrame: CGRect, imageSize: CGSize) {
    guard let effect else { return nil }
    self.effect = effect
    self.frame = guideFrame
    self.chainEntry = CGRect(origin: .zero, size: imageSize)
  }
}
