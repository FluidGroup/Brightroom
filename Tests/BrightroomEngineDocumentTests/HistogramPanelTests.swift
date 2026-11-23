#if os(macOS)

import Foundation
import Testing

@testable import BrightroomUI

/// The macOS histogram panel's text that needs no window: the readout of the
/// pixel under the pointer, and the clipping VoiceOver reads.
@MainActor
struct HistogramPanelTests {

  private static let color = OutputAnalysis.Color(red: 12, green: 128, blue: 255)

  @Test func `The readout shows the values of the pixel under the pointer`() {
    let format = ImageEditor.LocalizedStrings().pointerColor

    #expect(HistogramPanel.Readout.text(for: Self.color, format: format) == "R: 12   G: 128   B: 255")
  }

  @Test func `The readout shows dashes without a pixel under the pointer`() {
    let format = ImageEditor.LocalizedStrings().pointerColor

    #expect(HistogramPanel.Readout.text(for: nil, format: format) == "R: ---   G: ---   B: ---")
  }

  @Test func `A translation can reorder the readout's values`() {
    #expect(HistogramPanel.Readout.text(for: Self.color, format: "%3$@ %2$@ %1$@") == "255 128 12")
  }

  @Test func `The clipping reads the shadows' share first and the highlights' second`() {
    let histogram = OutputAnalysis.Histogram(
      red: [],
      green: [],
      blue: [],
      pixelCount: 1000,
      shadowClipping: 0.004,
      highlightClipping: 0.021
    )
    let shadows = 0.004.formatted(.percent.precision(.fractionLength(1)))
    let highlights = 0.021.formatted(.percent.precision(.fractionLength(1)))
    let format = ImageEditor.LocalizedStrings().histogramClipping

    #expect(
      HistogramPanel.Chart.clippingDescription(of: histogram, format: format)
        == "Shadows clipped \(shadows), highlights clipped \(highlights)"
    )
    #expect(
      HistogramPanel.Chart.clippingDescription(of: histogram, format: "%2$@ | %1$@")
        == "\(highlights) | \(shadows)",
      "A translation can reorder them."
    )
  }
}

#endif
