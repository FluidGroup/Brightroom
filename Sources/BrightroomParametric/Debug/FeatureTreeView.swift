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

#if canImport(SwiftUI)

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Display model

/// A read-only, display-oriented snapshot of one node in a feature tree.
///
/// `FeatureTreeNode` is a debug projection of the parametric document model: it
/// flattens a `MainFeature`, `MaskNode`, or nested pipeline into a title, a set
/// of scalar parameter fields, and child nodes. It carries no rendering or
/// editing capability — it exists purely so a viewer can present the structure
/// of an `EditingDocument` without each call site re-implementing the type
/// switch over the parametric vocabulary.
public struct FeatureTreeNode: Identifiable, Sendable {

  /// A single scalar parameter shown under a node.
  public struct Field: Identifiable, Sendable {

    /// A stable identity within a node, derived from the parameter name.
    public var id: String { name }

    /// The human-readable parameter name.
    public var name: String

    /// The formatted parameter value.
    public var value: String

    /// Creates a parameter field.
    public init(name: String, value: String) {
      self.name = name
      self.value = value
    }
  }

  /// A stable, tree-position identity used for view diffing.
  ///
  /// This is the node's path in the tree (for example `1.0`), not the parametric
  /// `FeatureID`. Mask combinators such as `union` do not carry a `FeatureID`,
  /// so a positional path is the only identity guaranteed to be unique.
  public let id: String

  /// The display title (for example `Exposure`, `Crop`, `Local Adjustment`).
  public var title: String

  /// The originating Swift type name, kept for debugging.
  public var typeName: String

  /// A compact one-line summary shown in the collapsed label, if any.
  public var summary: String?

  /// Whether the underlying feature contributes to rendering.
  public var isEnabled: Bool

  /// An SF Symbol name used as the node's leading icon.
  public var symbolName: String

  /// The scalar parameters of this node.
  public var fields: [Field]

  /// The child nodes evaluated or composed inside this node.
  public var children: [FeatureTreeNode]

  /// Creates a feature tree node.
  public init(
    id: String,
    title: String,
    typeName: String,
    summary: String? = nil,
    isEnabled: Bool,
    symbolName: String,
    fields: [Field] = [],
    children: [FeatureTreeNode] = []
  ) {
    self.id = id
    self.title = title
    self.typeName = typeName
    self.summary = summary
    self.isEnabled = isEnabled
    self.symbolName = symbolName
    self.fields = fields
    self.children = children
  }
}

// MARK: - Descriptor builder

/// Builds `FeatureTreeNode` snapshots from a parametric document.
///
/// The builder walks the document with explicit handling for structural
/// containers (effect pipelines, presets, local adjustments, mask trees) and
/// falls back to `Mirror` reflection for the scalar parameters of any leaf
/// feature. New leaf features therefore appear automatically without changes
/// here; only new structural containers need a dedicated case.
public enum FeatureTreeDescriptor {

  /// Builds the top-level nodes for a document's main tree.
  public static func nodes(for document: EditingDocument) -> [FeatureTreeNode] {
    document.mainTree.features.enumerated().map { index, feature in
      node(for: feature, path: "\(index)")
    }
  }

  // MARK: Main tree

  static func node(for feature: MainFeature, path: String) -> FeatureTreeNode {
    switch feature {
    case let .domain(domain):
      return domainNode(domain, path: path)
    case let .effect(effect):
      return effectNode(effect, path: path)
    case let .localAdjustment(adjustment):
      return localAdjustmentNode(adjustment, path: path)
    }
  }

  static func domainNode(_ domain: any DomainFeatureType, path: String) -> FeatureTreeNode {
    let typeName = String(describing: type(of: domain))
    let params = reflectedFields(of: domain)
    return FeatureTreeNode(
      id: path,
      title: humanizeType(typeName),
      typeName: typeName,
      summary: summarize(params),
      isEnabled: domain.isEnabled,
      symbolName: domain is CropFeature ? "crop" : "skew",
      fields: params + [idField(domain.id)],
      children: []
    )
  }

