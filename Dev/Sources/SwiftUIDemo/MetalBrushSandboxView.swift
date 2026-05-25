import BrightroomEngine
import BrightroomUI
import SwiftUI
import UIKit

struct MetalBrushSandboxView: View {

  @Environment(\.dismiss) private var dismiss

  private let source: MetalBrushSandboxSource

  init(image: UIImage = Asset.l1000316.image) {
    self.source = .image(image)
  }

  init(fileURL: URL) {
    self.source = .fileURL(fileURL)
  }

  var body: some View {
    MetalBrushSandboxRootView(source: source)
      .accessibilityIdentifier("metal-brush-sandbox-canvas")
    .navigationTitle("Metal Brush Sandbox")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button {
          dismiss()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .accessibilityIdentifier("metal-brush-back")
      }
    }
  }
}

enum MetalBrushSandboxSource {
  case image(UIImage)
  case fileURL(URL)

  func makeImageProvider() -> ImageProvider {
    switch self {
    case let .image(image):
      return .init(image: image)
    case let .fileURL(fileURL):
      return try! .init(fileURL: fileURL)
    }
  }
}
