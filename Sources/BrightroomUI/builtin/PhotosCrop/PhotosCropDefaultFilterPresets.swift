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

/// Built-in filter presets offered by PhotosCrop's Filters mode.
///
/// The presets are parameter-based (no lookup-table assets), so they ship with
/// the library and remain serializable through the FeatureTree's
/// global-effects node. Hosts replace them via
/// `SwiftUIPhotosCropView.Options.filterPresets`.
public enum PhotosCropDefaultFilterPresets {

  public static func make() -> [PresetFeature] {
    [
      preset(name: "Vivid", identifier: "brightroom.preset.vivid", effects: [
        SaturationFeature(id: .init(rawValue: "brightroom.preset.vivid.saturation"), value: 0.32),
        ContrastFeature(id: .init(rawValue: "brightroom.preset.vivid.contrast"), value: 0.05),
      ]),
      preset(name: "Dramatic", identifier: "brightroom.preset.dramatic", effects: [
        ContrastFeature(id: .init(rawValue: "brightroom.preset.dramatic.contrast"), value: 0.1),
        ShadowsFeature(id: .init(rawValue: "brightroom.preset.dramatic.shadows"), value: -0.3),
        HighlightsFeature(id: .init(rawValue: "brightroom.preset.dramatic.highlights"), value: 0.25),
      ]),
      preset(name: "Warm", identifier: "brightroom.preset.warm", effects: [
        TemperatureFeature(id: .init(rawValue: "brightroom.preset.warm.temperature"), value: 1200)
      ]),
      preset(name: "Cool", identifier: "brightroom.preset.cool", effects: [
        TemperatureFeature(id: .init(rawValue: "brightroom.preset.cool.temperature"), value: -1200)
      ]),
      preset(name: "Fade", identifier: "brightroom.preset.fade", effects: [
        FadeFeature(id: .init(rawValue: "brightroom.preset.fade.fade"), intensity: 0.3),
        ContrastFeature(id: .init(rawValue: "brightroom.preset.fade.contrast"), value: -0.04),
      ]),
      preset(name: "Mono", identifier: "brightroom.preset.mono", effects: [
        SaturationFeature(id: .init(rawValue: "brightroom.preset.mono.saturation"), value: -1)
      ]),
      preset(name: "Noir", identifier: "brightroom.preset.noir", effects: [
        SaturationFeature(id: .init(rawValue: "brightroom.preset.noir.saturation"), value: -1),
        ContrastFeature(id: .init(rawValue: "brightroom.preset.noir.contrast"), value: 0.14),
      ]),
    ]
  }

  private static func preset(
    name: String,
    identifier: String,
    effects: [any ImageEffectFeatureType]
  ) -> PresetFeature {
    // Every feature id (preset and nested effects) is derived from the preset
    // identifier so each make() call — and each session — produces value-equal
    // presets; fresh FeatureIDs would make re-selection rewrite the document.
    PresetFeature(
      id: .init(rawValue: identifier),
      name: name,
      identifier: identifier,
      effects: effects
    )
  }
}
