/// Selects how `SwiftUICropView` builds the image shown inside the crop surface.
public enum CropViewDisplayMode: Equatable {
  /// Uses the legacy crop interaction image stored in `EditingStack.Loaded`.
  ///
  /// This mode preserves the previous CG-backed crop display path. It is useful
  /// as a comparison point or for Photos-like crop surfaces that intentionally
  /// do not show the full edit stack during crop interaction.
  case cropInteractionImage

  /// Uses the viewport renderer to display the full current edit stack.
  ///
  /// This is the preferred mode when the user should choose the crop rectangle
  /// while seeing global filters and saved local adjustment layers.
  case renderedEditPreview
}
