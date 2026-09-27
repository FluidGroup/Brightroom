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
/// `FeatureTreeNode` is a debug projection of a feature document:
/// it flattens a feature, a `LocalAdjustmentFeature`, or a `Mask` into a title, a
/// set of scalar parameter fields, and child nodes. It carries no rendering or
/// editing capability — it exists purely so a viewer can present the structure
/// of a document without each call site re-implementing the walk over the
/// parametric vocabulary.
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

  /// A tree-path identity used for view diffing.
  ///
  /// Features carry no identity of their own, so the id is the node's path:
  /// each step is a type name and its occurrence among same-typed siblings
  /// (for example `FilterFeature#0/WhiteBalanceFeature#0`). A sibling that is
  /// absent, such as a `nil` member, does not re-key the nodes after it, but
  /// reordering same-typed siblings does.
  public let id: String

  /// The display title (for example `Exposure`, `Crop`, `Local Adjustment`).
  public var title: String

  /// The originating Swift type name, kept for debugging.
  public var typeName: String

  /// A compact one-line summary shown in the collapsed label, if any.
  public var summary: String?

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
    symbolName: String,
    fields: [Field] = [],
    children: [FeatureTreeNode] = []
  ) {
    self.id = id
    self.title = title
    self.typeName = typeName
    self.summary = summary
    self.symbolName = symbolName
    self.fields = fields
    self.children = children
  }
}

// MARK: - Descriptor builder

/// Builds `FeatureTreeNode` snapshots from a feature document.
///
/// The tree is the document's body structure in evaluation order. Structural
/// values the builder produces (tuples, branches, optionals, arrays,
/// `AnyImageEffect`) are flattened into their parent, and a `nil` member or a
/// branch not taken is left out. A composite feature shows its body members as
/// children, even when it also implements `apply(to:context:)`; a composite
/// with no fields and no present members is left out. A `LocalAdjustmentFeature`
/// shows its mask and its effects. Scalar parameters come from `Mirror`
/// reflection of stored properties, so new features appear without changes
/// here; properties that hold features are shown as children, not as fields.
public enum FeatureTreeDescriptor {

  /// The nodes of a document in evaluation order.
  ///
  /// A document that only groups other features (a composite with no scalar
  /// fields, such as an editor's document type) lists its body members. Any
  /// other document, including a preset or a composite with settings, is one
  /// node, and a structural value such as an array lists its members.
  public static func nodes(for feature: some Feature) -> [FeatureTreeNode] {
    var root: any Feature = feature
    while let wrapper = root as? any WrappingFeatureReflection {
      guard let wrapped = wrapper.reflectedWrapped else {
        return []
      }
      root = wrapped
    }
    if (root is any StructuralFeatureReflection) == false,
       reflectedFields(of: root).isEmpty,
       let body = bodyMembers(of: root)
    {
      return childNodes(body, parentPath: nil)
    }
    return childNodes(members(of: root), parentPath: nil)
  }

  // MARK: Features

  /// Flattens structural values into the features they contain.
  fileprivate static func members(of feature: any Feature) -> [any Feature] {
    if let structural = feature as? any StructuralFeatureReflection {
      return structural.reflectedMembers.flatMap { members(of: $0) }
    }
    return [feature]
  }

  /// The flattened body members of a composite, or `nil` for a primitive.
  fileprivate static func bodyMembers<F: Feature>(of feature: F) -> [any Feature]? {
    guard F.Body.self != Never.self else {
      return nil
    }
    return members(of: feature.body)
  }

