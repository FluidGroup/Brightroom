#if os(macOS)

import SwiftUI
import Testing

import BrightroomParametric
@testable import BrightroomUI

/// The macOS filter strip's rules that need no window: the order the arrow
/// keys select presets in, and the colour of a group tile's title.
@MainActor
struct FilterStripTests {

  private static func preset(_ id: String) -> FilterFeature {
    FilterFeature(name: id.capitalized, id: id, effects: [])
  }

  /// Two presets without a group, then a titled group of two.
  private static var groups: [ImageEditor.Options.StripGroup] {
    [
      .untitled([preset("vivid"), preset("warm")]),
      .titled(
        .init(title: "BW", name: "Black & White", color: .white, filters: [preset("mono"), preset("noir")])
      ),
    ]
  }

  /// The id of the preset an arrow key selects `step` tiles from
  /// `selectedID`: "original" for Original, nil when it selects nothing.
  private static func move(_ step: Int, from selectedID: String?) -> String? {
    FilterStrip.preset(movingBy: step, from: selectedID, in: groups).map { $0?.id ?? "original" }
  }

  @Test func `The arrow keys step through every group's presets in strip order, past the group tiles`() {
    #expect(Self.move(1, from: nil) == "vivid")
    #expect(Self.move(1, from: "vivid") == "warm")
    #expect(Self.move(1, from: "warm") == "mono", "The BW tile is not selectable.")
    #expect(Self.move(-1, from: "mono") == "warm")
    #expect(Self.move(-1, from: "vivid") == "original")
  }

  @Test func `The arrow keys stop at either end`() {
    #expect(Self.move(-1, from: nil) == nil)
    #expect(Self.move(1, from: "noir") == nil)
  }

  @Test func `A preset the strip does not show moves nowhere`() {
    #expect(Self.move(1, from: "sepia") == nil)
    #expect(Self.move(-1, from: "sepia") == nil)
  }

  @Test func `A group tile's title is black on a light colour and white on a dark one`() {
    let environment = EnvironmentValues()

    #expect(FilterStrip.titleColor(on: .white, in: environment) == .black)
    #expect(FilterStrip.titleColor(on: .yellow, in: environment) == .black)
    #expect(FilterStrip.titleColor(on: .black, in: environment) == .white)
    #expect(FilterStrip.titleColor(on: .gray, in: environment) == .black, "Black contrasts more with gray.")
  }

  @Test func `The title turns black above a linear luminance of 0.179, where both contrast equally`() {
    let environment = EnvironmentValues()

    #expect(FilterStrip.titleColor(on: Color(.sRGBLinear, white: 0.18), in: environment) == .black)
    #expect(FilterStrip.titleColor(on: Color(.sRGBLinear, white: 0.17), in: environment) == .white)
  }
}

#endif
