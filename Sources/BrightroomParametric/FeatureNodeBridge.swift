//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import Foundation

public extension FeatureDocument {

  /// Creates a registry-backed document from the current enum-backed prototype.
  init(editingDocument document: EditingDocument) throws {
    self.init(
      mainTree: FeatureMainTree(
        features: try document.mainTree.features.map(FeatureTreeNode.init(mainFeature:))
      )
    )
  }
}

public extension FeatureTreeNode {

  /// Creates a registry-backed main-tree node from the current enum-backed prototype.
  init(mainFeature feature: MainFeature) throws {
    switch feature {
    case let .domain(domain):
      self = .domain(try FeatureNode(domainFeature: domain))

    case let .effect(effect):
      self = .effect(try FeatureNode(imageEffect: effect))

    case let .localAdjustment(localAdjustment):
      self = .localAdjustment(try FeatureLocalAdjustment(localAdjustment: localAdjustment))
    }
  }
}

public extension FeatureLocalAdjustment {

  /// Creates a registry-backed local adjustment from the current enum-backed prototype.
  init(localAdjustment: LocalAdjustmentFeature) throws {
    self.init(
      id: localAdjustment.id,
      isEnabled: localAdjustment.isEnabled,
      mask: try FeatureNode(maskNode: localAdjustment.maskTree.root),
      effectPipeline: try FeatureEffectPipeline(effectPipeline: localAdjustment.effectPipeline),
      blendMode: localAdjustment.blendMode
    )
  }
}

public extension FeatureEffectPipeline {

  /// Creates a registry-backed effect pipeline from the current enum-backed prototype.
  init(effectPipeline: EffectPipeline) throws {
    self.init(
      effects: try effectPipeline.effects.map(FeatureNode.init(imageEffect:))
    )
  }
}

public extension FeatureNode {

  /// Creates a registry-backed node from a domain feature.
  init(domainFeature feature: DomainFeature) throws {
    switch feature {
    case let .crop(feature):
      try self.init(crop: feature)
    }
  }

  /// Creates a registry-backed node from an image effect.
  init(imageEffect effect: ImageEffectFeature) throws {
    switch effect {
    case let .preset(feature):
      try self.init(preset: feature)
    case let .colorCube(feature):
      try self.init(colorCube: feature)
    case let .brightness(feature):
      try self.init(brightness: feature)
    case let .contrast(feature):
      try self.init(contrast: feature)
    case let .saturation(feature):
      try self.init(saturation: feature)
    case let .exposure(feature):
      try self.init(exposure: feature)
    case let .highlights(feature):
      try self.init(highlights: feature)
    case let .shadows(feature):
      try self.init(shadows: feature)
    case let .highlightShadowTint(feature):
      try self.init(highlightShadowTint: feature)
    case let .temperature(feature):
      try self.init(temperature: feature)
    case let .sharpen(feature):
      try self.init(sharpen: feature)
    case let .gaussianBlur(feature):
      try self.init(gaussianBlur: feature)
    case let .unsharpMask(feature):
      try self.init(unsharpMask: feature)
    case let .vignette(feature):
      try self.init(vignette: feature)
    case let .fade(feature):
      try self.init(fade: feature)
    }
  }

  /// Creates a registry-backed node from a mask node.
  init(maskNode node: MaskNode) throws {
    switch node {
    case let .brush(mask):
      try self.init(brushMask: mask)
    case let .invert(input):
      try self.init(invertMaskInput: input)
    case let .feather(feather):
      try self.init(featherMask: feather)
    case let .union(nodes):
      try self.init(unionMaskNodes: nodes)
    case let .intersect(nodes):
      try self.init(intersectMaskNodes: nodes)
    case let .subtract(subtract):
      try self.init(subtractMask: subtract)
    }
  }