  /// The node for `feature`, or `nil` for a composite with nothing to show.
  fileprivate static func node(for feature: any Feature, path: String) -> FeatureTreeNode? {
    if let adjustment = feature as? any LocalAdjustmentReflection {
      return localAdjustmentNode(adjustment, path: path)
    }

    let typeName = String(describing: type(of: feature))
    let fields = reflectedFields(of: feature)

    if let body = bodyMembers(of: feature) {
      let children = childNodes(body, parentPath: path)
      guard fields.isEmpty == false || children.isEmpty == false else {
        return nil
      }
      return FeatureTreeNode(
        id: path,
        title: humanizeType(typeName),
        typeName: typeName,
        summary: summarize(fields) ?? count(children.count, "feature"),
        symbolName: feature is FilterFeature ? "camera.filters" : "square.stack",
        fields: fields,
        children: children
      )
    }

    return FeatureTreeNode(
      id: path,
      title: humanizeType(typeName),
      typeName: typeName,
      summary: summarize(fields),
      symbolName: symbol(for: feature),
      fields: fields
    )
  }

  fileprivate static func localAdjustmentNode(
    _ adjustment: any LocalAdjustmentReflection,
    path: String
  ) -> FeatureTreeNode {
    let mask = maskRootNode(adjustment.reflectedMask, path: "\(path)/mask")
    let effectsPath = "\(path)/effects"
    let effectNodes = childNodes(members(of: adjustment.reflectedContent), parentPath: effectsPath)
    let effects = FeatureTreeNode(
      id: effectsPath,
      title: "Effects",
      typeName: String(describing: type(of: adjustment.reflectedContent)),
      summary: count(effectNodes.count, "effect"),
      symbolName: "slider.horizontal.3",
      children: effectNodes
    )
    let maskRoot = mask.children.first
    return FeatureTreeNode(
      id: path,
      title: "Local Adjustment",
      typeName: String(describing: type(of: adjustment)),
      summary: [maskRoot?.title, maskRoot?.summary].compactMap { $0 }.joined(separator: " · "),
      symbolName: "circle.dashed.inset.filled",
      children: [mask, effects]
    )
  }

  // MARK: Mask

  fileprivate static func maskRootNode(_ mask: Mask, path: String) -> FeatureTreeNode {
    FeatureTreeNode(
      id: path,
      title: "Mask",
      typeName: "Mask",
      symbolName: "theatermasks",
      children: [maskNode(mask, path: "\(path)/0")]
    )
  }

  fileprivate static func maskNode(_ mask: Mask, path: String) -> FeatureTreeNode {
    switch mask {
    case let .brush(brush):
      let stamps = brush.strokes.reduce(0) { $0 + $1.stampCenters.count }
      return FeatureTreeNode(
        id: path,
        title: "Brush",
        typeName: "BrushMask",
        summary: count(brush.strokes.count, "stroke"),
        symbolName: "paintbrush.pointed",
        fields: [
          FeatureTreeNode.Field(name: "Strokes", value: "\(brush.strokes.count)"),
          FeatureTreeNode.Field(name: "Stamps", value: "\(stamps)"),
        ]
      )

    case let .inverted(inner):
      return FeatureTreeNode(
        id: path,
        title: "Invert",
        typeName: "Mask.inverted",
        symbolName: "circle.lefthalf.filled",
        children: [maskNode(inner, path: "\(path)/0")]
      )

    case let .feathered(inner, radius):
      let radius = FeatureValueFormatter.number(radius)
      return FeatureTreeNode(
        id: path,
        title: "Feather",
        typeName: "Mask.feathered",
        summary: "radius \(radius)",
        symbolName: "drop",
        fields: [FeatureTreeNode.Field(name: "Radius", value: radius)],
        children: [maskNode(inner, path: "\(path)/0")]
      )

    case let .union(nodes):
      return FeatureTreeNode(
        id: path,
        title: "Union",
        typeName: "Mask.union",
        summary: count(nodes.count, "input"),
        symbolName: "plus.circle",
        children: nodes.enumerated().map { maskNode($1, path: "\(path)/\($0)") }
      )

    case let .intersection(nodes):
      return FeatureTreeNode(
        id: path,
        title: "Intersect",
        typeName: "Mask.intersection",
        summary: count(nodes.count, "input"),
        symbolName: "circle.circle",
        children: nodes.enumerated().map { maskNode($1, path: "\(path)/\($0)") }
      )

    case let .subtraction(base, removing):
      return FeatureTreeNode(
        id: path,
        title: "Subtract",
        typeName: "Mask.subtraction",
        symbolName: "minus.circle",
        children: [
          labeledMaskChild("Base", base, path: "\(path)/base"),
          labeledMaskChild("Removing", removing, path: "\(path)/removing"),
        ]
      )
    }
  }

