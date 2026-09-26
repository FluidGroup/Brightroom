import BrightroomParametric
import BrightroomUI
import SwiftUI

struct ResultImage: Identifiable {
  let id: String
  let cgImage: CGImage
  let image: Image
  let metadata: [String]
  let document: PhotosCropDocument?

  init(
    cgImage: CGImage,
    metadata: [String] = [],
    document: PhotosCropDocument? = nil
  ) {
    self.id = UUID().uuidString
    self.cgImage = cgImage
    self.image = .init(decorative: cgImage, scale: 1, orientation: .up)
    self.metadata = metadata
    self.document = document
  }
}

struct RenderedResultView: View {

  let result: ResultImage

  var body: some View {
    List {
      Section {
        result.image
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)

        Text(Self.makeMetadataString(image: result.cgImage))
          .foregroundStyle(.secondary)
          .font(.caption)

        if !result.metadata.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(result.metadata, id: \.self) { line in
              Text(line)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
          }
          .accessibilityIdentifier("rendered-result-edit-metadata")
        }
      } header: {
        Text("Result")
      }

      if let document = result.document {
        Section {
          // Reusable debug viewer from BrightroomParametric, fed with the
          // features of the document used to produce this render.
          FeatureTreeOutline(nodes: document.demoTreeNodes)
        } header: {
          Text("Feature Tree")
        }
      }
    }
  }

  static func makeMetadataString(image: CGImage) -> String {

    //  let formatter = ByteCountFormatter()
    //  formatter.countStyle = .file
    //
    //  let jpegSize = formatter.string(
    //    fromByteCount: Int64(image.jpegData(compressionQuality: 1)!.count)
    //  )
    //
    let cgImage = image

    let meta = """
      size: \(image.width), \(cgImage.height)
      colorSpace: \(cgImage.colorSpace.map { String(describing: $0) } ?? "null")
      bit-depth: \(cgImage.bitsPerPixel / 4)
      bytesPerRow: \(cgImage.bytesPerRow)
      """

    return meta
  }

}

// MARK: - Document outline

extension PhotosCropDocument {

  /// One node per present feature, in evaluation order: the global effects,
  /// the blur mask, then the crop.
  fileprivate var demoTreeNodes: [FeatureTreeNode] {
    var nodes: [FeatureTreeNode] = []

    let effects: [(title: String, feature: Any?)] = [
      ("Preset", self.effects.preset),
      ("Exposure", self.effects.exposure),
      ("Brightness", self.effects.brightness),
      ("Temperature", self.effects.temperature),
      ("Highlights", self.effects.highlights),
      ("Shadows", self.effects.shadows),
      ("Saturation", self.effects.saturation),
      ("Contrast", self.effects.contrast),
      ("Sharpen", self.effects.sharpen),
      ("Unsharp Mask", self.effects.unsharpMask),
      ("Gaussian Blur", self.effects.gaussianBlur),
      ("Fade", self.effects.fade),
      ("Vignette", self.effects.vignette),
    ]
    for (title, feature) in effects {
      guard let feature else { continue }
      nodes.append(
        Self.demoNode(
          id: "effects.\(nodes.count)",
          title: title,
          feature: feature,
          symbolName: "slider.horizontal.3"
        )
      )
    }

    if let blurMask {
      let strokes = blurMaskStrokeCount(blurMask.maskTree.root)
      var node = Self.demoNode(
        id: "blur-mask",
        title: "Blur Mask",
        feature: blurMask.content,
        symbolName: "circle.dashed.inset.filled"
      )
      node.summary = "\(strokes) stroke\(strokes == 1 ? "" : "s")"
      node.fields.insert(.init(name: "Strokes", value: "\(strokes)"), at: 0)
      nodes.append(node)
    }

    let rect = crop.cropRect
    nodes.append(
      FeatureTreeNode(
        id: "crop",
        title: "Crop",
        typeName: "CropFeature",
        summary: "\(Int(rect.width)) x \(Int(rect.height))",
        isEnabled: crop.isEnabled,
        symbolName: "crop",
        fields: [
          .init(name: "Rect", value: "\(rect)"),
          .init(name: "Rotation", value: "\(crop.rotation)"),
          .init(name: "Straighten", value: String(format: "%.3f rad", crop.straightenRadians)),
        ]
      )
    )

    return nodes
  }

  private func blurMaskStrokeCount(_ node: MaskNode) -> Int {
    if case let .brush(brush) = node {
      return brush.strokes.count
    }
    return 0
  }

  /// A leaf node whose fields are the feature's scalar stored properties.
  private static func demoNode(
    id: String,
    title: String,
    feature: Any,
    symbolName: String
  ) -> FeatureTreeNode {
    let fields = Mirror(reflecting: feature).children.compactMap { child -> FeatureTreeNode.Field? in
      guard let name = child.label, name != "id", name != "isEnabled" else {
        return nil
      }
      switch child.value {
      case let value as Double:
        return .init(name: name, value: String(format: "%.3f", value))
      case let value as String:
        return .init(name: name, value: value)
      case let value as Int:
        return .init(name: name, value: "\(value)")
      default:
        return nil
      }
    }
    return FeatureTreeNode(
      id: id,
      title: title,
      typeName: String(describing: type(of: feature)),
      summary: fields.first.map { "\($0.name): \($0.value)" },
      isEnabled: true,
      symbolName: symbolName,
      fields: fields
    )
  }
}
