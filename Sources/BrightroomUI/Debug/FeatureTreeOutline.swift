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

import SwiftUI

import BrightroomParametric

/// The rows of a feature tree, for debugging: the body structure of a root
/// feature as nested `DisclosureGroup`s, in evaluation order.
///
/// Embed the rows in a `List`, `Form`, or `Section` of your own, such as
/// `List { FeatureTreeOutline(feature: feature) }`, to inspect the features
/// that produced a render. The top level starts expanded and nested nodes
/// start collapsed.
public struct FeatureTreeOutline: View {

  private let nodes: [FeatureTreeNode]

  /// Creates an outline for a root feature.
  public init(feature: some Feature) {
    self.nodes = FeatureTreeNode.nodes(for: feature)
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
