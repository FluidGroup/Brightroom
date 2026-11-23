#if os(macOS)

import AppKit
import Observation
import SwiftUI
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// The macOS inspector: what its cards compare, how its rows read their
/// values, which layout Color Grading opens in, and, hosted in a window off
/// every screen, how its sliders and grading wheels reach the editor model,
/// how its cards are laid out, and how its headers and footer respond.
@MainActor
struct AdjustmentInspectorTests {

  typealias Fixtures = DocumentTestFixtures
  private typealias Section = ImageEditor.AdjustmentSection

  /// A host-side document that counts writes, observed so the hosted
  /// inspector follows it.
  @MainActor
  @Observable
  final class Host {
    var document: ImageEditorDocument
    private(set) var writes = 0

    init(_ document: ImageEditorDocument) {
      self.document = document
    }

    var binding: Binding<ImageEditorDocument> {
      Binding(get: { self.document }, set: { self.document = $0; self.writes += 1 })
    }
  }

  /// Shows the inspector over the host's document, and reports the
  /// document's changes to the model as the editor does.
  struct InspectorHost: View {
    let host: Host
    let model: ImageEditorModel
    let isLoaded: Bool

    var body: some View {
      AdjustmentInspector(
        model: model,
        document: host.binding,
        isLoaded: isLoaded,
        localizedStrings: .init()
      )
      .onChange(of: host.document) { old, new in
        model.documentDidChange(from: old, to: new)
      }
    }
  }

  /// Shows the inspector over the first host's document, then, once
  /// `showsSecond` is on, over the second's: another document of the same
  /// image, bound while the editor keeps its identity.
  struct SwitchingHost: View {

    @MainActor
    @Observable
    final class Selection {
      var showsSecond = false
    }

    let first: Host
    let second: Host
    let selection: Selection
    let model: ImageEditorModel

    var body: some View {
      let host = selection.showsSecond ? second : first
      AdjustmentInspector(
        model: model,
        document: host.binding,
        isLoaded: true,
        localizedStrings: .init()
      )
      .onChange(of: host.document) { old, new in
        model.documentDidChange(from: old, to: new)
      }
    }
  }

  /// The inspector hosted in a 330 × 1600 window, tall enough to lay out
  /// every card, ordered in far off every screen, so SwiftUI handles clicks
  /// in it.
  @MainActor
  final class Mounted: WindowFixture {

    let host: Host
    let model: ImageEditorModel
    let window: NSWindow
    let hostingView: NSView

    /// The inspector over a host of `document`.
    convenience init(_ document: ImageEditorDocument, isLoaded: Bool = true) {
      let host = Host(document)
      let model = AdjustmentInspectorTests.model(editing: document)
      self.init(
        host: host,
        model: model,
        rootView: InspectorHost(host: host, model: model, isLoaded: isLoaded)
      )
    }

    init(host: Host, model: ImageEditorModel, rootView: some View) {
      self.host = host
      self.model = model
      hostingView = NSHostingView(rootView: rootView)
      window = Self.makeWindow(
        showing: hostingView,
        size: CGSize(width: 330, height: 1600),
        receivesClicks: true
      )
    }

    /// The buttons the inspector shows as `NSButton`s, pull-downs aside.
    /// SwiftUI backs a borderless button with one, and draws the bordered
    /// ones itself.
    var borderlessButtons: [NSButton] {
      Self.all(NSButton.self, in: hostingView).filter { ($0 is NSPopUpButton) == false }
    }

    /// The footer's section menu: SwiftUI backs a menu with an
    /// `NSPopUpButton`.
    var sectionMenu: NSPopUpButton? {
      Self.all(NSPopUpButton.self, in: hostingView).first
    }

    /// One arrow-key step on `slider`, from key-down to key-up: an operation
    /// of its own.
    func step(_ slider: AdjustmentSlider.Control, by direction: Double) throws {
      slider.step(by: direction, modifiers: [])
      slider.keyUp(with: try keyUp())
    }
  }

