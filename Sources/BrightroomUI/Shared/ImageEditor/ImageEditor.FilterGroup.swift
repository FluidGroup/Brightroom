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

import SwiftUI

import BrightroomParametric

extension ImageEditor.Options {

  /// Presets shown together: macOS's filter strip shows them after a tile
  /// with a short title, and iOS's Filters mode lists them without one.
  public struct FilterGroup: Equatable {

    /// The tile's text, two or three characters ("BW").
    public var title: String
    /// Read by VoiceOver and shown as the tile's tooltip ("Black & White").
    public var name: String
    /// The tile's color; the title is black or white, whichever contrasts.
    public var color: Color
    public var filters: [FilterFeature]

    public init(title: String, name: String, color: Color, filters: [FilterFeature]) {
      self.title = title
      self.name = name
      self.color = color
      self.filters = filters
    }
  }

  /// A group of presets in the macOS filter strip.
  enum StripGroup: Equatable {
    /// The presets of `filters`, shown without a tile.
    case untitled([FilterFeature])
    /// A group's presets, shown after its tile.
    case titled(FilterGroup)

    var filters: [FilterFeature] {
      switch self {
      case .untitled(let filters): filters
      case .titled(let group): group.filters
      }
    }
  }

  /// The presets of `filters`, then those of each group, as iOS's Filters
  /// mode lists them.
  var allFilters: [FilterFeature] {
    filters + filterGroups.flatMap(\.filters)
  }

  /// Whether `filters` or any group holds a preset.
  var hasFilters: Bool {
    !filters.isEmpty || filterGroups.contains { !$0.filters.isEmpty }
  }

  /// The macOS filter strip's groups: the presets of `filters` first, then
  /// each group that has presets.
  var stripGroups: [StripGroup] {
    assert(
      Set(allFilters.map(\.id)).count == allFilters.count,
      "Preset ids must be unique across filters and filterGroups"
    )
    var groups: [StripGroup] = filters.isEmpty ? [] : [.untitled(filters)]
    groups += filterGroups
      .filter { !$0.filters.isEmpty }
      .map(StripGroup.titled)
    return groups
  }
}
