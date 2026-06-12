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

import BrightroomEngine

/// Built-in filter presets offered by PhotosCrop's Filters mode.
///
/// The presets are parameter-based (no lookup-table assets), so they ship with
/// the library and remain serializable through the FeatureTree's
/// global-effects node. Hosts replace them via
/// `SwiftUIPhotosCropView.Options.filterPresets`.
public enum PhotosCropDefaultFilterPresets {

  public static func make() -> [FilterPreset] {
    [
      preset(name: "Vivid", identifier: "brightroom.preset.vivid") {
        [
          filter(FilterSaturation()) { $0.value = 0.32 },
          filter(FilterContrast()) { $0.value = 0.05 },
        ]
      },
      preset(name: "Dramatic", identifier: "brightroom.preset.dramatic") {
        [
          filter(FilterContrast()) { $0.value = 0.1 },
          filter(FilterShadows()) { $0.value = -0.3 },
          filter(FilterHighlights()) { $0.value = 0.25 },
        ]
      },
      preset(name: "Warm", identifier: "brightroom.preset.warm") {
        [
          filter(FilterTemperature()) { $0.value = 1200 }
        ]
      },
      preset(name: "Cool", identifier: "brightroom.preset.cool") {
        [
          filter(FilterTemperature()) { $0.value = -1200 }
        ]
      },
      preset(name: "Fade", identifier: "brightroom.preset.fade") {
        [
          filter(FilterFade()) { $0.intensity = 0.3 },
          filter(FilterContrast()) { $0.value = -0.04 },
        ]
      },
      preset(name: "Mono", identifier: "brightroom.preset.mono") {
        [
          filter(FilterSaturation()) { $0.value = -1 }
        ]
      },
      preset(name: "Noir", identifier: "brightroom.preset.noir") {
        [
          filter(FilterSaturation()) { $0.value = -1 },
          filter(FilterContrast()) { $0.value = 0.14 },
        ]
      },
    ]
  }

  private static func preset(
    name: String,
    identifier: String,
    filters: () -> [AnyFilter]
  ) -> FilterPreset {
    FilterPreset(
      name: name,
      identifier: identifier,
      filters: filters(),
      userInfo: [:]
    )
  }

  private static func filter<F: Filtering>(
    _ filter: F,
    _ configure: (inout F) -> Void
  ) -> AnyFilter {
    var filter = filter
    configure(&filter)
    return filter.asAny()
  }
}
