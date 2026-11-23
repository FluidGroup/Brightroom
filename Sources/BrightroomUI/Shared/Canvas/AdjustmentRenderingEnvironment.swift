import BrightroomParametric
import SwiftUI

private struct AdjustmentRenderingKey: EnvironmentKey {

  static let defaultValue = AdjustmentRendering.standard
}

extension EnvironmentValues {

  var adjustmentRendering: AdjustmentRendering {
    get { self[AdjustmentRenderingKey.self] }
    set { self[AdjustmentRenderingKey.self] = newValue }
  }
}

extension View {

  /// Selects preview calculations for ImageEditor and ImageEditorCanvas.
  /// Pass the same selection to document.render for matching exports.
  public func adjustmentRendering(_ rendering: AdjustmentRendering) -> some View {
    environment(\.adjustmentRendering, rendering)
  }
}
