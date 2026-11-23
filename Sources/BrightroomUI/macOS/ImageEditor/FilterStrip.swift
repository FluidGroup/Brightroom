#if os(macOS)
import AppKit
import BrightroomEngine
import BrightroomParametric
import SwiftUI

/// The macOS editor's filter strip, under the image: an Original tile that
/// removes the filter, then the host's presets, each titled group after a
/// tile in its color.
///
/// A click selects a preset, and while the strip has focus the Left and
/// Right arrows select the previous or next one, Original first: one write
/// each. Full Keyboard Access reaches the strip as it does any control;
/// otherwise only a click focuses it, so the window does not focus it when
/// it opens and no arrow key changes the filter before the strip is used.
/// The strip shows the document's preset, not a value in progress. A
/// selection from the arrows or from outside the strip, such as Remove
/// Filter or an undo, scrolls its tile to the centre. A click leaves the
/// strip where it is, unless its tile is cut off at an end, which then
/// scrolls only as far as shows it with the end padding. A thumbnail shows
/// its preset over the centre square of the unedited image and renders
/// once, so edits never render it again.
struct FilterStrip: View {

  /// The room at each end of the strip, which a tile scrolled into view
  /// keeps beside it.
  private static let endPadding: CGFloat = 12

  private let model: ImageEditorModel
  @Binding private var document: ImageEditorDocument
  private let groups: [ImageEditor.Options.StripGroup]
  private let previewSource: PreviewSource
  private let localizedStrings: ImageEditor.LocalizedStrings

  /// The tile `.scrollPosition` centres, which scrolling also writes. The
  /// selection drives it; it never selects.
  @State private var scrolledID: String?

  /// The tile a click has selected, until the selection follows: the click
  /// has scrolled it as far as it needs, so that selection is not centred.
  @State private var clickedTileID: String?

  /// Whether a click has given the strip focus. Until then it is focusable
  /// only as a control is, through Full Keyboard Access; without that, it
  /// stays out of the key view loop a window takes its first focus from.
  @State private var isClickFocusable = false
  @FocusState private var isFocused: Bool

  /// The scroller style the system prefers: a legacy scroller takes room
  /// under the tiles, where an overlay scroller floats over them.
  @State private var scrollerStyle = NSScroller.preferredScrollerStyle

  /// Whether the tiles are wider than what the strip shows, so it scrolls
  /// and shows its scroller.
  @State private var tilesOverflow = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `previewSource` is the loaded image: its thumbnail is what the tiles
  /// show.
  init(
    model: ImageEditorModel,
    document: Binding<ImageEditorDocument>,
    groups: [ImageEditor.Options.StripGroup],
    previewSource: PreviewSource,
    localizedStrings: ImageEditor.LocalizedStrings
  ) {
    self.model = model
    self._document = document
    self.groups = groups
    self.previewSource = previewSource
    self.localizedStrings = localizedStrings
  }

