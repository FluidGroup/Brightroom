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

  /// A group of adjustments the macOS inspector shows as one card with one
  /// switch. `allCases` is the card order.
  ///
  /// Each section owns a fixed set of the feature's members: its card shows
  /// them, its switch removes and restores them, and its reset removes them.
  /// No section owns `effects.preset`, `sharpen`, `unsharpMask`, `fade` or
  /// `custom`, the local blur or the crop.
  enum AdjustmentSection: CaseIterable, Identifiable, Hashable, Sendable {

    case whiteBalance
    case basic
    case color
    case colorGrading
    case blur
    case vignette
    case grain

    /// The bar a slider draws behind its knob.
    enum Track: Equatable, Sendable {
      /// A bar filled from the neutral value to the knob.
      case plain
      /// Blue through gray to yellow.
      case temperature
      /// Green through gray to pink.
      case tint
    }

    /// How a slider's value reads.
    enum Unit: Equatable, Sendable {
      case percent
      case number
    }

    /// A slider that edits one parameter over its `sliderRange`, through
    /// `Adjustment.apply(sliderValue:to:)`. Its neutral value is zero.
    struct Row: Identifiable, Equatable {

      let parameter: Adjustment
      let title: String
      let track: Track
      let unit: Unit

      var id: Adjustment { parameter }
    }

    /// What a section's card holds.
    enum Content: Equatable {
      /// One slider per row.
      case adjustments([Row])
      /// The grading wheels and `gradingAxes`.
      case colorGrading
      /// One slider per `grainAxes` entry.
      case grain
    }

    /// A slider that edits one value of a member, such as the grain size.
    struct Axis<Value>: Identifiable {

      let id: String
      let title: String
      let keyPath: WritableKeyPath<Value, Double>
      let range: ClosedRange<Double>
      let neutralValue: Double
      let unit: Unit
      let track: Track
    }

    /// A section's switch: on while the feature has values in the section,
    /// off while it has none but kept ones (`Switches`).
    enum SwitchState: Equatable, Sendable {
      case on
      case off
    }

    var id: Self { self }

    var title: String {
      switch self {
      case .whiteBalance: return "White Balance"
      case .basic: return "Basic"
      case .color: return "Color"
      case .colorGrading: return "Color Grading"
      case .blur: return "Blur"
      case .vignette: return "Vignette"
      case .grain: return "Grain"
      }
    }

    var content: Content {
      switch self {
      case .whiteBalance:
        return .adjustments([
          Row(parameter: .warmth, title: "Temperature", track: .temperature, unit: .percent),
          Row(parameter: .tint, title: "Tint", track: .tint, unit: .percent),
        ])
      case .basic:
        return .adjustments([
          Row(parameter: .exposure, title: "Exposure", track: .plain, unit: .percent),
          Row(parameter: .highlights, title: "Highlights", track: .plain, unit: .percent),
          Row(parameter: .shadows, title: "Shadows", track: .plain, unit: .percent),
          Row(parameter: .brightness, title: "Brightness", track: .plain, unit: .percent),
          Row(parameter: .contrast, title: "Contrast", track: .plain, unit: .percent),
          Row(parameter: .blackPoint, title: "Black Point", track: .plain, unit: .percent),
          Row(parameter: .texture, title: "Texture", track: .plain, unit: .percent),
          Row(parameter: .clarity, title: "Clarity", track: .plain, unit: .percent),
        ])
      case .color:
        return .adjustments([
          Row(parameter: .saturation, title: "Saturation", track: .plain, unit: .percent),
        ])
      case .colorGrading:
        return .colorGrading
      case .blur:
        return .adjustments([
          Row(parameter: .gaussianBlur, title: "Radius", track: .plain, unit: .number),
        ])
      case .vignette:
        return .adjustments([
          Row(parameter: .vignette, title: "Amount", track: .plain, unit: .percent),
        ])
      case .grain:
        return .grain
      }
    }

    /// Whether the card starts expanded even when the section has no values.
    var isExpandedByDefault: Bool {
      switch self {
      case .whiteBalance, .basic:
        return true
      case .color, .colorGrading, .blur, .vignette, .grain:
        return false
      }
    }

    var accessibilityIdentifier: String {
      "image-editor.section.\(String(describing: self))"
    }

    /// The section whose card shows `parameter`.
    static func section(containing parameter: Adjustment) -> Self {
      switch parameter {
      case .warmth, .tint:
        return .whiteBalance
      case .exposure, .highlights, .shadows, .brightness, .contrast, .blackPoint, .texture, .clarity:
        return .basic
      case .saturation:
        return .color
      case .colorGrading:
        return .colorGrading
      case .gaussianBlur:
        return .blur
      case .vignette:
        return .vignette
      case .grain:
        return .grain
      }
    }

    /// Whether `feature` sets any of this section's members.
    func hasValues(in feature: ImageEditorFeature) -> Bool {
      members(of: feature) != ImageEditorFeature(crop: feature.crop)
    }

    /// Removes this section's members from `feature`, and nothing else.
    func clear(in feature: inout ImageEditorFeature) {
      copyMembers(from: ImageEditorFeature(crop: feature.crop), to: &feature)
    }

    /// Sets this section's members of `feature` to those of `source`, and
    /// nothing else.
    func copyMembers(from source: ImageEditorFeature, to feature: inout ImageEditorFeature) {
      switch self {
      case .whiteBalance:
        feature.effects.whiteBalance = source.effects.whiteBalance
      case .basic:
        feature.effects.exposure = source.effects.exposure
        feature.effects.highlights = source.effects.highlights
        feature.effects.shadows = source.effects.shadows
        feature.effects.brightness = source.effects.brightness
        feature.effects.contrast = source.effects.contrast
        feature.effects.blacks = source.effects.blacks
        feature.effects.texture = source.effects.texture
        feature.effects.clarity = source.effects.clarity
      case .color:
        feature.effects.saturation = source.effects.saturation
      case .colorGrading:
        feature.effects.colorGrading = source.effects.colorGrading
      case .blur:
        feature.effects.gaussianBlur = source.effects.gaussianBlur
      case .vignette:
        feature.vignette = source.vignette
      case .grain:
        feature.effects.grain = source.effects.grain
      }
    }

    /// This section's members over `feature`'s crop, nothing else: what its
    /// card shows. Cards compare it, so a drag re-evaluates only the dragged
    /// card.
    func members(of feature: ImageEditorFeature) -> ImageEditorFeature {
      var members = ImageEditorFeature(crop: feature.crop)
      copyMembers(from: feature, to: &members)
      return members
    }

    /// `feature` without any section's members: what the inspector's Reset
    /// writes. The preset, `sharpen`, `unsharpMask`, `fade`, `custom`, the
    /// local blur and the crop stay.
    static func clearingAll(in feature: ImageEditorFeature) -> ImageEditorFeature {
      var cleared = feature
      for section in allCases {
        section.clear(in: &cleared)
      }
      return cleared
    }

    /// The Color Grading card's sliders under its 3-Way wheels. Their neutral
    /// values are those of a neutral grading, which `AdjustmentChange`
    /// removes.
    ///
    /// Computed, because key paths are not `Sendable`.
    static var gradingAxes: [Axis<ColorGradingFeature>] {
      let neutral = ColorGradingFeature()
      return [
        Axis(
          id: "blending",
          title: "Blending",
          keyPath: \.blending,
          range: 0...100,
          neutralValue: neutral.blending,
          unit: .percent,
          track: .plain
        ),
        Axis(
          id: "balance",
          title: "Balance",
          keyPath: \.balance,
          range: -100...100,
          neutralValue: neutral.balance,
          unit: .number,
          track: .plain
        ),
      ]
    }

    /// The Grain card's sliders. Their neutral values are those of neutral
    /// grain, which `AdjustmentChange` removes.
    ///
    /// Computed, because key paths are not `Sendable`.
    static var grainAxes: [Axis<GrainFeature.CameraRaw>] {
      let neutral = GrainFeature.CameraRaw(amount: 0)
      return [
        Axis(
          id: "amount",
          title: "Amount",
          keyPath: \.amount,
          range: 0...100,
          neutralValue: neutral.amount,
          unit: .number,
          track: .plain
        ),
        Axis(
          id: "size",
          title: "Size",
          keyPath: \.size,
          range: 0...100,
          neutralValue: neutral.size,
          unit: .number,
          track: .plain
        ),
        Axis(
          id: "roughness",
          title: "Roughness",
          keyPath: \.roughness,
          range: 0...100,
          neutralValue: neutral.roughness,
          unit: .number,
          track: .plain
        ),
      ]
    }
  }

  /// One change an inspector control makes.
  enum AdjustmentChange: Equatable {

    /// A slider value, written by `Adjustment.apply(sliderValue:to:)`.
    case slider(Adjustment, Double)
    /// Every grading value at once. A neutral grading removes the member.
    case colorGrading(ColorGradingFeature)
    /// Every grain value at once. Neutral grain removes the member.
    case grain(GrainFeature.CameraRaw)
    /// The white balance a gray point solves for; nil removes the member.
    case whiteBalance(WhiteBalanceFeature?)

    /// The control an operation belongs to; the model keeps one operation
    /// live at a time.
    enum Key: Hashable, Sendable {
      case slider(Adjustment)
      case colorGrading
      case grain
      case whiteBalance
    }

    var key: Key {
      switch self {
      case .slider(let parameter, _):
        return .slider(parameter)
      case .colorGrading:
        return .colorGrading
      case .grain:
        return .grain
      case .whiteBalance:
        return .whiteBalance
      }
    }

    /// The section whose members the change edits.
    var section: AdjustmentSection {
      switch self {
      case .slider(let parameter, _):
        return .section(containing: parameter)
      case .colorGrading:
        return .colorGrading
      case .grain:
        return .grain
      case .whiteBalance:
        return .whiteBalance
      }
    }

    func apply(to feature: inout ImageEditorFeature) {
      switch self {
      case .slider(let parameter, let sliderValue):
        parameter.apply(sliderValue: sliderValue, to: &feature)
      case .colorGrading(let grading):
        // Keep an authored hue at zero saturation so returning to the wheel
        // keeps the selected hue. Only a complete reset removes the optional
        // feature.
        if grading == ColorGradingFeature() {
          feature.effects.colorGrading = nil
        } else {
          feature.effects.colorGrading = grading
        }
      case .grain(let grain):
        // Keep size, roughness and seed at zero amount so the next edit
        // restores them.
        if grain == GrainFeature.CameraRaw(amount: 0) {
          feature.effects.grain = nil
        } else {
          feature.effects.grain = grain
        }
      case .whiteBalance(let balance):
        feature.effects.whiteBalance = balance
      }
    }
  }
}

