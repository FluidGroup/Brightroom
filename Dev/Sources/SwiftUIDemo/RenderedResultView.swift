import BrightroomParametric
import BrightroomUI
import SwiftUI

struct ResultImage: Identifiable {
  let id: String
  let cgImage: CGImage
  let image: Image
  let metadata: [String]
  let feature: PhotosCropFeature?

  init(
    cgImage: CGImage,
    metadata: [String] = [],
    feature: PhotosCropFeature? = nil
  ) {
    self.id = UUID().uuidString
    self.cgImage = cgImage
    self.image = .init(decorative: cgImage, scale: 1, orientation: .up)
    self.metadata = metadata
    self.feature = feature
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

      if let feature = result.feature {
        Section {
          // Reusable debug viewer from BrightroomParametric: it walks the
          // body of the feature used to produce this render.
          FeatureTreeOutline(feature: feature)
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
