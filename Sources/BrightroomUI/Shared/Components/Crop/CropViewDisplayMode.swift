/// Selects how `SwiftUICropView` builds the image shown inside the crop surface.
public enum CropViewDisplayMode: Equatable {
  /// Uses the lightweight viewport renderer for crop interaction.
  ///
  /// This mode intentionally skips saved local-adjustment layers and renders
  /// the interaction base through the Metal crop viewport instead of a legacy
  /// `UIImageView` surface.
  case cropInteractionImage

  /// Uses the viewport renderer to display the full current edit stack.
  ///
  /// This is the preferred mode when the user should choose the crop rectangle
  /// while seeing global filters and saved local adjustment layers.
  case renderedEditPreview
}
