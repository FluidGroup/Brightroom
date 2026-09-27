//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.


import BrightroomParametric

extension ImageEditor {

  /// A global adjustment parameter editable in ImageEditor's Adjust mode.
  ///
  /// Each parameter maps a -100...100 (or 0...100 for zero-based ranges) slider
  /// value onto the corresponding member of `ImageEditorFeature.Effects`, which
  /// is evaluated before the local blur and the final crop.
  enum Adjustment: CaseIterable, Identifiable, Equatable {
    case exposure
    case brightness
    case contrast
    case saturation
    case warmth
    case highlights
    case shadows
    case gaussianBlur
    case vignette

    var id: Self { self }

    var title: String {
      switch self {
      case .exposure: return "Exposure"
      case .brightness: return "Brightness"
      case .contrast: return "Contrast"
      case .saturation: return "Saturation"
      case .warmth: return "Warmth"
      case .highlights: return "Highlights"
      case .shadows: return "Shadows"
      case .gaussianBlur: return "Blur"
      case .vignette: return "Vignette"
      }
    }

    var systemImageName: String {
      switch self {
      case .exposure: return "plusminus.circle"
      case .brightness: return "sun.max"
      case .contrast: return "circle.lefthalf.filled"
      case .saturation: return "drop"
      case .warmth: return "thermometer.medium"
      case .highlights: return "circle.tophalf.filled"
      case .shadows: return "circle.bottomhalf.filled"
      case .gaussianBlur: return "drop.fill"
      case .vignette: return "circle.dashed.inset.filled"
      }
    }

    var accessibilityIdentifier: String {
      "image-editor.adjust.\(String(describing: self))"
    }

    /// Zero-based parameters only strengthen in one direction.
    private var isZeroBased: Bool {
      switch self {
      case .highlights, .gaussianBlur, .vignette:
        return true
      case .exposure, .brightness, .contrast, .saturation, .warmth, .shadows:
        return false
      }
    }

    var sliderRange: ClosedRange<Double> {
      isZeroBased ? 0...100 : -100...100
    }

    /// The maximum effect value the slider's positive end maps to.
    ///
    /// These mirror the slider maxima of Brightroom 5; the parametric features
    /// carry unbounded values, so the slider scale is an ImageEditor policy.
    private var maximumFilterValue: Double {
      switch self {
      case .exposure: return 1.8
      case .brightness: return 0.2
      case .contrast: return 0.18
      case .saturation: return 1
      case .warmth: return 3000
      case .highlights: return 1
      case .shadows: return 1
      case .gaussianBlur: return 100
      case .vignette: return 2
      }
    }

    /// The current slider value for this parameter.
    func sliderValue(in effects: ImageEditorFeature.Effects) -> Double {
      let filterValue: Double
      switch self {
      case .exposure:
        filterValue = effects.exposure?.ev ?? 0
      case .brightness:
        filterValue = effects.brightness?.value ?? 0
      case .contrast:
        filterValue = effects.contrast?.value ?? 0
      case .saturation:
        filterValue = effects.saturation?.value ?? 0
      case .warmth:
        filterValue = effects.whiteBalance?.temperature ?? 0
      case .highlights:
        filterValue = effects.highlights?.value ?? 0
      case .shadows:
        filterValue = effects.shadows?.value ?? 0
      case .gaussianBlur:
        filterValue = effects.gaussianBlur?.proportionalValue ?? 0
      case .vignette:
        filterValue = effects.vignette?.value ?? 0
      }

      guard maximumFilterValue != 0 else {
        return 0
      }

      return (filterValue / maximumFilterValue * 100).rounded()
    }

    /// Writes a slider value into the global effects.
    ///
    /// An existing effect is updated in place, so its parameters the slider
    /// does not control (such as `WhiteBalanceFeature.tint`) are kept. A neutral
    /// value removes the effect, including those parameters, so untouched
    /// parameters stay absent.
    func apply(sliderValue: Double, to effects: inout ImageEditorFeature.Effects) {
      let clamped = min(
        max(sliderValue, sliderRange.lowerBound),
        sliderRange.upperBound
      )
      let filterValue = clamped / 100 * maximumFilterValue
      let value: Double? = abs(clamped) < 0.5 ? nil : filterValue

      switch self {
      case .exposure:
        Self.upsert(
          value,
          into: &effects.exposure,
          make: { ExposureFeature(ev: $0) },
          update: { $0.ev = $1 }
        )
      case .brightness:
        Self.upsert(
          value,
          into: &effects.brightness,
          make: { BrightnessFeature(value: $0) },
          update: { $0.value = $1 }
        )
      case .contrast:
        Self.upsert(
          value,
          into: &effects.contrast,
          make: { ContrastFeature(value: $0) },
          update: { $0.value = $1 }
        )
      case .saturation:
        Self.upsert(
          value,
          into: &effects.saturation,
          make: { SaturationFeature(value: $0) },
          update: { $0.value = $1 }
        )
      case .warmth:
        Self.upsert(
          value,
          into: &effects.whiteBalance,
          make: { WhiteBalanceFeature(temperature: $0) },
          update: { $0.temperature = $1 }
        )
      case .highlights:
        Self.upsert(
          value,
          into: &effects.highlights,
          make: { HighlightsFeature(value: $0) },
          update: { $0.value = $1 }
        )
      case .shadows:
        Self.upsert(
          value,
          into: &effects.shadows,
          make: { ShadowsFeature(value: $0) },
          update: { $0.value = $1 }
        )
      case .gaussianBlur:
        Self.upsert(
          value,
          into: &effects.gaussianBlur,
          make: { GaussianBlurFeature(radius: .proportional($0)) },
          update: { $0.radius = .proportional($1) }
        )
      case .vignette:
        Self.upsert(
          value,
          into: &effects.vignette,
          make: { VignetteFeature(value: $0) },
          update: { $0.value = $1 }
        )
      }
    }

    /// Updates an existing effect in place (keeping the parameters the slider
    /// does not control), creates a missing one, or removes it when the slider
    /// returns to neutral.
    private static func upsert<Member>(
      _ value: Double?,
      into member: inout Member?,
      make: (Double) -> Member,
      update: (inout Member, Double) -> Void
    ) {
      guard let value else {
        member = nil
        return
      }

      if var existing = member {
        update(&existing, value)
        member = existing
      } else {
        member = make(value)
      }
    }
  }
}

extension GaussianBlurFeature {

  /// The ImageEditor adjustment-slider value when this blur was authored by the
  /// global Adjust tool.
  ///
  /// Absolute-radius blurs do not have enough context here to map back onto a
  /// source-relative slider value, so the ImageEditor control treats them as
  /// neutral and preserves them unless the user edits Blur.
  fileprivate var proportionalValue: Double? {
    switch radius {
    case .proportional(let value):
      return value
    case .absolute:
      return nil
    }
  }
}
