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

/// A global adjustment parameter editable in PhotosCrop's Adjust mode.
///
/// Each parameter maps a -100...100 (or 0...100 for zero-based ranges) slider
/// value onto the corresponding member of `PhotosCropDocument.Effects`, which
/// is evaluated before the blur mask and the final crop.
enum PhotosCropAdjustmentParameter: CaseIterable, Identifiable, Equatable {
  case exposure
  case brightness
  case contrast
  case saturation
  case temperature
  case highlights
  case shadows
  case blur
  case vignette

  private typealias MemberID = PhotosCropDocument.MemberID

  var id: Self { self }

  var title: String {
    switch self {
    case .exposure: return "Exposure"
    case .brightness: return "Brightness"
    case .contrast: return "Contrast"
    case .saturation: return "Saturation"
    case .temperature: return "Warmth"
    case .highlights: return "Highlights"
    case .shadows: return "Shadows"
    case .blur: return "Blur"
    case .vignette: return "Vignette"
    }
  }

  var systemImageName: String {
    switch self {
    case .exposure: return "plusminus.circle"
    case .brightness: return "sun.max"
    case .contrast: return "circle.lefthalf.filled"
    case .saturation: return "drop"
    case .temperature: return "thermometer.medium"
    case .highlights: return "circle.tophalf.filled"
    case .shadows: return "circle.bottomhalf.filled"
    case .blur: return "drop.fill"
    case .vignette: return "circle.dashed.inset.filled"
    }
  }

  var accessibilityIdentifier: String {
    "photos.crop.adjustments.\(String(describing: self))"
  }

  /// Zero-based parameters only strengthen in one direction.
  private var isZeroBased: Bool {
    switch self {
    case .highlights, .blur, .vignette:
      return true
    case .exposure, .brightness, .contrast, .saturation, .temperature, .shadows:
      return false
    }
  }

  var sliderRange: ClosedRange<Double> {
    isZeroBased ? 0...100 : -100...100
  }

  /// The maximum effect value the slider's positive end maps to.
  ///
  /// These mirror the legacy `ParameterRange` maxima; the parametric features
  /// carry unbounded values, so the slider scale is a PhotosCrop policy.
  private var maximumFilterValue: Double {
    switch self {
    case .exposure: return 1.8
    case .brightness: return 0.2
    case .contrast: return 0.18
    case .saturation: return 1
    case .temperature: return 3000
    case .highlights: return 1
    case .shadows: return 1
    case .blur: return 100
    case .vignette: return 2
    }
  }

  /// The current slider value for this parameter.
  func sliderValue(in effects: PhotosCropDocument.Effects) -> Double {
    let filterValue: Double
    switch self {
    case .exposure:
      filterValue = effects.exposure?.value ?? 0
    case .brightness:
      filterValue = effects.brightness?.value ?? 0
    case .contrast:
      filterValue = effects.contrast?.value ?? 0
    case .saturation:
      filterValue = effects.saturation?.value ?? 0
    case .temperature:
      filterValue = effects.temperature?.value ?? 0
    case .highlights:
      filterValue = effects.highlights?.value ?? 0
    case .shadows:
      filterValue = effects.shadows?.value ?? 0
    case .blur:
      filterValue = effects.gaussianBlur?.editingStackFilterValue ?? 0
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
  /// A neutral value removes the effect, so untouched parameters stay absent.
  /// An existing effect is updated in place and a new one is created with the
  /// document's fixed identity, so re-applying a value restores an equal
  /// document.
  func apply(sliderValue: Double, to effects: inout PhotosCropDocument.Effects) {
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
        make: { ExposureFeature(id: MemberID.exposure, value: $0) },
        update: { $0.value = $1 }
      )
    case .brightness:
      Self.upsert(
        value,
        into: &effects.brightness,
        make: { BrightnessFeature(id: MemberID.brightness, value: $0) },
        update: { $0.value = $1 }
      )
    case .contrast:
      Self.upsert(
        value,
        into: &effects.contrast,
        make: { ContrastFeature(id: MemberID.contrast, value: $0) },
        update: { $0.value = $1 }
      )
    case .saturation:
      Self.upsert(
        value,
        into: &effects.saturation,
        make: { SaturationFeature(id: MemberID.saturation, value: $0) },
        update: { $0.value = $1 }
      )
    case .temperature:
      Self.upsert(
        value,
        into: &effects.temperature,
        make: { TemperatureFeature(id: MemberID.temperature, value: $0) },
        update: { $0.value = $1 }
      )
    case .highlights:
      Self.upsert(
        value,
        into: &effects.highlights,
        make: { HighlightsFeature(id: MemberID.highlights, value: $0) },
        update: { $0.value = $1 }
      )
    case .shadows:
      Self.upsert(
        value,
        into: &effects.shadows,
        make: { ShadowsFeature(id: MemberID.shadows, value: $0) },
        update: { $0.value = $1 }
      )
    case .blur:
      Self.upsert(
        value,
        into: &effects.gaussianBlur,
        make: { GaussianBlurFeature(id: MemberID.gaussianBlur, value: $0) },
        update: { $0.radius = .editingStackFilterValue($1) }
      )
    case .vignette:
      Self.upsert(
        value,
        into: &effects.vignette,
        make: { VignetteFeature(id: MemberID.vignette, value: $0) },
        update: { $0.value = $1 }
      )
    }
  }

  /// Updates an existing effect in place (keeping its identity), creates a
  /// missing one, or removes it when the slider returns to neutral.
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

extension GaussianBlurFeature {

  /// The PhotosCrop adjustment-slider value when this blur was authored by the
  /// global Adjust tool.
  ///
  /// Absolute-radius blurs do not have enough context here to map back onto a
  /// source-relative slider value, so the PhotosCrop control treats them as
  /// neutral and preserves them unless the user edits Blur.
  fileprivate var editingStackFilterValue: Double? {
    switch radius {
    case .editingStackFilterValue(let value):
      return value
    case .absolute:
      return nil
    }
  }
}