  var body: some View {
    let selectedPresetID = document.feature.effects.preset?.id

    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 0) {
          ForEach(tiles) { tile in
            tileView(tile, selectedPresetID: selectedPresetID, proxy: proxy)
              .padding(.leading, tile.startsGroup ? 8 : 0)
          }
        }
        .scrollTargetLayout()
        .padding(.top, 8)
        .padding(.bottom, 12)
        // Whether the tiles are wider than what the strip shows of them: the
        // scroll view's coordinate space, which leaves out the end padding,
        // as the tiles' width does.
        .onGeometryChange(for: Bool.self) { geometry in
          guard let shown = geometry.bounds(of: .scrollView) else {
            return true
          }
          return geometry.size.width > shown.width
        } action: { overflows in
          tilesOverflow = overflows
        }
      }
      // The end padding is a content margin, which a tile scrolled into view
      // keeps beside it.
      .contentMargins(.horizontal, Self.endPadding, for: .scrollContent)
      // The tiles' row, and under it the room a legacy scroller takes while
      // it shows.
      .frame(height: 80 + legacyScrollerHeight)
      // A horizontal scroll view runs on under the inspector's glass, which
      // floats over the image column's trailing edge; the tiles stay under
      // the image. The clip comes before `focusable(interactions:)`, so it
      // leaves the focus ring, drawn outside the frame, alone.
      .clipped()
      .scrollPosition(id: $scrolledID, anchor: .center)
      .focusable(interactions: isClickFocusable ? .edit : .activate)
      .focused($isFocused)
      // Simultaneous, so a click on a tile both selects it and focuses the
      // strip.
      .simultaneousGesture(
        TapGesture().onEnded {
          isClickFocusable = true
          isFocused = true
        }
      )
      .onMoveCommand { direction in
        switch direction {
        case .left:
          select(movingBy: -1, from: selectedPresetID)
        case .right:
          select(movingBy: 1, from: selectedPresetID)
        default:
          break
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(localizedStrings.filters)
      .accessibilityIdentifier("image-editor.filters")
      .onAppear {
        scrolledID = selectedPresetID ?? Tile.originalID
      }
      .onChange(of: selectedPresetID) { _, presetID in
        let tileID = presetID ?? Tile.originalID
        let isClicked = tileID == clickedTileID
        clickedTileID = nil
        guard isClicked == false else {
          return
        }
        withAnimation(scrollAnimation) {
          scrolledID = tileID
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)
      ) { _ in
        scrollerStyle = NSScroller.preferredScrollerStyle
      }
    }
  }

  /// The preset `step` tiles away from the selected one, in the order the
  /// strip shows them without its group tiles: Original, which removes the
  /// filter (`.some(nil)`), then every group's presets. nil when the step
  /// passes either end, or when the strip does not show the selected preset.
  static func preset(
    movingBy step: Int,
    from selectedPresetID: String?,
    in groups: [ImageEditor.Options.StripGroup]
  ) -> FilterFeature?? {
    let presets: [FilterFeature?] = [nil] + groups.flatMap(\.filters).map(Optional.some)
    guard let index = presets.firstIndex(where: { $0?.id == selectedPresetID }) else {
      return nil
    }

    let target = index + step
    guard presets.indices.contains(target) else {
      return nil
    }
    return .some(presets[target])
  }

  /// Black or white, whichever contrasts more with `background`: black where
  /// its linear luminance is above 0.179, where both reach about 4.58:1.
  static func titleColor(on background: Color, in environment: EnvironmentValues) -> Color {
    let resolved = background.resolve(in: environment)
    let luminance = 0.2126 * resolved.linearRed
      + 0.7152 * resolved.linearGreen
      + 0.0722 * resolved.linearBlue
    if luminance > 0.179 {
      return .black
    }
    return .white
  }

  /// The height a legacy scroller takes under the tiles while they overflow;
  /// none for an overlay scroller, or while every tile shows, when the
  /// scroller hides.
  private var legacyScrollerHeight: CGFloat {
    guard scrollerStyle == .legacy, tilesOverflow else { return 0 }
    return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
  }

  /// The tiles in strip order: Original, then each group's tile, when it has
  /// a title, and its presets.
  private var tiles: [Tile] {
    var tiles = [Tile(content: .original, isFirst: true, isLast: true)]
    for (index, group) in groups.enumerated() {
      var contents: [Tile.Content] = []
      if case .titled(let filterGroup) = group {
        contents.append(.group(filterGroup, index: index))
      }
      contents += group.filters.map(Tile.Content.preset)

      tiles += contents.enumerated().map { offset, content in
        Tile(content: content, isFirst: offset == 0, isLast: offset == contents.count - 1)
      }
    }
    return tiles
  }

  /// The selection's scroll; none under Reduce Motion.
  private var scrollAnimation: Animation? {
    reduceMotion ? nil : .snappy
  }

  @ViewBuilder
  private func tileView(
    _ tile: Tile,
    selectedPresetID: String?,
    proxy: ScrollViewProxy
  ) -> some View {
    switch tile.content {
    case .original:
      Thumbnail(
        preset: nil,
        name: localizedStrings.noFilter,
        previewSource: previewSource,
        shape: tile.shape,
        isSelected: selectedPresetID == nil
      ) { isFullyVisible in
        select(nil, clickedTile: tile.id, isFullyVisible: isFullyVisible, proxy: proxy)
      }
      .accessibilityIdentifier(Tile.originalID)
    case .group(let group, _):
      GroupTile(group: group, shape: tile.shape)
    case .preset(let preset):
      Thumbnail(
        preset: preset,
        name: preset.name,
        previewSource: previewSource,
        shape: tile.shape,
        isSelected: selectedPresetID == preset.id
      ) { isFullyVisible in
        select(preset, clickedTile: tile.id, isFullyVisible: isFullyVisible, proxy: proxy)
      }
      .accessibilityIdentifier("image-editor.filters.\(preset.id)")
    }
  }

  /// Selects the preset of a clicked tile. The strip stays where it is while
  /// the whole tile shows; otherwise it scrolls only as far as shows the
  /// tile with the end padding beside it.
  private func select(
    _ preset: FilterFeature?,
    clickedTile tileID: String,
    isFullyVisible: Bool,
    proxy: ScrollViewProxy
  ) {
    if isFullyVisible == false {
      withAnimation(scrollAnimation) {
        // Without an anchor, the least scroll that shows the tile inside the
        // content margins.
        proxy.scrollTo(tileID)
      }
    }
    // Selecting the selected preset writes nothing, so no selection follows.
    if preset?.id != document.feature.effects.preset?.id {
      clickedTileID = tileID
    }
    model.selectPreset(preset, in: $document)
  }

  /// Selects the preset `step` tiles away from the selected one, if there is
  /// one.
  private func select(movingBy step: Int, from selectedPresetID: String?) {
    if let preset = Self.preset(movingBy: step, from: selectedPresetID, in: groups) {
      model.selectPreset(preset, in: $document)
    }
  }
}

extension FilterStrip {

  /// One tile of the strip. A group's first and last tiles round its outer
  /// corners.
  private struct Tile: Identifiable {