  // MARK: Helpers

  /// The nodes of sibling features, each keyed by its type name and its
  /// occurrence among same-typed siblings.
  private static func childNodes(
    _ features: [any Feature],
    parentPath: String?
  ) -> [FeatureTreeNode] {
    var occurrences: [String: Int] = [:]
    return features.compactMap { feature in
      let typeName = String(describing: type(of: feature))
      let occurrence = occurrences[typeName, default: 0]
      occurrences[typeName] = occurrence + 1
      let step = "\(typeName)#\(occurrence)"
      return node(for: feature, path: parentPath.map { "\($0)/\(step)" } ?? step)
    }
  }

  private static func labeledMaskChild(
    _ label: String,
    _ node: Mask,
    path: String
  ) -> FeatureTreeNode {
    var child = maskNode(node, path: path)
    child.title = "\(label): \(child.title)"
    return child
  }

  /// The scalar parameters of a feature.
  ///
  /// A feature with curated fields supplies them; otherwise its stored
  /// properties are reflected, skipping those that hold features or a mask
  /// (they appear as children).
  private static func reflectedFields(of feature: any Feature) -> [FeatureTreeNode.Field] {
    if let curated = feature as? any FeatureTreeFieldReflection {
      return curated.reflectedFields
    }
    return Mirror(reflecting: feature).children.compactMap { child in
      guard
        let label = child.label,
        (child.value is any Feature) == false,
        (child.value is Mask) == false
      else {
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

  private static func symbol(for feature: any Feature) -> String {
    switch feature {
    case is CropFeature: "crop"
    case is GaussianBlurFeature: "drop.fill"
    case is UnsharpMaskFeature, is SharpenFeature: "triangle"
    case is ColorCubeFeature: "swatchpalette"
    case is VignetteFeature: "circle.and.line.horizontal"
    case is WhiteBalanceFeature: "thermometer.medium"
    case is FadeFeature: "sun.haze"
    case is HighlightShadowTintFeature: "paintpalette"
    case is ToneCurveFeature: "point.bottomleft.forward.to.point.topright.scurvepath"
    case is ColorMixerFeature: "paintpalette.fill"
    case is any ImageEffect: "dial.medium"
    default: "skew"
    }
  }

  private static func humanizeType(_ typeName: String) -> String {
    var name = typeName
    if let genericStart = name.firstIndex(of: "<") {
      name = String(name[..<genericStart])
    }
    if name.hasSuffix("Feature"), name != "Feature" {
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

// MARK: - Reflection

/// A structural value the builder produces. The walk flattens it into its
/// parent.
private protocol StructuralFeatureReflection {
  var reflectedMembers: [any Feature] { get }
}

extension TupleFeature: StructuralFeatureReflection {
  var reflectedMembers: [any Feature] {
    var members: [any Feature] = []
    for element in repeat each elements {
      members.append(element)
    }
    return members
  }
}

extension EitherFeature: StructuralFeatureReflection {
  var reflectedMembers: [any Feature] {
    switch self {
    case let .first(feature):
      [feature]
    case let .second(feature):
      [feature]
    }
  }
}

extension Optional: StructuralFeatureReflection where Wrapped: Feature {
  var reflectedMembers: [any Feature] {
    map { [$0] } ?? []
  }
}

/// A structural value that holds at most one feature. The document root is
/// unwrapped through it before deciding whether to list the body members.
private protocol WrappingFeatureReflection {
  var reflectedWrapped: (any Feature)? { get }
}

extension Optional: WrappingFeatureReflection where Wrapped: Feature {
  var reflectedWrapped: (any Feature)? { self }
}

extension AnyImageEffect: WrappingFeatureReflection {
  var reflectedWrapped: (any Feature)? { base }
}

extension Array: StructuralFeatureReflection where Element: Feature {
  var reflectedMembers: [any Feature] {
    map { $0 }
  }
}

extension EmptyFeature: StructuralFeatureReflection {
  var reflectedMembers: [any Feature] { [] }
}

extension AnyImageEffect: StructuralFeatureReflection {
  var reflectedMembers: [any Feature] { [base] }
}

/// Exposes a `LocalAdjustmentFeature` without its generic content type.
private protocol LocalAdjustmentReflection {
  var reflectedMask: Mask { get }
  var reflectedContent: any Feature { get }
}

extension LocalAdjustmentFeature: LocalAdjustmentReflection {
  var reflectedMask: Mask { mask }
  var reflectedContent: any Feature { content }
}

/// Curated fields that replace `Mirror` reflection for a feature whose stored
/// properties are derived or too large to show.
private protocol FeatureTreeFieldReflection {
  var reflectedFields: [FeatureTreeNode.Field] { get }
}

extension ToneCurveFeature: FeatureTreeFieldReflection {
  var reflectedFields: [FeatureTreeNode.Field] {
    let curvedChannels = ToneCurveFeature.Channel.allCases.filter { curves[$0].isIdentity == false }
    return [
      .init(name: "Neutral", value: ToneCurveFeature.RenderKey(activeCurves: curves) == nil ? "yes" : "no"),
      .init(name: "Curved Channels", value: "\(curvedChannels.count)"),
    ]
  }
}

extension ColorMixerFeature: FeatureTreeFieldReflection {
  var reflectedFields: [FeatureTreeNode.Field] {
    [
      .init(name: "Algorithm", value: algorithm.rawValue),
      .init(name: "Neutral", value: bands.isIdentity ? "yes" : "no"),
    ]
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
    case let value as HighlightShadowTintFeature.Color:
      return "rgba(\(number(value.red)), \(number(value.green)), \(number(value.blue)), \(number(value.alpha)))"
    case let value as QuarterTurn:
      return "\(value.rawValue)°"
    case let value as GaussianBlurFeature.Radius:
      switch value {
      case let .absolute(radius):
        return "\(number(radius)) px"
      case let .proportional(value):
        return "\(number(value)) (proportional)"
      }
    case let value as any RawRepresentable:
      if let rawValue = value.rawValue as? String {
        return rawValue
      }
      return String(describing: type(of: value))
    default:
      if isNilOptional(value) {
        return "nil"
      }
      // Other values print only their type name: `String(describing:)` of a
      // curve or a large collection can be arbitrarily long.
      return String(describing: type(of: value))
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

  private static func isNilOptional(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .optional && mirror.children.isEmpty
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
/// This is a debug component: it presents the body structure of a feature
/// document as a hierarchy of `DisclosureGroup`s so the features used to produce a render
/// can be inspected. To embed the rows inside an existing `List` or `Form`, use
/// ``FeatureTreeOutline`` instead.
public struct FeatureTreeView: View {

  private let nodes: [FeatureTreeNode]

  /// Creates a viewer for a document.
  public init(feature: some Feature) {
    self.nodes = FeatureTreeDescriptor.nodes(for: feature)
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

  /// Creates an outline for a document.
  public init(feature: some Feature) {
    self.nodes = FeatureTreeDescriptor.nodes(for: feature)
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
        .foregroundStyle(Color.accentColor)

      VStack(alignment: .leading, spacing: 2) {
        Text(node.title)
          .font(.callout.weight(.medium))

        if let summary = node.summary, summary.isEmpty == false {
          Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
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
