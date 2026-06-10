import SwiftUI

struct ResultImage: Identifiable {
  let id: String
  let cgImage: CGImage
  let image: Image
  let metadata: [String]

  init(cgImage: CGImage, metadata: [String] = []) {
    self.id = UUID().uuidString
    self.cgImage = cgImage
    self.image = .init(decorative: cgImage, scale: 1, orientation: .up)
    self.metadata = metadata
  }
}

struct RenderedResultView: View {

  let result: ResultImage

  var body: some View {
    VStack {
      result.image
        .resizable()
        .aspectRatio(contentMode: .fit)
        .padding()

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
