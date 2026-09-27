//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import CoreGraphics
import Foundation
import Testing

/// The debug tree of a feature document: its body structure in evaluation
/// order, with scalar fields reflected from stored properties.
struct FeatureTreeDescriptorTests {

  @Test func `a nil member is left out and order follows the body`() {
    var document = TreeDocument()
    let nodes = FeatureTreeDescriptor.nodes(for: document)
    #expect(nodes.map(\.typeName) == ["ExposureFeature", "FilterFeature", "FilmLook", "CropFeature"])

    document.exposure = nil
    document.vignette = VignetteFeature(value: 0.3)
    #expect(
      FeatureTreeDescriptor.nodes(for: document).map(\.typeName)
        == ["FilterFeature", "FilmLook", "VignetteFeature", "CropFeature"]
    )
  }

  @Test func `a preset shows its fields and its effects, including a nested preset`() throws {
    let preset = try #require(
      FeatureTreeDescriptor.nodes(for: TreeDocument()).first { $0.typeName == "FilterFeature" }
    )

    #expect(preset.title == "Filter")
    #expect(preset.symbolName == "camera.filters")
    #expect(Self.value(of: "Name", in: preset) == "Warm")
    #expect(Self.value(of: "Id", in: preset) == "tests.warm")
    #expect(preset.fields.map(\.name).contains("Effects") == false)
    #expect(preset.children.map(\.typeName) == ["WhiteBalanceFeature", "FilterFeature"])

    let inner = preset.children[1]
    #expect(Self.value(of: "Name", in: inner) == "Inner")
    #expect(inner.children.map(\.typeName) == ["ContrastFeature"])
  }

  @Test func `a host composite shows its scalar fields and its body members`() throws {
    let look = try #require(
      FeatureTreeDescriptor.nodes(for: TreeDocument()).first { $0.typeName == "FilmLook" }
    )

    #expect(look.title == "Film Look")
    #expect(look.symbolName == "square.stack")
    // Scalar settings are fields; the feature-valued property is a child.
    #expect(look.fields.map(\.name) == ["Grain", "Is Mono"])
    #expect(Self.value(of: "Grain", in: look) == "0.2")
    #expect(Self.value(of: "Is Mono", in: look) == "false")
    #expect(look.children.map(\.typeName) == ["SaturationFeature", "FadeFeature"])
  }

  @Test func `a local adjustment shows its mask and its effects`() throws {
    let nodes = FeatureTreeDescriptor.nodes(for: MaskedDocument())
    #expect(nodes.count == 1)
    let adjustment = try #require(nodes.first)

    #expect(adjustment.title == "Local Adjustment")
    #expect(adjustment.summary == "Feather · radius 4")
    #expect(adjustment.fields.isEmpty)
    #expect(adjustment.children.map(\.title) == ["Mask", "Effects"])

    let mask = adjustment.children[0]
    let feather = try #require(mask.children.first)
    #expect(feather.title == "Feather")
    #expect(Self.value(of: "Radius", in: feather) == "4")
    let brush = try #require(feather.children.first)
    #expect(brush.title == "Brush")
    #expect(Self.value(of: "Strokes", in: brush) == "2")
    #expect(Self.value(of: "Stamps", in: brush) == "3")

    let effects = adjustment.children[1]
    #expect(effects.children.map(\.typeName) == ["GaussianBlurFeature", "ExposureFeature"])
    #expect(Self.value(of: "Radius", in: effects.children[0]) == "40 (proportional)")

    let brushOnly = FeatureTreeDescriptor.nodes(
      for: LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [
        BrushMask.Stroke(stampCenters: [CGPoint(x: 1, y: 1)], brush: BrushMask.Brush(diameter: 4, hardness: 1, opacity: 1)),
      ]))) {
        GaussianBlurFeature(radius: .absolute(3))
      }
    )
    #expect(brushOnly.first?.summary == "Brush · 1 stroke")
    #expect(
      brushOnly.first?.children.last?.children.first.flatMap { Self.value(of: "Radius", in: $0) } == "3 px"
    )
  }

  @Test func `crop fields and type-path ids`() throws {
    let nodes = FeatureTreeDescriptor.nodes(for: TreeDocument())
    let crop = try #require(nodes.last)

    #expect(crop.title == "Crop")
    #expect(crop.symbolName == "crop")
    #expect(Self.value(of: "Rect", in: crop) == "(4, 6, 80, 60)")
    #expect(Self.value(of: "Quarter Turn", in: crop) == "-90°")
    #expect(Self.value(of: "Straighten Radians", in: crop) == "0.05")

    // Ids are type paths: unique and the same on every walk.
    let ids = Self.allNodes(nodes).map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(Self.allNodes(FeatureTreeDescriptor.nodes(for: TreeDocument())).map(\.id) == ids)
    #expect(nodes.map(\.id) == ["ExposureFeature#0", "FilterFeature#0", "FilmLook#0", "CropFeature#0"])
    #expect(
      nodes[1].children.map(\.id)
        == ["FilterFeature#0/WhiteBalanceFeature#0", "FilterFeature#0/FilterFeature#0"]
    )

    // An absent member does not re-key the nodes after it.
    var withoutExposure = TreeDocument()
    withoutExposure.exposure = nil
    let shifted = FeatureTreeDescriptor.nodes(for: withoutExposure)
    #expect(shifted.map(\.id) == ["FilterFeature#0", "FilmLook#0", "CropFeature#0"])

    // Same-typed siblings are told apart by occurrence.
    let twice = [AnyImageEffect(FadeFeature(intensity: 0.1)), AnyImageEffect(FadeFeature(intensity: 0.2))]
    #expect(FeatureTreeDescriptor.nodes(for: twice).map(\.id) == ["FadeFeature#0", "FadeFeature#1"])
  }

  @Test func `a composite with fields is a node wherever it sits`() {
    let preset = TreeDocument().preset
    let fade = AnyImageEffect(FadeFeature(intensity: 0.1))

    #expect(FeatureTreeDescriptor.nodes(for: preset).map(\.typeName) == ["FilterFeature"])
    #expect(FeatureTreeDescriptor.nodes(for: preset).first?.fields.map(\.name) == ["Name", "Id"])
    #expect(FeatureTreeDescriptor.nodes(for: [AnyImageEffect(preset)]).map(\.typeName) == ["FilterFeature"])
    #expect(
      FeatureTreeDescriptor.nodes(for: [AnyImageEffect(preset), fade]).map(\.typeName)
        == ["FilterFeature", "FadeFeature"]
    )

    let look = FeatureTreeDescriptor.nodes(for: FilmLook())
    #expect(look.map(\.typeName) == ["FilmLook"])
    #expect(look.first?.fields.map(\.name) == ["Grain", "Is Mono"])
  }

  @Test func `a composite with no fields and no present members is left out`() {
    let nodes = FeatureTreeDescriptor.nodes(for: GroupedDocument())
    #expect(nodes.map(\.typeName) == ["CropFeature"])

    var edited = GroupedDocument()
    edited.effects.exposure = ExposureFeature(ev: 0.1)
    let editedNodes = FeatureTreeDescriptor.nodes(for: edited)
    #expect(editedNodes.map(\.typeName) == ["Effects", "CropFeature"])
    #expect(editedNodes.first?.summary == "1 feature")
  }

  @Test func `fields hold parameters only, with curated tone curve and mixer fields`() throws {
    var curve = ToneCurveEditorValue()
    let insertedIndex = curve.y.insertPoint(input: 0.3, output: 0.4)
    _ = try #require(insertedIndex)
    let document = ColorDocument(
      toneCurve: ToneCurveFeature(value: curve),
      colorMixer: ColorMixerFeature(adjustment: .init(red: .init(hue: 12)))
    )
    let nodes = FeatureTreeDescriptor.nodes(for: document)
    #expect(nodes.count == 2)

    for node in Self.allNodes(nodes) + Self.allNodes(FeatureTreeDescriptor.nodes(for: TreeDocument())) {
      #expect(node.fields.map(\.name).contains("ID") == false, "\(node.typeName)")
      #expect(node.fields.map(\.name).contains("Is Enabled") == false, "\(node.typeName)")
    }

    let toneCurve = nodes[0]
    #expect(Self.value(of: "Neutral", in: toneCurve) == "no")
    #expect(Self.value(of: "Curved Channels", in: toneCurve) == "1")
    #expect(toneCurve.fields.map(\.name).contains("Render Plan") == false)

    let mixer = nodes[1]
    #expect(Self.value(of: "Algorithm", in: mixer) == "oklch")
    #expect(Self.value(of: "Neutral", in: mixer) == "no")

    let neutral = FeatureTreeDescriptor.nodes(for: ToneCurveFeature(value: .neutral))
    #expect(neutral.count == 1)
    #expect(neutral.first.flatMap { Self.value(of: "Neutral", in: $0) } == "yes")
  }

  @Test func `structural documents list their members`() {
    let array = [
      AnyImageEffect(ExposureFeature(ev: 0.1)),
      AnyImageEffect(FadeFeature(intensity: 0.2)),
    ]
    #expect(
      FeatureTreeDescriptor.nodes(for: array).map(\.typeName) == ["ExposureFeature", "FadeFeature"]
    )

    let present: TreeDocument? = TreeDocument()
    #expect(FeatureTreeDescriptor.nodes(for: present).count == 4)

    let absent: TreeDocument? = nil
    #expect(FeatureTreeDescriptor.nodes(for: absent).isEmpty)

    let tuple = TupleFeature(ExposureFeature(ev: 0.1), CropFeature(rect: CGRect(x: 0, y: 0, width: 4, height: 4)))
    #expect(
      FeatureTreeDescriptor.nodes(for: tuple).map(\.typeName) == ["ExposureFeature", "CropFeature"]
    )

    #expect(FeatureTreeDescriptor.nodes(for: EmptyFeature()).isEmpty)
    #expect(FeatureTreeDescriptor.nodes(for: ExposureFeature(ev: 0.1)).map(\.title) == ["Exposure"])
  }

  // MARK: - Helpers

  private static func value(of name: String, in node: FeatureTreeNode) -> String? {
    node.fields.first { $0.name == name }?.value
  }

  private static func allNodes(_ nodes: [FeatureTreeNode]) -> [FeatureTreeNode] {
    nodes.flatMap { [$0] + allNodes($0.children) }
  }
}

