import BrightroomParametric

extension ImageEditorFeature.Effects {

  /// The global effects as the canvas factories take them: nil when no effect
  /// is present, so the canvas can sample its cached source instead of
  /// evaluating an identity graph.
  var canvasEffect: AnyImageEffect? {
    self == Self() ? nil : AnyImageEffect(self)
  }
}

extension ImageEditorFeature {

  /// The effect the canvas draws after the crop (the vignette), or nil.
  ///
  /// It is drawn over the crop frame of each displayed frame instead of
  /// being part of the render images, so changing it never rebuilds them.
  var canvasPostCropEffect: AnyImageEffect? {
    vignette.map { AnyImageEffect($0) }
  }
}
