import SwiftUI
import Testing

import BrightroomParametric
@testable import BrightroomUI

/// The presets of `ImageEditor.Options`: `filters` and `filterGroups`, as
/// iOS's Filters mode lists them and the macOS filter strip groups them.
struct ImageEditorOptionsTests {

  private static func preset(_ id: String) -> FilterFeature {
    FilterFeature(name: id.capitalized, id: id, effects: [])
  }

  @Test func `All filters lists the ungrouped presets, then each group's, in order`() {
    var options = ImageEditor.Options()
    options.filters = [Self.preset("vivid"), Self.preset("warm")]
    options.filterGroups = [
      .init(title: "BW", name: "Black & White", color: .white, filters: [Self.preset("mono"), Self.preset("noir")]),
      .init(title: "C", name: "Color", color: .gray, filters: []),
      .init(title: "LUT", name: "Looks", color: .orange, filters: [Self.preset("film")]),
    ]

    #expect(options.allFilters.map(\.id) == ["vivid", "warm", "mono", "noir", "film"])
  }

  @Test func `The strip shows the ungrouped presets first and skips groups without presets`() {
    let blackAndWhite = ImageEditor.Options.FilterGroup(
      title: "BW",
      name: "Black & White",
      color: .white,
      filters: [Self.preset("mono"), Self.preset("noir")]
    )
    let looks = ImageEditor.Options.FilterGroup(
      title: "LUT",
      name: "Looks",
      color: .orange,
      filters: [Self.preset("film")]
    )
    var options = ImageEditor.Options()
    options.filters = [Self.preset("vivid")]
    options.filterGroups = [
      .init(title: "C", name: "Color", color: .gray, filters: []),
      blackAndWhite,
      looks,
    ]

    #expect(options.stripGroups == [.untitled([Self.preset("vivid")]), .titled(blackAndWhite), .titled(looks)])
    #expect(options.stripGroups.flatMap(\.filters) == options.allFilters)
  }

  @Test func `Without ungrouped presets the strip starts with the first group that has presets`() {
    let looks = ImageEditor.Options.FilterGroup(
      title: "LUT",
      name: "Looks",
      color: .orange,
      filters: [Self.preset("film")]
    )
    var options = ImageEditor.Options()
    options.filterGroups = [.init(title: "BW", name: "Black & White", color: .white, filters: []), looks]

    #expect(options.stripGroups == [.titled(looks)])
    #expect(ImageEditor.Options().stripGroups.isEmpty)
  }

  @Test func `Options have filters when the ungrouped presets or any group hold one`() {
    var options = ImageEditor.Options()
    #expect(!options.hasFilters)

    options.filterGroups = [.init(title: "C", name: "Color", color: .gray, filters: [])]
    #expect(!options.hasFilters)

    options.filterGroups.append(.init(title: "BW", name: "Black & White", color: .white, filters: [Self.preset("mono")]))
    #expect(options.hasFilters)

    options.filterGroups = []
    options.filters = [Self.preset("vivid")]
    #expect(options.hasFilters)
  }

  @Test func `Options compare their filter groups by value`() {
    var options = ImageEditor.Options()
    options.filterGroups = [
      .init(title: "BW", name: "Black & White", color: .white, filters: [Self.preset("mono")])
    ]

    var same = ImageEditor.Options()
    same.filterGroups = [
      .init(title: "BW", name: "Black & White", color: .white, filters: [Self.preset("mono")])
    ]
    #expect(same == options)
    #expect(ImageEditor.Options() != options)

    var retitled = options
    retitled.filterGroups[0].title = "M"
    #expect(retitled != options)

    var renamed = options
    renamed.filterGroups[0].name = "Monochrome"
    #expect(renamed != options)

    var recolored = options
    recolored.filterGroups[0].color = .black
    #expect(recolored != options)

    var emptied = options
    emptied.filterGroups[0].filters = []
    #expect(emptied != options)
  }
}
