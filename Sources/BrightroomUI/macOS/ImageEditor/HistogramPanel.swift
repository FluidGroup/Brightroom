#if os(macOS)
import SwiftUI

/// The panel over the image column's top leading corner: a histogram of what
/// the canvas shows, over the 8-bit Display P3 values of the pixel under the
/// pointer.
///
/// The chart and the readout are views of their own, so an analysis redraws
/// the chart alone and a pointer move updates the readout alone. VoiceOver
/// reads the panel as one element, the histogram with its clipping; the
/// readout follows the pointer and is left out.
struct HistogramPanel: View {

  private let model: ImageEditorModel
  private let localizedStrings: ImageEditor.LocalizedStrings

  @Environment(\.pixelLength) private var pixelLength

  init(model: ImageEditorModel, localizedStrings: ImageEditor.LocalizedStrings) {
    self.model = model
    self.localizedStrings = localizedStrings
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    VStack(spacing: 0) {
      Chart(model: model, localizedStrings: localizedStrings)

      Readout(model: model, format: localizedStrings.pointerColor)
        .frame(maxHeight: .infinity)
    }
    .frame(width: 220, height: 112)
    .background(.regularMaterial, in: shape)
    .overlay {
      shape.strokeBorder(.separator, lineWidth: pixelLength)
    }
    .accessibilityElement(children: .combine)
  }
}

extension HistogramPanel {

  /// The red, green and blue levels of the latest analysis as filled areas,
  /// added together where they overlap. Empty until the first analysis
  /// arrives.
  struct Chart: View {

    /// Pure primaries rather than the system's red, green and blue, so the
    /// three channels add up to a neutral gray where they overlap.
    private static let channelColors: [Color] = [
      Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 0.6),
      Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 0.6),
      Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 0.6),
    ]

    let model: ImageEditorModel
    let localizedStrings: ImageEditor.LocalizedStrings

    var body: some View {
      let histogram = model.analysis?.histogram
      let levels = histogram?.levels()
      let clipping = histogram.map {
        Self.clippingDescription(of: $0, format: localizedStrings.histogramClipping)
      }

      Canvas { context, size in
        guard let levels else {
          return
        }

        // Clear of the panel's rounded corners.
        let plot = CGRect(x: 8, y: 8, width: size.width - 16, height: size.height - 8)
        context.blendMode = .plusLighter
        for (channel, color) in zip([levels.red, levels.green, levels.blue], Self.channelColors) {
          context.fill(Self.area(channel, in: plot), with: .color(color))
        }
      }
      .frame(width: 220, height: 88)
      .accessibilityElement()
      .accessibilityLabel(localizedStrings.histogram)
      .accessibilityValue(clipping ?? "")
    }

    /// The share of pixels clipped to black and to white, in the positions
    /// `format` gives them (`LocalizedStrings.histogramClipping`).
    static func clippingDescription(of histogram: OutputAnalysis.Histogram, format: String) -> String {
      String(
        format: format,
        histogram.shadowClipping.formatted(.percent.precision(.fractionLength(1))),
        histogram.highlightClipping.formatted(.percent.precision(.fractionLength(1)))
      )
    }

    /// The area under `levels`, the first at the left edge and the last at
    /// the right edge of `rect`.
    private static func area(_ levels: [Double], in rect: CGRect) -> Path {
      Path { path in
        guard levels.count > 1 else {
          return
        }

        let step = rect.width / CGFloat(levels.count - 1)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (index, level) in levels.enumerated() {
          path.addLine(
            to: CGPoint(x: rect.minX + step * CGFloat(index), y: rect.maxY - rect.height * level)
          )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
      }
    }
  }

  /// The values of the pixel under the pointer, or dashes off the image and
  /// before the first analysis.
  struct Readout: View {

    let model: ImageEditorModel
    let format: String

    var body: some View {
      Text(Self.text(for: model.pointerColor, format: format))
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    /// The red, green and blue values of `color`, or "---" for each without
    /// one, in the positions `format` gives them
    /// (`LocalizedStrings.pointerColor`).
    static func text(for color: OutputAnalysis.Color?, format: String) -> String {
      guard let color else {
        return String(format: format, "---", "---", "---")
      }
      return String(
        format: format,
        Int(color.red).formatted(),
        Int(color.green).formatted(),
        Int(color.blue).formatted()
      )
    }
  }
}

/// The badge at the top centre of the image column: "Original" while the
/// canvas shows the original, from Show Original or a held M; otherwise,
/// while the gray point is on, the hint to click a neutral area, or for a
/// moment after a rejected click, why it was rejected. VoiceOver announces
/// each message as it shows. It takes no clicks.
struct StatusBadge: View {

  private let model: ImageEditorModel
  private let localizedStrings: ImageEditor.LocalizedStrings

  init(model: ImageEditorModel, localizedStrings: ImageEditor.LocalizedStrings) {
    self.model = model
    self.localizedStrings = localizedStrings
  }

  var body: some View {
    if let message {
      Text(message)
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 12)
        .allowsHitTesting(false)
        // The badge can stay while its message changes, so each message is
        // announced, not only the first.
        .onChange(of: message, initial: true) { _, message in
          AccessibilityNotification.Announcement(message).post()
        }
    }
  }

  private var message: String? {
    if model.showsOriginal {
      return localizedStrings.showingOriginal
    }
    switch model.grayPointSampling {
    case .off:
      return nil
    case .waiting, .solving:
      return localizedStrings.grayPointHint
    case .rejected:
      return localizedStrings.grayPointRejected
    }
  }
}
#endif