  static func effectNode(_ effect: any ImageEffectFeatureType, path: String) -> FeatureTreeNode {
    if let bundle = effect as? EffectPipelineFeature {
      return pipelineNode(
        id: path,
        title: "Effects",
        typeName: "EffectPipelineFeature",
        summary: count(bundle.pipeline.effects.count, "effect"),
        isEnabled: bundle.isEnabled,
        symbolName: "slider.horizontal.3",
        idField: idField(bundle.id),
        effects: bundle.pipeline.effects,
        path: path
      )
    }

    if let preset = effect as? PresetFeature {
      let params = [
        FeatureTreeNode.Field(name: "Name", value: preset.name),
        FeatureTreeNode.Field(name: "Identifier", value: preset.identifier),
      ]
      return pipelineNode(
        id: path,
        title: "Preset",
        typeName: "PresetFeature",
        summary: preset.name,
        isEnabled: preset.isEnabled,
        symbolName: "camera.filters",
        fields: params + [idField(preset.id)],
        effects: preset.effects,
        path: path
      )
    }

    let typeName = String(describing: type(of: effect))
    let params = reflectedFields(of: effect)
    return FeatureTreeNode(
      id: path,
      title: humanizeType(typeName),
      typeName: typeName,
      summary: summarize(params),
      isEnabled: effect.isEnabled,
      symbolName: symbol(forEffectType: typeName),
      fields: params + [idField(effect.id)],
      children: []
    )
  }

  static func localAdjustmentNode(
    _ adjustment: LocalAdjustmentFeature,
    path: String
  ) -> FeatureTreeNode {
    let mask = maskTreeNode(adjustment.maskTree, path: "\(path).mask")
    let effects = pipelineNode(
      id: "\(path).effects",
      title: "Effects",
      typeName: "EffectPipeline",
      summary: count(adjustment.effectPipeline.effects.count, "effect"),
      isEnabled: true,
      symbolName: "slider.horizontal.3",
      effects: adjustment.effectPipeline.effects,
      path: "\(path).effects"
    )
    let params = [FeatureTreeNode.Field(name: "Blend Mode", value: adjustment.blendMode.rawValue)]
    return FeatureTreeNode(
      id: path,
      title: "Local Adjustment",
      typeName: "LocalAdjustmentFeature",
      summary: adjustment.blendMode.rawValue,
      isEnabled: adjustment.isEnabled,
      symbolName: "circle.dashed.inset.filled",
      fields: params + [idField(adjustment.id)],
      children: [mask, effects]
    )
  }

  // MARK: Mask tree

  static func maskTreeNode(_ tree: MaskTree, path: String) -> FeatureTreeNode {
    FeatureTreeNode(
      id: path,
      title: "Mask",
      typeName: "MaskTree",
      isEnabled: true,
      symbolName: "theatermasks",
      children: [maskNode(tree.root, path: "\(path).0")]
    )
  }

  static func maskNode(_ node: MaskNode, path: String) -> FeatureTreeNode {
    switch node {
    case let .brush(brush):
      let stamps = brush.strokes.reduce(0) { $0 + $1.stamps.count }
      let fields = [
        FeatureTreeNode.Field(name: "Strokes", value: "\(brush.strokes.count)"),
        FeatureTreeNode.Field(name: "Stamps", value: "\(stamps)"),
      ]
      return FeatureTreeNode(
        id: path,
        title: "Brush",
        typeName: "BrushMask",
        summary: count(brush.strokes.count, "stroke"),
        isEnabled: brush.isEnabled,
        symbolName: "paintbrush.pointed",
        fields: fields + [idField(brush.id)]
      )

    case let .invert(inner):
      return FeatureTreeNode(
        id: path,
        title: "Invert",
        typeName: "MaskNode.invert",
        isEnabled: true,
        symbolName: "circle.lefthalf.filled",
        children: [maskNode(inner, path: "\(path).0")]
      )

    case let .feather(feather):
      let radius = FeatureValueFormatter.number(feather.radius)
      return FeatureTreeNode(
        id: path,
        title: "Feather",
        typeName: "MaskFeather",
        summary: "radius \(radius)",
        isEnabled: feather.isEnabled,
        symbolName: "drop",
        fields: [FeatureTreeNode.Field(name: "Radius", value: radius), idField(feather.id)],
        children: [maskNode(feather.input, path: "\(path).0")]
      )

    case let .union(nodes):
      return FeatureTreeNode(
        id: path,
        title: "Union",
        typeName: "MaskNode.union",
        summary: count(nodes.count, "input"),
        isEnabled: true,
        symbolName: "plus.circle",
        children: nodes.enumerated().map { maskNode($1, path: "\(path).\($0)") }
      )

    case let .intersect(nodes):
      return FeatureTreeNode(
        id: path,
        title: "Intersect",
        typeName: "MaskNode.intersect",
        summary: count(nodes.count, "input"),
        isEnabled: true,
        symbolName: "circle.circle",
        children: nodes.enumerated().map { maskNode($1, path: "\(path).\($0)") }
      )

    case let .subtract(subtract):
      return FeatureTreeNode(
        id: path,
        title: "Subtract",
        typeName: "MaskSubtract",
        isEnabled: subtract.isEnabled,
        symbolName: "minus.circle",
        fields: [idField(subtract.id)],
        children: [
          labeledMaskChild("Base", subtract.base, path: "\(path).base"),
          labeledMaskChild("Removing", subtract.removing, path: "\(path).removing"),
        ]
      )
    }
  }