  /// The model of a macOS editor that opens `document`; it never analyses.
  static func model(editing document: ImageEditorDocument) -> ImageEditorModel {
    ImageEditorModel(documentAtStart: document, historyStep: .operation, analyze: { _ in nil })
  }

  /// The center of `correction`'s puck in a wheel at `frame`, in window
  /// coordinates, which run up.
  static func puck(of correction: ColorGradingFeature.Correction, inWheelAt frame: CGRect) -> CGPoint {
    let angle = correction.hue / 180 * .pi
    let distance = correction.saturation / 100 * frame.width / 2
    return CGPoint(x: frame.midX + cos(angle) * distance, y: frame.midY - sin(angle) * distance)
  }

  private static func document(
    _ change: (inout ImageEditorFeature) -> Void = { _ in }
  ) throws -> ImageEditorDocument {
    var feature = ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)
    change(&feature)
    return try Fixtures.makeDocument(feature: feature)
  }

  // MARK: - Values

  @Test func `A card compares what it shows, not its closures`() {
    let shown = Section.basic.members(of: Fixtures.exposure(0.9))

    func card(
      members: ImageEditorFeature = shown,
      switchState: Section.SwitchState? = .on,
      isExpanded: Bool = true,
      canReset: Bool = true,
      isLoaded: Bool = true,
      localizedStrings: ImageEditor.LocalizedStrings = .init(),
      onReset: @escaping () -> Void = {}
    ) -> AdjustmentCard<EmptyView, EmptyView> {
      AdjustmentCard(
        section: .basic,
        members: members,
        switchState: switchState,
        isExpanded: isExpanded,
        canReset: canReset,
        isLoaded: isLoaded,
        localizedStrings: localizedStrings,
        onToggleExpanded: {},
        onSetSwitch: { _ in },
        onReset: onReset
      ) {
        EmptyView()
      } accessory: {
        EmptyView()
      }
    }

    var strings = ImageEditor.LocalizedStrings()
    strings.collapsed = "zugeklappt"

    #expect(card() == card(onReset: { Issue.record("A comparison called a closure") }))
    #expect(card() != card(members: Section.basic.members(of: Fixtures.exposure(0.5))))
    #expect(card() != card(switchState: .off))
    #expect(card() != card(switchState: nil))
    #expect(card() != card(isExpanded: false))
    #expect(card() != card(canReset: false))
    #expect(card() != card(isLoaded: false))
    #expect(card() != card(localizedStrings: strings))
  }

  @Test func `A row reads its value in its unit, in whole numbers`() {
    typealias Unit = Section.Unit

    #expect(Unit.percent.text(for: 12).contains("12"))
    #expect(Unit.percent.text(for: 12).contains("%"))
    #expect(Unit.number.text(for: 12.4) == Unit.number.text(for: 12))
    #expect(Unit.percent.text(for: 11.6) == Unit.percent.text(for: 12))

    // Not "-0".
    #expect(Unit.number.text(for: -0.4) == Unit.number.text(for: 0))
    #expect(Unit.percent.text(for: -0.4) == Unit.percent.text(for: 0))
  }

  @Test func `Color Grading opens in Global only when the global correction alone is set`() {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40)

    #expect(ColorGradingCard.initialMode(for: .init()) == .threeWay)
    #expect(ColorGradingCard.initialMode(for: .init(global: tint)) == .global)
    #expect(ColorGradingCard.initialMode(for: .init(shadows: tint)) == .threeWay)
    #expect(ColorGradingCard.initialMode(for: .init(midtones: .init(luminance: 10), global: tint)) == .threeWay)
    #expect(ColorGradingCard.initialMode(for: .init(global: tint, blending: 70)) == .threeWay)
  }

  // MARK: - Hosted

  @Test func `Mounting writes nothing, and the open cards show the document's values`() async throws {
    let mounted = Mounted(try Self.document { $0.effects.exposure = ExposureFeature(ev: 0.9) })
    defer { mounted.close() }

    let exposure = try await mounted.slider("image-editor.adjust.exposure")

    // White Balance and Basic are open; the cards without values are closed.
    let identifiers = Set(mounted.sliders.keys)
    let expected = [
      ImageEditor.Adjustment.warmth, .tint,
      .exposure, .highlights, .shadows, .brightness, .contrast, .blackPoint, .texture, .clarity,
    ]
    .map(\.accessibilityIdentifier)
    #expect(identifiers == Set(expected))
    #expect(exposure.doubleValue == 50)
    #expect(exposure.isEnabled)
    #expect(mounted.host.writes == 0)
  }

  @Test func `The sliders stay disabled until the image has loaded`() async throws {
    let mounted = Mounted(try Self.document(), isLoaded: false)
    defer { mounted.close() }

    _ = try await mounted.slider("image-editor.adjust.exposure")

    #expect(mounted.sliders.isEmpty == false)
    #expect(mounted.sliders.filter { $0.value.isEnabled }.keys.sorted() == [])
  }

  @Test func `The sliders are mini, 13 points inside their card, in rows 40 points apart`() async throws {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40)
    let mounted = Mounted(try Self.document { $0.effects.colorGrading = .init(shadows: tint) })
    defer { mounted.close() }
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    let highlights = try await mounted.slider("image-editor.adjust.highlights")
    _ = try await mounted.slider("image-editor.grading.shadows.luminance")

    #expect(mounted.sliders.values.allSatisfy { $0.controlSize == .mini })

    // The column pads its cards by 12 points, and window coordinates run
    // up. A row is a 16-point title over a 20-point slider, 4 from the next.
    let exposureFrame = exposure.convert(exposure.bounds, to: nil)
    let highlightsFrame = highlights.convert(highlights.bounds, to: nil)
    let inset: CGFloat = 12 + 13
    #expect(exposureFrame.minX == inset)
    #expect(exposureFrame.width == mounted.window.frame.width - 2 * inset)
    #expect(exposureFrame.midY - highlightsFrame.midY == 40)
  }

  @Test func `A click anywhere in a card's header row collapses or expands it`() async throws {
    let mounted = Mounted(try Self.document())
    defer { mounted.close() }
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    #expect(mounted.model.expandedSections.contains(.basic))

    // Basic's 24-point header stands 8 points above its first row, a
    // 16-point title over the Exposure slider's 20-point row. Each click is
    // a point inside an edge of the header, past the title's text.
    let row = exposure.convert(exposure.bounds, to: nil)
    let headerMidY = row.midY + 10 + 16 + 8 + 12
    let x = row.minX + 100

    try mounted.click(at: CGPoint(x: x, y: headerMidY + 11))
    try await mounted.wait(
      until: { mounted.model.expandedSections.contains(.basic) == false },
      "A click at the top of the header did not collapse the card"
    )
    try mounted.click(at: CGPoint(x: x, y: headerMidY - 11))
    try await mounted.wait(
      until: { mounted.model.expandedSections.contains(.basic) },
      "A click at the bottom of the header did not expand the card"
    )
    #expect(mounted.host.writes == 0)
  }

  @Test func `Color Grading's reset button takes a 24-point square`() async throws {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40)
    let mounted = Mounted(try Self.document { $0.effects.colorGrading = .init(shadows: tint) })
    defer { mounted.close() }
    _ = try await mounted.slider("image-editor.grading.shadows.luminance")

    let buttons = mounted.borderlessButtons
    try #require(buttons.isEmpty == false, "SwiftUI backed no button with an NSButton")
    #expect(buttons.allSatisfy { $0.frame.size == CGSize(width: 24, height: 24) })
  }

  @Test func `The footer's section menu is enabled exactly when Reset is`() async throws {
    let unloaded = Mounted(try Self.document { $0.effects.exposure = ExposureFeature(ev: 0.9) }, isLoaded: false)
    defer { unloaded.close() }
    _ = try await unloaded.slider("image-editor.adjust.exposure")
    #expect(try #require(unloaded.sectionMenu).isEnabled == false)

    let mounted = Mounted(try Self.document())
    defer { mounted.close() }
    _ = try await mounted.slider("image-editor.adjust.exposure")
    let menu = try #require(mounted.sectionMenu)
    #expect(menu.isEnabled == false, "Nothing is there to reset.")

    mounted.host.document.feature.effects.exposure = ExposureFeature(ev: 0.9)
    try await mounted.wait(until: { menu.isEnabled }, "The menu stayed disabled with a value to reset")

    // Only kept values, in a section switched off.
    mounted.model.setSection(.basic, isOn: false, in: mounted.host.binding)
    try await mounted.wait(
      until: { mounted.model.switchState(of: .basic, in: mounted.host.document) == .off },
      "Basic is not switched off"
    )
    #expect(menu.isEnabled)

    mounted.model.resetSection(.basic, in: mounted.host.binding)
    try await mounted.wait(until: { menu.isEnabled == false }, "The menu stayed enabled with nothing to reset")
  }

  @Test func `A key step on a slider previews its value, and the key-up writes it once`() async throws {
    let mounted = Mounted(try Self.document())
    defer { mounted.close() }
    let exposure = try await mounted.slider("image-editor.adjust.exposure")

    exposure.step(by: 1, modifiers: [])
    let shown = mounted.model.displayedFeature(of: mounted.host.document).effects.exposure?.ev
    #expect(abs((shown ?? 0) - 0.018) < 1e-9)
    #expect(mounted.host.writes == 0)

    exposure.keyUp(with: try mounted.keyUp())
    #expect(mounted.host.writes == 1)
    let written = mounted.host.document.feature.effects.exposure?.ev
    #expect(abs((written ?? 0) - 0.018) < 1e-9)
  }

  @Test func `A key held across the host's change writes nothing from before it`() async throws {
    let mounted = Mounted(try Self.document { $0.effects.exposure = ExposureFeature(ev: 0.36) })
    defer { mounted.close() }
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    #expect(exposure.doubleValue == 20)

    // A held arrow's repeats, each shown before the next.
    for step in 1...10 {
      exposure.step(by: 1, modifiers: [])
      try await mounted.wait(
        until: { exposure.shownValue == Double(20 + step) },
        "The row does not show the step"
      )
    }

    // The host's undo, say, while the arrow is still down.
    mounted.host.document.feature.effects.exposure = nil
    try await mounted.wait(until: { exposure.shownValue == 0 }, "The row does not show the host's change")
    exposure.step(by: 1, modifiers: [])
    exposure.keyUp(with: try mounted.keyUp())
    #expect(mounted.host.writes == 0)
    #expect(mounted.host.document.feature.effects.exposure == nil)
    #expect(exposure.doubleValue == 0, "The knob shows the host's change.")

    // The next press is an operation of its own, and the knob follows its
    // write.
    try mounted.step(exposure, by: 1)
    #expect(mounted.host.writes == 1)
    let written = mounted.host.document.feature.effects.exposure?.ev
    #expect(abs((written ?? 0) - 0.018) < 1e-9)
    try await mounted.wait(until: { exposure.doubleValue == 1 }, "The knob does not show the write")
  }

  @Test func `Collapsing a card during a key step writes the step on the next turn`() async throws {
    let mounted = Mounted(try Self.document())
    defer { mounted.close() }
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    _ = mounted.window.makeFirstResponder(exposure)

    // The arrow is still down when the card's rows leave the window.
    exposure.step(by: 1, modifiers: [])
    mounted.model.toggleExpansion(of: .basic)
    try await mounted.wait(until: { exposure.window == nil }, "The Exposure slider stayed in the window")
    try await mounted.wait(until: { mounted.host.writes == 1 }, "Leaving the window did not end the key step")
    let written = mounted.host.document.feature.effects.exposure?.ev
    #expect(abs((written ?? 0) - 0.018) < 1e-9)
  }

  @Test func `Double-clicking a knob in a switched-off section resets it in one write`() async throws {
    let mounted = Mounted(try Self.document {
      $0.effects.exposure = ExposureFeature(ev: 0.9)
      $0.effects.contrast = ContrastFeature(value: 0.2)
    })
    defer { mounted.close() }
    let exposure = try await mounted.slider("image-editor.adjust.exposure")
    mounted.model.setSection(.basic, isOn: false, in: mounted.host.binding)
    try await mounted.wait(
      until: { mounted.model.switchState(of: .basic, in: mounted.host.document) == .off },
      "Basic is not switched off"
    )
    let switchedOff = mounted.host.document.feature
    #expect(mounted.host.writes == 1)

    let cell = try #require(exposure.cell as? NSSliderCell)
    let knob = cell.knobRect(flipped: exposure.isFlipped)
    let knobCenter = exposure.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
    for clickCount in [1, 2] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown,
          location: knobCenter,
          modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: mounted.window.windowNumber,
          context: nil,
          eventNumber: 0,
          clickCount: clickCount,
          pressure: 1
        )
      )
      exposure.mouseDown(with: event)
      if clickCount == 1 {
        // The first click moves nothing, so Basic stays off.
        #expect(mounted.host.writes == 1)
        #expect(mounted.model.switchState(of: .basic, in: mounted.host.document) == .off)
      }
    }

    #expect(mounted.host.writes == 2)
    #expect(mounted.host.document.feature.effects.exposure == nil)
    #expect(mounted.host.document.feature.effects.contrast == ContrastFeature(value: 0.2))
    var undone = mounted.host.document
    undone.undo()
    #expect(undone.feature == switchedOff, "One undo returns to before the double-click.")
  }

  @Test func `Grain's size and roughness wait for an amount`() async throws {
    let mounted = Mounted(try Self.document())
    defer { mounted.close() }
    mounted.model.toggleExpansion(of: .grain)

    let amount = try await mounted.slider("image-editor.grain.amount")
    let size = try await mounted.slider("image-editor.grain.size")
    let roughness = try await mounted.slider("image-editor.grain.roughness")
    #expect(amount.isEnabled)
    #expect(size.isEnabled == false)
    #expect(roughness.isEnabled == false)
    #expect(size.doubleValue == 25)
    #expect(roughness.doubleValue == 50)

    try mounted.step(amount, by: 1)
    #expect(mounted.host.writes == 1)
    #expect(mounted.host.document.feature.effects.grain == .init(amount: 1))

    try await mounted.wait(
      until: { size.isEnabled && roughness.isEnabled },
      "Size and roughness stayed disabled with an amount"
    )
  }

  @Test func `A switched-off section shows the values it keeps, and a slider in it switches it on`() async throws {
    let mounted = Mounted(try Self.document { $0.effects.exposure = ExposureFeature(ev: 0.9) })
    defer { mounted.close() }
    let exposure = try await mounted.slider("image-editor.adjust.exposure")

    mounted.model.setSection(.basic, isOn: false, in: mounted.host.binding)
    #expect(mounted.host.writes == 1)
    #expect(mounted.host.document.feature.effects.exposure == nil)

    try await mounted.wait(
      until: { mounted.model.switchState(of: .basic, in: mounted.host.document) == .off },
      "Basic is not switched off"
    )
    #expect(exposure.doubleValue == 50)

    try mounted.step(exposure, by: 1)
    #expect(mounted.host.writes == 2)
    let written = mounted.host.document.feature.effects.exposure?.ev
    #expect(abs((written ?? 0) - 0.918) < 1e-9)
    #expect(mounted.model.switchState(of: .basic, in: mounted.host.document) == .on)
  }

  @Test func `After the host binds another document of the same image, the controls write to it`() async throws {
    let image = try Fixtures.makeImage()
    let first = Host(EditingDocument(source: image, feature: ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)))
    var secondFeature = ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)
    secondFeature.effects.whiteBalance = WhiteBalanceFeature(temperature: 900)
    let second = Host(EditingDocument(source: image, feature: secondFeature))
    let selection = SwitchingHost.Selection()
    let model = Self.model(editing: first.document)
    let mounted = Mounted(
      host: first,
      model: model,
      rootView: SwitchingHost(first: first, second: second, selection: selection, model: model)
    )
    defer { mounted.close() }
    let warmth = try await mounted.slider("image-editor.adjust.warmth")
    let exposure = try await mounted.slider("image-editor.adjust.exposure")

    selection.showsSecond = true
    try await mounted.wait(
      until: { warmth.doubleValue == 30 },
      "The inspector does not show the second document"
    )

    // Basic is the same in both documents, so its card kept its body.
    try mounted.step(exposure, by: 1)
    #expect(first.writes == 0)
    #expect(first.document.feature.effects.exposure == nil)
    #expect(second.writes == 1)
    let written = second.document.feature.effects.exposure?.ev
    #expect(abs((written ?? 0) - 0.018) < 1e-9)
  }

  @Test func `The 3-Way grading's sliders edit their range and the blending`() async throws {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40)
    let mounted = Mounted(try Self.document { $0.effects.colorGrading = .init(shadows: tint) })
    defer { mounted.close() }

    // A card with values opens expanded, in 3-Way.
    let shadows = try await mounted.slider("image-editor.grading.shadows.luminance")
    let blending = try await mounted.slider("image-editor.grading.blending")
    #expect(mounted.sliders["image-editor.grading.midtones.luminance"] != nil)
    #expect(mounted.sliders["image-editor.grading.highlights.luminance"] != nil)
    #expect(mounted.sliders["image-editor.grading.balance"] != nil)
    #expect(mounted.sliders["image-editor.grading.global.luminance"] == nil)
    #expect(blending.doubleValue == 50)

    try mounted.step(shadows, by: 1)
    #expect(mounted.host.writes == 1)
    let afterShadows = mounted.host.document.feature.effects.colorGrading
    #expect(afterShadows == .init(shadows: .init(hue: 30, saturation: 40, luminance: 1)))

    // The card follows the write before the next control reads it.
    try await mounted.wait(
      until: { shadows.doubleValue == 1 },
      "The shadows luminance does not show the write"
    )
    try mounted.step(blending, by: -1)
    #expect(mounted.host.writes == 2)
    #expect(
      mounted.host.document.feature.effects.colorGrading
        == .init(shadows: .init(hue: 30, saturation: 40, luminance: 1), blending: 49)
    )
  }

  @Test func `A global-only grading opens in Global`() async throws {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40, luminance: -20)
    let mounted = Mounted(try Self.document { $0.effects.colorGrading = .init(global: tint) })
    defer { mounted.close() }

    let luminance = try await mounted.slider("image-editor.grading.global.luminance")
    #expect(luminance.doubleValue == -20)
    #expect(mounted.sliders["image-editor.grading.shadows.luminance"] == nil)
    #expect(mounted.sliders["image-editor.grading.blending"] == nil)

    try mounted.step(luminance, by: 1)
    #expect(mounted.host.writes == 1)
    #expect(
      mounted.host.document.feature.effects.colorGrading
        == .init(global: .init(hue: 30, saturation: 40, luminance: -19))
    )
  }

  @Test func `A wheel drag that collapsing the card cuts short is written once, and the next grading operation writes`() async throws {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40)
    let mounted = Mounted(try Self.document { $0.effects.colorGrading = .init(shadows: tint) })
    defer { mounted.close() }
    _ = try await mounted.slider("image-editor.grading.shadows.luminance")
    let wheel = try #require(mounted.wheelKeyboards.first)

    // The press grabs the shadows puck, and the drag moves it 10 points.
    let puck = Self.puck(of: tint, inWheelAt: wheel.convert(wheel.bounds, to: nil))
    let dragged = CGPoint(x: puck.x + 10, y: puck.y)
    try mounted.mouse(.leftMouseDown, at: puck)
    try mounted.mouse(.leftMouseDragged, at: dragged)
    try await mounted.wait(
      until: { mounted.model.displayedFeature(of: mounted.host.document).effects.colorGrading?.shadows != tint },
      "The drag shows nothing"
    )
    let shown = mounted.model.displayedFeature(of: mounted.host.document).effects.colorGrading
    #expect(mounted.host.writes == 0)

    // The card's rows leave the window before the mouse-up, which SwiftUI
    // then never reports.
    mounted.model.toggleExpansion(of: .colorGrading)
    try await mounted.wait(until: { wheel.window == nil }, "The wheel stayed in the window")
    try await mounted.wait(until: { mounted.host.writes == 1 }, "The cut-short drag was not written")
    #expect(mounted.host.document.feature.effects.colorGrading == shown)
    try mounted.mouse(.leftMouseUp, at: dragged)

    // Another action, then the shadows luminance: each writes once.
    mounted.model.resetSection(.colorGrading, in: mounted.host.binding)
    #expect(mounted.host.writes == 2)
    mounted.model.toggleExpansion(of: .colorGrading)
    let luminance = try await mounted.slider("image-editor.grading.shadows.luminance")
    try mounted.step(luminance, by: 1)
    #expect(mounted.host.writes == 3)
    #expect(mounted.host.document.feature.effects.colorGrading == .init(shadows: .init(luminance: 1)))
  }

  @Test func `A double-click on a wheel resets its range in one write`() async throws {
    let shadows = ColorGradingFeature.Correction(hue: 30, saturation: 40, luminance: 20)
    let midtones = ColorGradingFeature.Correction(hue: 200, saturation: 10)
    let mounted = Mounted(try Self.document { $0.effects.colorGrading = .init(shadows: shadows, midtones: midtones) })
    defer { mounted.close() }
    _ = try await mounted.slider("image-editor.grading.shadows.luminance")
    let opened = mounted.host.document.feature
    let wheel = try #require(mounted.wheelKeyboards.first)

    // On the puck, so the first click moves nothing.
    let puck = Self.puck(of: shadows, inWheelAt: wheel.convert(wheel.bounds, to: nil))
    for clickCount in [1, 2] {
      try mounted.mouse(.leftMouseDown, at: puck, clickCount: clickCount)
      try mounted.mouse(.leftMouseUp, at: puck, clickCount: clickCount)
    }
    try await mounted.wait(until: { mounted.host.writes == 1 }, "The double-click did not reset the range")
    try await mounted.settle()

    #expect(mounted.host.writes == 1)
    #expect(mounted.host.document.feature.effects.colorGrading == .init(midtones: midtones))
    var undone = mounted.host.document
    undone.undo()
    #expect(undone.feature == opened, "One undo returns to before the double-click.")
  }

  @Test func `A key step on a wheel previews its value, and the key-up writes it once`() async throws {
    let tint = ColorGradingFeature.Correction(hue: 30, saturation: 40)
    let mounted = Mounted(try Self.document { $0.effects.colorGrading = .init(shadows: tint) })
    defer { mounted.close() }
    _ = try await mounted.slider("image-editor.grading.shadows.luminance")
    let wheel = try #require(mounted.wheelKeyboards.first)

    wheel.step(.right, modifiers: [])
    let stepped = ColorGradingFeature(shadows: .init(hue: 31, saturation: 40))
    #expect(mounted.model.displayedFeature(of: mounted.host.document).effects.colorGrading == stepped)
    #expect(mounted.host.writes == 0)

    wheel.keyUp(with: try mounted.keyUp())
    #expect(mounted.host.writes == 1)
    #expect(mounted.host.document.feature.effects.colorGrading == stepped)
  }
}

#endif