    enum Content {
      case original
      /// A titled group's tile; `index` is the group's place in the strip.
      case group(ImageEditor.Options.FilterGroup, index: Int)
      case preset(FilterFeature)
    }

    /// The Original tile's identity; a preset's tile has the preset's id.
    static let originalID = "image-editor.filters.original"

    let content: Content
    let isFirst: Bool
    let isLast: Bool

    /// The tile's identity, which `.scrollPosition` reports.
    var id: String {
      switch content {
      case .original:
        Self.originalID
      case .group(_, let index):
        "image-editor.filters.group.\(index)"
      case .preset(let preset):
        preset.id
      }
    }

    /// Whether the tile begins a group of presets, which stands 8 points
    /// after the tile before it.
    var startsGroup: Bool {
      if case .original = content {
        return false
      }
      return isFirst
    }

    var shape: UnevenRoundedRectangle {
      UnevenRoundedRectangle(
        topLeadingRadius: isFirst ? 6 : 0,
        bottomLeadingRadius: isFirst ? 6 : 0,
        bottomTrailingRadius: isLast ? 6 : 0,
        topTrailingRadius: isLast ? 6 : 0,
        style: .continuous
      )
    }
  }

  /// A tile that shows its preset over the image's thumbnail, or the
  /// thumbnail alone for Original, ringed while it is selected and, more
  /// thinly, while the pointer is over it. The thumbnail renders off the main
  /// actor when the tile first appears, over a placeholder, and fills the
  /// tile whatever its size.
  private struct Thumbnail: View {

    let preset: FilterFeature?
    let name: String
    let previewSource: PreviewSource
    let shape: UnevenRoundedRectangle
    let isSelected: Bool
    /// Selects the tile; `isFullyVisible` is whether the strip shows all of
    /// it.
    let action: (_ isFullyVisible: Bool) -> Void

    @State private var image: CGImage?
    @State private var isHovering = false
    /// Whether the strip shows all of the tile, cut off at neither end.
    @State private var isFullyVisible = true
    @Environment(\.displayScale) private var displayScale
    @Environment(\.adjustmentRendering) private var adjustmentRendering
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
      let endPadding = FilterStrip.endPadding

      Button {
        action(isFullyVisible)
      } label: {
        ZStack {
          if let image {
            Image(decorative: image, scale: displayScale)
              .resizable()
              .scaledToFill()
          } else {
            Color.white.opacity(0.08)
          }
        }
        .frame(width: 60, height: 60)
        .clipShape(shape)
        // Inside the tile's shape, on the first frame. The selection's ring
        // takes the accent color while the window is active and dims with
        // it otherwise, as system controls do.
        .overlay {
          if isSelected {
            shape.strokeBorder(isWindowActive ? Color.accentColor : Color.secondary, lineWidth: 2)
          } else if isHovering {
            shape.strokeBorder(Color.secondary, lineWidth: 1)
          }
        }
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }
      .onGeometryChange(for: Bool.self) { geometry in
        // The scroll view's coordinate space leaves out its content margins,
        // the end padding, which shows as well.
        guard let content = geometry.bounds(of: .scrollView) else {
          return true
        }
        let visible = content.insetBy(dx: -endPadding, dy: 0)
        return visible.minX <= 0 && visible.maxX >= geometry.size.width
      } action: {
        isFullyVisible = $0
      }
      .help(name)
      .accessibilityLabel(name)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .task(id: renderKey) {
        let rendered = await FilterSwatch.render(
          base: previewSource.thumbnail,
          preset: preset,
          pointSize: 60,
          scale: displayScale,
          fullResolutionSize: previewSource.source.pixelSize,
          adjustmentRendering: adjustmentRendering
        )
        guard Task.isCancelled == false else {
          return
        }
        image = rendered
      }
    }

    /// Whether the window shows its controls active, as AppKit's do while it
    /// is key or main. Before macOS 15, `appearsActive` is true only in the
    /// key window.
    private var isWindowActive: Bool {
      if #available(macOS 15, *) {
        appearsActive
      } else {
        controlActiveState != .inactive
      }
    }

    /// What the thumbnail renders from: none of it changes with an edit.
    private var renderKey: FilterSwatch.RenderKey {
      FilterSwatch.RenderKey(
        baseImage: ObjectIdentifier(previewSource.thumbnail),
        presetID: preset?.id,
        scale: displayScale,
        rendering: adjustmentRendering.identity
      )
    }
  }

  /// A titled group's tile: its title on its color. It takes no clicks, and
  /// VoiceOver reads it as the heading of the presets after it.
  private struct GroupTile: View {

    let group: ImageEditor.Options.FilterGroup
    let shape: UnevenRoundedRectangle

    @Environment(\.self) private var environment

    var body: some View {
      Text(group.title)
        .font(.headline)
        .foregroundStyle(FilterStrip.titleColor(on: group.color, in: environment))
        .frame(width: 32, height: 60)
        .background(group.color, in: shape)
        .help(group.name)
        .accessibilityLabel(group.name)
        .accessibilityAddTraits(.isHeader)
    }
  }
}
#endif