// MARK: - Documents

/// A host look with scalar settings and a feature-valued member.
private struct FilmLook: ImageEffect, Equatable {

  var grain = 0.2
  var isMono = false
  var fade = FadeFeature(intensity: 0.1)

  var body: some ImageEffect {
    if isMono {
      SaturationFeature(value: -1)
    } else {
      SaturationFeature(value: 0.1)
    }
    fade
  }
}

private struct TreeDocument: Feature {

  var exposure: ExposureFeature? = ExposureFeature(ev: 0.2)
  var preset = FilterFeature(
    name: "Warm",
    id: "tests.warm",
    effects: [
      AnyImageEffect(WhiteBalanceFeature(temperature: 400)),
      AnyImageEffect(
        FilterFeature(
          name: "Inner",
          id: "tests.inner",
          effects: [AnyImageEffect(ContrastFeature(value: 0.1))]
        )
      ),
    ]
  )
  var look = FilmLook()
  var vignette: VignetteFeature?
  var crop = CropFeature(
    rect: CGRect(x: 4, y: 6, width: 80, height: 60),
    quarterTurn: .counterclockwise,
    straightenRadians: 0.05
  )

  var body: some Feature {
    exposure
    preset
    look
    vignette
    crop
  }
}

private struct MaskedDocument: Feature {

  var body: some Feature {
    LocalAdjustmentFeature(
      mask: .feathered(
        .brush(
          BrushMask(strokes: [
            BrushMask.Stroke(
              stampCenters: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)],
              brush: BrushMask.Brush(diameter: 4, hardness: 1, opacity: 1)
            ),
            BrushMask.Stroke(
              stampCenters: [CGPoint(x: 3, y: 3)],
              brush: BrushMask.Brush(diameter: 4, hardness: 1, opacity: 1)
            ),
          ])
        ),
        radius: 4
      )
    ) {
      GaussianBlurFeature(radius: .proportional(40))
      ExposureFeature(ev: 0.3)
    }
  }
}

private struct GroupedDocument: Feature {

  struct Effects: ImageEffect {
    var exposure: ExposureFeature?
    var fade: FadeFeature?

    var body: some ImageEffect {
      exposure
      fade
    }
  }

  var effects = Effects()
  var crop = CropFeature(rect: CGRect(x: 0, y: 0, width: 8, height: 8))

  var body: some Feature {
    effects
    crop
  }
}

private struct ColorDocument: Feature {

  var toneCurve: ToneCurveFeature
  var colorMixer: ColorMixerFeature

  var body: some Feature {
    toneCurve
    colorMixer
  }
}