  // MARK: Helpers

  private static func pipelineNode(
    id: String,
    title: String,
    typeName: String,
    summary: String?,
    isEnabled: Bool,
    symbolName: String,
    fields: [FeatureTreeNode.Field] = [],
    idField: FeatureTreeNode.Field? = nil,
    effects: [any ImageEffectFeatureType],
    path: String
  ) -> FeatureTreeNode {
    var allFields = fields
    if let idField {
      allFields.append(idField)
    }
    return FeatureTreeNode(
      id: id,
      title: title,
      typeName: typeName,
      summary: summary,
      isEnabled: isEnabled,
      symbolName: symbolName,
      fields: allFields,
      children: effects.enumerated().map { effectNode($1, path: "\(path).\($0)") }
    )
  }

  private static func labeledMaskChild(
    _ label: String,
    _ node: MaskNode,
    path: String
  ) -> FeatureTreeNode {
    var child = maskNode(node, path: path)
    child.title = "\(label): \(child.title)"
    return child
  }

  private static func idField(_ id: FeatureID) -> FeatureTreeNode.Field {
    .init(name: "ID", value: id.rawValue)
  }

  /// Reflects the scalar stored properties of a feature, skipping the structural
  /// `id` / `isEnabled` properties surfaced elsewhere.
  private static func reflectedFields(
    of feature: Any,
    skipping: Set<String> = ["id", "isEnabled"]
  ) -> [FeatureTreeNode.Field] {
    Mirror(reflecting: feature).children.compactMap { child in
      guard let label = child.label, skipping.contains(label) == false else {
        return nil
      }
      return .init(name: humanizeLabel(label), value: FeatureValueFormatter.string(for: child.value))
    }
  }

  private static func summarize(_ fields: [FeatureTreeNode.Field], max: Int = 2) -> String? {
    guard fields.isEmpty == false else {
      return nil
    }
    return fields.prefix(max).map { "\($0.name) \($0.value)" }.joined(separator: " · ")
  }

  private static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }

  private static func symbol(forEffectType typeName: String) -> String {
    switch typeName {
    case "GaussianBlurFeature": return "drop.fill"
    case "UnsharpMaskFeature", "SharpenFeature": return "triangle"
    case "ColorCubeFeature": return "swatchpalette"
    case "VignetteFeature": return "circle.and.line.horizontal"
    case "TemperatureFeature": return "thermometer.medium"
    case "FadeFeature": return "sun.haze"
    case "HighlightShadowTintFeature": return "paintpalette"
    default: return "dial.medium"
    }
  }

  private static func humanizeType(_ typeName: String) -> String {
    var name = typeName
    if name.hasSuffix("Feature") {
      name.removeLast("Feature".count)
    }
    return splitCamelCase(name)
  }

  private static func humanizeLabel(_ label: String) -> String {
    let split = splitCamelCase(label)
    return split.prefix(1).uppercased() + split.dropFirst()
  }

  private static func splitCamelCase(_ value: String) -> String {
    var result = ""
    for (index, character) in value.enumerated() {
      if character.isUppercase, index != 0 {
        result.append(" ")
      }
      result.append(character)
    }
    return result
  }
}

// MARK: - Value formatting

private enum FeatureValueFormatter {

