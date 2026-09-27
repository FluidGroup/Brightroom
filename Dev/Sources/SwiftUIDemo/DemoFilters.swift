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

/// Sample filter presets used by the ImageEditor demo.
///
/// These simple parameter combinations demonstrate host-provided presets through
/// `ImageEditor.Options.filterPresets`; they are not a production catalog.
enum DemoFilters {

  static func make() -> [PresetFeature] {
    [
      PresetFeature(name: "Vivid", identifier: "brightroom.preset.vivid", effects: [
        AnyImageEffect(SaturationFeature(value: 0.32)),
        AnyImageEffect(ContrastFeature(value: 0.05)),
      ]),
      PresetFeature(name: "Dramatic", identifier: "brightroom.preset.dramatic", effects: [
        AnyImageEffect(ContrastFeature(value: 0.1)),
        AnyImageEffect(ShadowsFeature(value: -0.3)),
        AnyImageEffect(HighlightsFeature(value: 0.25)),
      ]),
      PresetFeature(name: "Warm", identifier: "brightroom.preset.warm", effects: [
        AnyImageEffect(WhiteBalanceFeature(temperature: 1200))
      ]),
      PresetFeature(name: "Cool", identifier: "brightroom.preset.cool", effects: [
        AnyImageEffect(WhiteBalanceFeature(temperature: -1200))
      ]),
      PresetFeature(name: "Fade", identifier: "brightroom.preset.fade", effects: [
        AnyImageEffect(FadeFeature(intensity: 0.3)),
        AnyImageEffect(ContrastFeature(value: -0.04)),
      ]),
      PresetFeature(name: "Mono", identifier: "brightroom.preset.mono", effects: [
        AnyImageEffect(SaturationFeature(value: -1))
      ]),
      PresetFeature(name: "Noir", identifier: "brightroom.preset.noir", effects: [
        AnyImageEffect(SaturationFeature(value: -1)),
        AnyImageEffect(ContrastFeature(value: 0.14)),
      ]),
    ]
  }
}
