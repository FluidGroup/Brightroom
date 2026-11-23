import CoreGraphics
import Testing

import BrightroomParametric
@testable import BrightroomUI

/// The macOS inspector's sections: their rows and axes, the members each
/// owns, the switches that keep a switched-off section's values, and the
/// changes its controls make.
struct AdjustmentSectionTests {

  private typealias Section = ImageEditor.AdjustmentSection
  private typealias Change = ImageEditor.AdjustmentChange

  private static let imageSize = CGSize(width: 40, height: 20)

  /// A feature without values, over the whole image.
  private static var plain: ImageEditorFeature {
    ImageEditorFeature(imageSize: imageSize)
  }

  /// A feature that sets every member, over a crop of part of the image.
  private static var full: ImageEditorFeature {
    let stroke = BrushMask.Stroke(
      stampCenters: [CGPoint(x: 10, y: 10)],
      brush: .init(diameter: 8, hardness: 1, opacity: 1)
    )
    return ImageEditorFeature(
      effects: .init(
        preset: FilterFeature(name: "Test", id: "test", effects: [AnyImageEffect(BrightnessFeature(value: 0.1))]),
        exposure: ExposureFeature(ev: 0.5),
        brightness: BrightnessFeature(value: 0.1),
        whiteBalance: WhiteBalanceFeature(temperature: 600, tint: -20),
        highlights: HighlightsFeature(value: 0.3),
        shadows: ShadowsFeature(value: -0.2),
        saturation: SaturationFeature(value: 0.5),
        contrast: ContrastFeature(value: 0.1),
        blacks: BlacksFeature(amount: -30),
        colorGrading: ColorGradingFeature(midtones: .init(hue: 200, saturation: 40)),
        clarity: ClarityFeature(amount: 25),
        texture: TextureFeature(amount: -15),
        sharpen: SharpenFeature(intensity: 0.4, radius: .absolute(2)),
        unsharpMask: UnsharpMaskFeature(intensity: 0.5, radius: .absolute(3)),
        gaussianBlur: GaussianBlurFeature(radius: .proportional(10)),
        fade: FadeFeature(intensity: 0.2),
        grain: GrainFeature.CameraRaw(amount: 20, size: 40, roughness: 60, seed: 7),
        custom: [AnyImageEffect(ExposureFeature(ev: 1))]
      ),
      localBlur: LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [stroke]))) {
        GaussianBlurFeature(radius: .absolute(4))
      },
      crop: CropFeature(rect: CGRect(x: 4, y: 2, width: 20, height: 10)),
      vignette: VignetteFeature(value: 0.5)
    )
  }

  /// Every section's rows, with their section, in card order.
  private static var rows: [(section: Section, row: Section.Row)] {
    Section.allCases.flatMap { section -> [(section: Section, row: Section.Row)] in
      guard case .adjustments(let rows) = section.content else {
        return []
      }
      return rows.map { (section, $0) }
    }
  }

  /// A range's bounds, its midpoint, and the points halfway from zero to each
  /// bound.
  private static func values(in range: ClosedRange<Double>) -> [Double] {
    [
      range.lowerBound,
      range.lowerBound / 2,
      (range.lowerBound + range.upperBound) / 2,
      range.upperBound / 2,
      range.upperBound,
    ]
  }

  /// `feature` without the members `section` owns, removed one by one.
  private static func removingMembers(
    of section: Section,
    from feature: ImageEditorFeature
  ) -> ImageEditorFeature {
    var feature = feature
    switch section {
    case .whiteBalance:
      feature.effects.whiteBalance = nil
    case .basic:
      feature.effects.exposure = nil
      feature.effects.highlights = nil
      feature.effects.shadows = nil
      feature.effects.brightness = nil
      feature.effects.contrast = nil
      feature.effects.blacks = nil
      feature.effects.texture = nil
      feature.effects.clarity = nil
    case .color:
      feature.effects.saturation = nil
    case .colorGrading:
      feature.effects.colorGrading = nil
    case .blur:
      feature.effects.gaussianBlur = nil
    case .vignette:
      feature.vignette = nil
    case .grain:
      feature.effects.grain = nil
    }
    return feature
  }

  // MARK: - Sections, rows and axes

  @Test func `The sections are the inspector's cards, in order`() {
    #expect(Section.allCases == [.whiteBalance, .basic, .color, .colorGrading, .blur, .vignette, .grain])
    #expect(
      Section.allCases.map(\.title) == ["White Balance", "Basic", "Color", "Color Grading", "Blur", "Vignette", "Grain"]
    )
    #expect(Section.allCases.filter(\.isExpandedByDefault) == [.whiteBalance, .basic])
    #expect(
      Section.allCases.map(\.accessibilityIdentifier) == [
        "image-editor.section.whiteBalance",
        "image-editor.section.basic",
        "image-editor.section.color",
        "image-editor.section.colorGrading",
        "image-editor.section.blur",
        "image-editor.section.vignette",
        "image-editor.section.grain",
      ]
    )
    #expect(Section.allCases.allSatisfy { $0.id == $0 })
  }

  @Test func `Each section's rows have their titles, tracks and units`() {
    #expect(
      Section.whiteBalance.content == .adjustments([
        .init(parameter: .warmth, title: "Temperature", track: .temperature, unit: .percent),
        .init(parameter: .tint, title: "Tint", track: .tint, unit: .percent),
      ])
    )
    #expect(
      Section.basic.content == .adjustments([
        .init(parameter: .exposure, title: "Exposure", track: .plain, unit: .percent),
        .init(parameter: .highlights, title: "Highlights", track: .plain, unit: .percent),
        .init(parameter: .shadows, title: "Shadows", track: .plain, unit: .percent),
        .init(parameter: .brightness, title: "Brightness", track: .plain, unit: .percent),
        .init(parameter: .contrast, title: "Contrast", track: .plain, unit: .percent),
        .init(parameter: .blackPoint, title: "Black Point", track: .plain, unit: .percent),
        .init(parameter: .texture, title: "Texture", track: .plain, unit: .percent),
        .init(parameter: .clarity, title: "Clarity", track: .plain, unit: .percent),
      ])
    )
    #expect(
      Section.color.content == .adjustments([
        .init(parameter: .saturation, title: "Saturation", track: .plain, unit: .percent),
      ])
    )
    #expect(Section.colorGrading.content == .colorGrading)
    #expect(
      Section.blur.content == .adjustments([
        .init(parameter: .gaussianBlur, title: "Radius", track: .plain, unit: .number),
      ])
    )
    #expect(
      Section.vignette.content == .adjustments([
        .init(parameter: .vignette, title: "Amount", track: .plain, unit: .percent),
      ])
    )
    #expect(Section.grain.content == .grain)
    #expect(Self.rows.allSatisfy { $0.row.id == $0.row.parameter })
  }

  /// Highlights only recovers, and Blur and Vignette only strengthen, so
  /// their sliders start at their neutral value; the other rows are bipolar.
  @Test func `Each row's slider spans its range, and an absent member reads as zero`() {
    #expect(
      Self.rows.map { $0.row.parameter.sliderRange } == [
        -100...100,  // Temperature
        -100...100,  // Tint
        -100...100,  // Exposure
        0...100,  // Highlights
        -100...100,  // Shadows
        -100...100,  // Brightness
        -100...100,  // Contrast
        -100...100,  // Black Point
        -100...100,  // Texture
        -100...100,  // Clarity
        -100...100,  // Saturation
        0...100,  // Radius
        0...100,  // Amount
      ]
    )
    for (_, row) in Self.rows {
      #expect(row.parameter.sliderValue(in: Self.plain) == 0, "\(row.title)")
    }
  }

  /// A row writes into its own section's members only, and its card, which
  /// reads the section's members, shows the value it wrote.
  @Test func `Every row round-trips at its bounds, its midpoint and halfway to each bound`() throws {
    for (section, row) in Self.rows {
      let range = try #require(row.parameter.sliderRange)
      var base = Self.full
      section.clear(in: &base)

      for value in Self.values(in: range) {
        var feature = base
        Change.slider(row.parameter, value).apply(to: &feature)

        #expect(row.parameter.sliderValue(in: feature) == value, "\(row.title) at \(value)")
        #expect(row.parameter.sliderValue(in: section.members(of: feature)) == value, "\(row.title) at \(value)")
        #expect(section.hasValues(in: feature) == (value != 0), "\(row.title) at \(value)")

        var cleared = feature
        section.clear(in: &cleared)
        #expect(cleared == base, "\(row.title) at \(value) writes outside its section.")
      }
    }
  }

  @Test func `The grading axes are Blending and Balance`() {
    let axes = Section.gradingAxes

    #expect(axes.map(\.id) == ["blending", "balance"])
    #expect(axes.map(\.title) == ["Blending", "Balance"])
    #expect(axes.map(\.keyPath) == [\ColorGradingFeature.blending, \ColorGradingFeature.balance])
    #expect(axes.map(\.range) == [0...100, -100...100])
    #expect(axes.map(\.neutralValue) == [50, 0])
    #expect(axes.map(\.unit) == [.percent, .number])
    #expect(axes.map(\.track) == [.plain, .plain])
  }

  @Test func `The grain axes are Amount, Size and Roughness`() {
    let axes = Section.grainAxes

    #expect(axes.map(\.id) == ["amount", "size", "roughness"])
    #expect(axes.map(\.title) == ["Amount", "Size", "Roughness"])
    #expect(
      axes.map(\.keyPath) == [
        \GrainFeature.CameraRaw.amount,
        \GrainFeature.CameraRaw.size,
        \GrainFeature.CameraRaw.roughness,
      ]
    )
    #expect(axes.map(\.range) == [0...100, 0...100, 0...100])
    #expect(axes.map(\.neutralValue) == [0, 25, 50])
    #expect(axes.map(\.unit) == [.number, .number, .number])
    #expect(axes.map(\.track) == [.plain, .plain, .plain])
  }

  /// A card reads an absent grading as a neutral one, so every value reads
  /// back, including the neutral value that removes the member.
  @Test func `Every grading axis round-trips through a grading change`() {
    for axis in Section.gradingAxes {
      for value in Self.values(in: axis.range) + [axis.neutralValue] {
        var grading = ColorGradingFeature()
        grading[keyPath: axis.keyPath] = value
        var feature = Self.plain
        Change.colorGrading(grading).apply(to: &feature)

        let shown = feature.effects.colorGrading ?? ColorGradingFeature()
        #expect(shown[keyPath: axis.keyPath] == value, "\(axis.title) at \(value)")
        #expect((feature.effects.colorGrading == nil) == (value == axis.neutralValue), "\(axis.title) at \(value)")
      }
    }
  }

  /// A card reads absent grain as neutral grain, so every value reads back,
  /// including the neutral value that removes the member.
  @Test func `Every grain axis round-trips through a grain change`() {
    for axis in Section.grainAxes {
      for value in Self.values(in: axis.range) + [axis.neutralValue] {
        var grain = GrainFeature.CameraRaw(amount: 0)
        grain[keyPath: axis.keyPath] = value
        var feature = Self.plain
        Change.grain(grain).apply(to: &feature)

        let shown = feature.effects.grain ?? GrainFeature.CameraRaw(amount: 0)
        #expect(shown[keyPath: axis.keyPath] == value, "\(axis.title) at \(value)")
        #expect((feature.effects.grain == nil) == (value == axis.neutralValue), "\(axis.title) at \(value)")
      }
    }
  }

  @Test func `Every parameter belongs to the one section whose card shows it`() {
    for parameter in ImageEditor.Adjustment.allCases {
      let section = Section.section(containing: parameter)
      switch section.content {
      case .adjustments(let rows):
        #expect(rows.contains { $0.parameter == parameter }, "\(parameter) has no row in \(section).")
      case .colorGrading:
        #expect(parameter == .colorGrading)
      case .grain:
        #expect(parameter == .grain)
      }
    }

    for (section, row) in Self.rows {
      #expect(Section.section(containing: row.parameter) == section, "\(row.title)")
    }
    let parameters = Self.rows.map { $0.row.parameter }
    #expect(Set(parameters).count == parameters.count, "A parameter has two rows.")
  }

  // MARK: - Members

  @Test func `A section has values when any of its members is set`() {
    for section in Section.allCases {
      #expect(section.hasValues(in: Self.full), "\(section)")
      #expect(section.hasValues(in: Self.plain) == false, "\(section)")
    }

    var feature = Self.plain
    feature.effects.clarity = ClarityFeature(amount: 10)
    #expect(Section.basic.hasValues(in: feature))
    feature.effects.grain = GrainFeature.CameraRaw(amount: 0, size: 60)
    #expect(Section.grain.hasValues(in: feature), "Grain at zero amount keeps its shape.")
  }

  @Test func `Clearing a section removes exactly its members`() {
    for section in Section.allCases {
      var cleared = Self.full
      section.clear(in: &cleared)

      #expect(cleared == Self.removingMembers(of: section, from: Self.full), "\(section)")
      #expect(section.hasValues(in: cleared) == false, "\(section)")
    }
  }

  @Test func `Copying a section's members back restores what clearing removed`() {
    let empty = ImageEditorFeature(crop: Self.full.crop)

    for section in Section.allCases {
      var feature = Self.full
      section.clear(in: &feature)
      section.copyMembers(from: Self.full, to: &feature)
      #expect(feature == Self.full, "\(section)")

      // Into a feature without values, only the section's members arrive.
      var target = empty
      section.copyMembers(from: Self.full, to: &target)
      #expect(Self.removingMembers(of: section, from: target) == empty, "\(section)")
      #expect(section.members(of: target) == section.members(of: Self.full), "\(section)")
    }
  }

  @Test func `A section's members hold its members and the crop, and nothing else`() {
    for section in Section.allCases {
      let members = section.members(of: Self.full)

      #expect(members.crop == Self.full.crop, "\(section)")
      #expect(Self.removingMembers(of: section, from: members) == ImageEditorFeature(crop: Self.full.crop), "\(section)")
      var restored = Self.removingMembers(of: section, from: Self.full)
      section.copyMembers(from: members, to: &restored)
      #expect(restored == Self.full, "\(section)")
      for other in Section.allCases where other != section {
        #expect(other.hasValues(in: members) == false, "\(section) holds \(other)")
      }
    }
  }

  /// Cards compare their section's members, so a change made by one card's
  /// control leaves every other card's input equal.
  @Test func `A change leaves the members of every other section equal`() {
    let changes: [Change] = Self.rows.map { Change.slider($0.row.parameter, 40) } + [
      .colorGrading(ColorGradingFeature(shadows: .init(hue: 30, saturation: 20))),
      .grain(GrainFeature.CameraRaw(amount: 50)),
      .whiteBalance(nil),
    ]

    for change in changes {
      var feature = Self.full
      change.apply(to: &feature)

      #expect(change.section.members(of: feature) != change.section.members(of: Self.full), "\(change)")
      for other in Section.allCases where other != change.section {
        #expect(other.members(of: feature) == other.members(of: Self.full), "\(change) changes \(other)")
      }
    }
  }

  /// Reset keeps what no section shows: the preset, the effects without a
  /// control, the host's custom effects, the painted blur and the crop.
  @Test func `Clearing every section keeps the members no section owns`() {
    let full = Self.full
    let cleared = Section.clearingAll(in: full)

    #expect(
      cleared.effects == ImageEditorFeature.Effects(
        preset: full.effects.preset,
        sharpen: full.effects.sharpen,
        unsharpMask: full.effects.unsharpMask,
        fade: full.effects.fade,
        custom: full.effects.custom
      )
    )
    #expect(cleared.localBlur == full.localBlur)
    #expect(cleared.crop == full.crop)
    #expect(cleared.vignette == nil)
    #expect(Section.allCases.allSatisfy { $0.hasValues(in: cleared) == false })
    #expect(Section.clearingAll(in: Self.plain) == Self.plain)
  }

  // MARK: - Switches

  @Test func `A section has a switch only while it has values or kept ones`() {
    var switches = Section.Switches()
    #expect(switches.isEmpty)
    #expect(switches.state(of: .basic, in: Self.plain) == nil)
    #expect(switches.state(of: .basic, in: Self.full) == .on)

    // Switching Basic off: its members are kept, then removed.
    switches.keep(.basic, from: Self.full)
    var off = Self.full
    Section.basic.clear(in: &off)

    #expect(switches.isEmpty == false)
    #expect(switches.keptFeature(for: .basic) == Section.basic.members(of: Self.full))
    #expect(switches.keptFeature(for: .color) == nil)
    #expect(switches.state(of: .basic, in: off) == .off)
    #expect(switches.state(of: .color, in: off) == .on)
    #expect(switches.state(of: .basic, in: Self.full) == .on, "Values in the feature come before kept ones.")
  }

  @Test func `Keeping a section without values keeps nothing`() {
    var switches = Section.Switches()
    switches.keep(.color, from: Self.plain)

    #expect(switches.isEmpty)
    #expect(switches == Section.Switches())
    #expect(switches.state(of: .color, in: Self.plain) == nil)
  }

  @Test func `A switched-off section shows its kept values`() {
    var switches = Section.Switches()
    switches.keep(.basic, from: Self.full)
    var off = Self.full
    Section.basic.clear(in: &off)

    #expect(switches.shownFeature(for: .basic, in: off) == Self.full)
    #expect(switches.shownFeature(for: .color, in: off) == off)

    // Once the feature has values in the section again, they are shown.
    var edited = off
    Change.slider(.exposure, 20).apply(to: &edited)
    #expect(switches.shownFeature(for: .basic, in: edited) == edited)
  }

  @Test func `Forgetting a section removes its switch once it has no values`() {
    var switches = Section.Switches()
    switches.keep(.basic, from: Self.full)
    switches.keep(.grain, from: Self.full)
    let off = Section.clearingAll(in: Self.full)

    switches.forget(.basic)
    #expect(switches.state(of: .basic, in: off) == nil)
    #expect(switches.shownFeature(for: .basic, in: off) == off)
    #expect(switches.state(of: .grain, in: off) == .off)

    switches.forgetAll()
    #expect(switches.isEmpty)
    #expect(switches.state(of: .grain, in: off) == nil)
  }

  /// A host's undo of a switch-off brings the section's members back: the
  /// section is on again, and its kept values are forgotten.
  @Test func `Following a feature forgets the sections it has values in`() {
    var switches = Section.Switches()
    switches.keep(.basic, from: Self.full)
    switches.keep(.grain, from: Self.full)
    var off = Self.full
    Section.basic.clear(in: &off)
    Section.grain.clear(in: &off)

    let kept = switches
    switches.follow(off)
    #expect(switches == kept, "Nothing came back.")

    var undone = off
    Section.basic.copyMembers(from: Self.full, to: &undone)
    switches.follow(undone)
    #expect(switches.keptFeature(for: .basic) == nil)
    #expect(switches.keptFeature(for: .grain) == Section.grain.members(of: Self.full))
    #expect(switches.state(of: .basic, in: undone) == .on)
    #expect(switches.state(of: .grain, in: undone) == .off)
  }

  // MARK: - Changes

  @Test func `A slider change applies the parameter's slider value`() {
    for parameter in ImageEditor.Adjustment.allCases {
      var changed = Self.full
      var expected = Self.full
      Change.slider(parameter, 37).apply(to: &changed)
      parameter.apply(sliderValue: 37, to: &expected)

      #expect(changed == expected, "\(parameter)")
    }
  }

  /// A hue at zero saturation is kept, so returning to the wheel keeps it.
  @Test func `A grading change removes the member only when the grading is neutral`() {
    var feature = Self.plain

    Change.colorGrading(ColorGradingFeature(global: .init(hue: 52))).apply(to: &feature)
    #expect(feature.effects.colorGrading == ColorGradingFeature(global: .init(hue: 52)))

    Change.colorGrading(ColorGradingFeature(blending: 30)).apply(to: &feature)
    #expect(feature.effects.colorGrading == ColorGradingFeature(blending: 30))

    Change.colorGrading(ColorGradingFeature()).apply(to: &feature)
    #expect(feature.effects.colorGrading == nil)
    #expect(feature == Self.plain)
  }

  /// Zero amount keeps an authored size, roughness and seed, so the next edit
  /// restores them.
  @Test func `A grain change removes the member only when the grain is neutral`() {
    var feature = Self.plain

    Change.grain(GrainFeature.CameraRaw(amount: 0, size: 42, roughness: 70, seed: 9)).apply(to: &feature)
    #expect(feature.effects.grain == GrainFeature.CameraRaw(amount: 0, size: 42, roughness: 70, seed: 9))

    Change.grain(GrainFeature.CameraRaw(amount: 0, seed: 9)).apply(to: &feature)
    #expect(feature.effects.grain == GrainFeature.CameraRaw(amount: 0, seed: 9))

    Change.grain(GrainFeature.CameraRaw(amount: 0)).apply(to: &feature)
    #expect(feature.effects.grain == nil)
    #expect(feature == Self.plain)
  }

  @Test func `A white balance change sets the member, and nil removes it`() {
    var feature = Self.full

    Change.whiteBalance(WhiteBalanceFeature(temperature: 1200, tint: 25)).apply(to: &feature)
    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 1200, tint: 25))

    Change.whiteBalance(nil).apply(to: &feature)
    #expect(feature == Self.removingMembers(of: .whiteBalance, from: Self.full))
  }

  @Test func `Each change names its control's key and its section`() {
    for parameter in ImageEditor.Adjustment.allCases {
      #expect(Change.slider(parameter, 10).key == .slider(parameter))
      #expect(Change.slider(parameter, 10).section == Section.section(containing: parameter))
    }
    #expect(Change.slider(.exposure, 10).key == Change.slider(.exposure, -40).key, "A slider's values are one operation.")
    #expect(Change.slider(.exposure, 10).key != Change.slider(.contrast, 10).key)

    #expect(Change.colorGrading(ColorGradingFeature()).key == .colorGrading)
    #expect(Change.colorGrading(ColorGradingFeature(balance: 20)).key == .colorGrading)
    #expect(Change.colorGrading(ColorGradingFeature()).section == .colorGrading)

    #expect(Change.grain(GrainFeature.CameraRaw(amount: 10)).key == .grain)
    #expect(Change.grain(GrainFeature.CameraRaw(amount: 10, size: 60)).key == .grain)
    #expect(Change.grain(GrainFeature.CameraRaw(amount: 10)).section == .grain)

    // Temperature, Tint and the gray point all edit white balance, each as
    // an operation of its own.
    #expect(Change.whiteBalance(nil).key == .whiteBalance)
    #expect(Change.whiteBalance(nil).section == .whiteBalance)
    #expect(Set([Change.slider(.warmth, 10).key, Change.slider(.tint, 10).key, Change.whiteBalance(nil).key]).count == 3)
  }
}