  static func string(for value: Any) -> String {
    let value = unwrap(value)
    switch value {
    case let value as Bool:
      return value ? "true" : "false"
    case let value as Int:
      return String(value)
    case let value as Double:
      return number(value)
    case let value as Float:
      return number(Double(value))
    case let value as CGFloat:
      return number(Double(value))
    case let value as String:
      return value.isEmpty ? "\"\"" : value
    case let value as CGRect:
      return "(\(number(value.minX)), \(number(value.minY)), \(number(value.width)), \(number(value.height)))"
    case let value as CGPoint:
      return "(\(number(value.x)), \(number(value.y)))"
    case let value as CGSize:
      return "\(number(value.width)) × \(number(value.height))"
    case let value as Data:
      return ByteCountFormatter.string(fromByteCount: Int64(value.count), countStyle: .memory)
    case let value as ParametricRGBAColor:
      return "rgba(\(number(value.red)), \(number(value.green)), \(number(value.blue)), \(number(value.alpha)))"
    case let value as QuarterTurn:
      return "\(value.rawValue)°"
    case let value as FeatureID:
      return value.rawValue
    case let value as LocalAdjustmentBlendMode:
      return value.rawValue
    case let value as GaussianBlurRadius:
      switch value {
      case let .absolute(radius):
        return "absolute(\(number(radius)))"
      case let .editingStackFilterValue(radius):
        return "value(\(number(radius)))"
      }
    default:
      return String(describing: value)
    }
  }

  static func number(_ value: Double) -> String {
    guard value.isFinite else {
      return String(describing: value)
    }
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int(value))
    }
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") {
      text.removeLast()
    }
    if text.hasSuffix(".") {
      text.removeLast()
    }
    return text
  }

  private static func unwrap(_ value: Any) -> Any {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else {
      return value
    }
    return mirror.children.first?.value ?? value
  }
}

// MARK: - Views

/// A standalone, `List`-based viewer for a parametric feature tree.
///
/// This is a debug component: it presents the structure of an `EditingDocument`
/// as a hierarchy of `DisclosureGroup`s so the features used to produce a render
/// can be inspected. To embed the rows inside an existing `List` or `Form`, use
/// ``FeatureTreeOutline`` instead.
public struct FeatureTreeView: View {

  private let nodes: [FeatureTreeNode]

  /// Creates a viewer for a parametric document.
  public init(document: EditingDocument) {
    self.nodes = FeatureTreeDescriptor.nodes(for: document)
  }

  /// Creates a viewer for pre-built nodes.
  public init(nodes: [FeatureTreeNode]) {
    self.nodes = nodes
  }

  public var body: some View {
    List {
      FeatureTreeOutline(nodes: nodes)
    }
  }
}

/// The recursive rows of a feature tree, suitable for embedding inside a host
/// `List`, `Form`, or `Section`.
///
/// Use this when the feature tree should appear as one section among others (for
/// example under a rendered-result preview). For a self-contained screen use
/// ``FeatureTreeView``.
public struct FeatureTreeOutline: View {

  private let nodes: [FeatureTreeNode]

  /// Creates an outline for a parametric document.
  public init(document: EditingDocument) {
    self.nodes = FeatureTreeDescriptor.nodes(for: document)
  }

  /// Creates an outline for pre-built nodes.
  public init(nodes: [FeatureTreeNode]) {
    self.nodes = nodes
  }

  public var body: some View {
    ForEach(nodes) { node in
      FeatureTreeNodeRow(node: node, depth: 0)
    }
  }
}

private struct FeatureTreeNodeRow: View {

  let node: FeatureTreeNode
  let depth: Int

  @State private var isExpanded: Bool

  init(node: FeatureTreeNode, depth: Int) {
    self.node = node
    self.depth = depth
    // Expand the top level by default; collapse nested structure so deep trees
    // stay scannable.
    _isExpanded = State(initialValue: depth == 0)
  }

  private var hasDetail: Bool {
    node.fields.isEmpty == false || node.children.isEmpty == false
  }

  var body: some View {
    if hasDetail {
      DisclosureGroup(isExpanded: $isExpanded) {
        ForEach(node.fields) { field in
          FeatureTreeFieldRow(field: field)
        }
        ForEach(node.children) { child in
          FeatureTreeNodeRow(node: child, depth: depth + 1)
        }
      } label: {
        FeatureTreeNodeLabel(node: node)
      }
    } else {
      FeatureTreeNodeLabel(node: node)
    }
  }
}

private struct FeatureTreeNodeLabel: View {

  let node: FeatureTreeNode

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: node.symbolName)
        .font(.callout)
        .frame(width: 22)
        .foregroundStyle(node.isEnabled ? Color.accentColor : Color.secondary)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(node.title)
            .font(.callout.weight(.medium))

          if node.isEnabled == false {
            Text("disabled")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.18), in: Capsule())
              .foregroundStyle(.secondary)
          }
        }

        if let summary = node.summary, summary.isEmpty == false {
          Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .opacity(node.isEnabled ? 1 : 0.55)
  }
}

private struct FeatureTreeFieldRow: View {

  let field: FeatureTreeNode.Field

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(field.name)
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer(minLength: 12)

      Text(field.value)
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

#endif