extension ImageEditor.AdjustmentSection {

  /// The values of sections switched off while the editor is open. View
  /// state: never in the document.
  ///
  /// Switching a section off keeps its members here and removes them from
  /// the feature; switching it on copies them back.
  struct Switches: Equatable {

    /// The members of each switched-off section, as `members(of:)` gives
    /// them.
    private(set) var kept: [ImageEditor.AdjustmentSection: ImageEditorFeature] = [:]

    var isEmpty: Bool {
      kept.isEmpty
    }

    /// `.on` while the section has values in `feature`, `.off` while it has
    /// none but kept ones, and nil when there is nothing to switch.
    func state(
      of section: ImageEditor.AdjustmentSection,
      in feature: ImageEditorFeature
    ) -> SwitchState? {
      if section.hasValues(in: feature) {
        return .on
      }
      if kept[section] != nil {
        return .off
      }
      return nil
    }

    /// What the rows show: `feature`, with the kept members copied in while
    /// the section is off.
    func shownFeature(
      for section: ImageEditor.AdjustmentSection,
      in feature: ImageEditorFeature
    ) -> ImageEditorFeature {
      guard section.hasValues(in: feature) == false, let keptMembers = kept[section] else {
        return feature
      }

      var shown = feature
      section.copyMembers(from: keptMembers, to: &shown)
      return shown
    }

    func keptFeature(for section: ImageEditor.AdjustmentSection) -> ImageEditorFeature? {
      kept[section]
    }

    /// Keeps the section's members of `feature`, before switching it off
    /// removes them. Does nothing when the section has no values in
    /// `feature`.
    mutating func keep(_ section: ImageEditor.AdjustmentSection, from feature: ImageEditorFeature) {
      guard section.hasValues(in: feature) else {
        return
      }

      kept[section] = section.members(of: feature)
    }

    mutating func forget(_ section: ImageEditor.AdjustmentSection) {
      kept[section] = nil
    }

    mutating func forgetAll() {
      kept.removeAll()
    }

    /// Forgets the sections that have values in `feature` (an undo brought
    /// them back).
    mutating func follow(_ feature: ImageEditorFeature) {
      kept = kept.filter { section, _ in section.hasValues(in: feature) == false }
    }
  }
}