  /// Creates a registry-backed crop node.
  init(crop feature: CropFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Crop.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(cropRect: feature.cropRect)
    )
  }

  /// Creates a registry-backed preset node.
  init(preset feature: PresetFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Preset.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(
        name: feature.name,
        identifier: feature.identifier,
        effects: try feature.effects.map(FeatureNode.init(imageEffect:))
      )
    )
  }

  /// Creates a registry-backed color-cube node.
  init(colorCube feature: ColorCubeFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.ColorCube.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(
        name: feature.name,
        identifier: feature.identifier,
        amount: feature.amount,
        dimension: feature.dimension,
        cubeData: feature.cubeData
      )
    )
  }

  /// Creates a registry-backed brightness node.
  init(brightness feature: BrightnessFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Brightness.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed contrast node.
  init(contrast feature: ContrastFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Contrast.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed saturation node.
  init(saturation feature: SaturationFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Saturation.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed exposure node.
  init(exposure feature: ExposureFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Exposure.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed highlights node.
  init(highlights feature: HighlightsFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Highlights.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed shadows node.
  init(shadows feature: ShadowsFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Shadows.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed highlight/shadow tint node.
  init(highlightShadowTint feature: HighlightShadowTintFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.HighlightShadowTint.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(
        highlightColor: feature.highlightColor,
        shadowColor: feature.shadowColor
      )
    )
  }

  /// Creates a registry-backed temperature node.
  init(temperature feature: TemperatureFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Temperature.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed sharpen node.
  init(sharpen feature: SharpenFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Sharpen.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(
        sharpness: feature.sharpness,
        radius: feature.radius
      )
    )
  }

  /// Creates a registry-backed Gaussian blur node.
  init(gaussianBlur feature: GaussianBlurFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.GaussianBlur.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(radius: feature.radius)
    )
  }

  /// Creates a registry-backed unsharp mask node.
  init(unsharpMask feature: UnsharpMaskFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.UnsharpMask.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(
        intensity: feature.intensity,
        radius: feature.radius
      )
    )
  }

  /// Creates a registry-backed vignette node.
  init(vignette feature: VignetteFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Vignette.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(value: feature.value)
    )
  }

  /// Creates a registry-backed fade node.
  init(fade feature: FadeFeature) throws {
    try self.init(
      BrightroomFeatureDefinitions.Fade.self,
      id: feature.id,
      isEnabled: feature.isEnabled,
      payload: .init(intensity: feature.intensity)
    )
  }

  /// Creates a registry-backed brush mask node.
  init(brushMask mask: BrushMask) throws {
    try self.init(
      BrightroomFeatureDefinitions.BrushMask.self,
      id: mask.id,
      isEnabled: mask.isEnabled,
      payload: .init(strokes: mask.strokes)
    )
  }

  /// Creates a registry-backed invert mask node.
  init(invertMaskInput input: MaskNode) throws {
    try self.init(
      BrightroomFeatureDefinitions.InvertMask.self,
      id: .init(),
      isEnabled: true,
      payload: .init(input: try FeatureNode(maskNode: input))
    )
  }

  /// Creates a registry-backed feather mask node.
  init(featherMask feather: MaskFeather) throws {
    try self.init(
      BrightroomFeatureDefinitions.FeatherMask.self,
      id: feather.id,
      isEnabled: feather.isEnabled,
      payload: .init(
        input: try FeatureNode(maskNode: feather.input),
        radius: feather.radius
      )
    )
  }

  /// Creates a registry-backed union mask node.
  init(unionMaskNodes nodes: [MaskNode]) throws {
    try self.init(
      BrightroomFeatureDefinitions.UnionMask.self,
      id: .init(),
      isEnabled: true,
      payload: .init(nodes: try nodes.map(FeatureNode.init(maskNode:)))
    )
  }

  /// Creates a registry-backed intersection mask node.
  init(intersectMaskNodes nodes: [MaskNode]) throws {
    try self.init(
      BrightroomFeatureDefinitions.IntersectMask.self,
      id: .init(),
      isEnabled: true,
      payload: .init(nodes: try nodes.map(FeatureNode.init(maskNode:)))
    )
  }

  /// Creates a registry-backed subtract mask node.
  init(subtractMask subtract: MaskSubtract) throws {
    try self.init(
      BrightroomFeatureDefinitions.SubtractMask.self,
      id: subtract.id,
      isEnabled: subtract.isEnabled,
      payload: .init(
        base: try FeatureNode(maskNode: subtract.base),
        removing: try FeatureNode(maskNode: subtract.removing)
      )
    )
  }
}
