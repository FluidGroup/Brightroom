import BrightroomEngine
import SwiftUI
import UIKit

enum MetalBrushSandboxInteractionMode: String, CaseIterable, Identifiable {
  case draw
  case view

  var id: Self { self }

  var title: String {
    switch self {
    case .draw:
      return "Draw"
    case .view:
      return "View"
    }
  }
}

extension MetalBrushSandboxInteractionMode {
  var isDrawingEnabled: Bool {
    switch self {
    case .draw:
      return true
    case .view:
      return false
    }
  }

  var panMinimumNumberOfTouches: Int {
    switch self {
    case .draw:
      return 2
    case .view:
      return 1
    }
  }
}

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
    MetalBrushSandboxRepresentable(source: source)
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

struct MetalBrushSandboxMetrics: Equatable {
  var zoomScale: Double = 1
  var stampCount: Int = 0
  var strokeCount: Int = 0
  var framesPerSecond: Double = 0
}

private struct MetalBrushSandboxRepresentable: UIViewRepresentable {

  let source: MetalBrushSandboxSource

  func makeUIView(context: Context) -> MetalBrushSandboxRootView {
    MetalBrushSandboxRootView(source: source)
  }

  func updateUIView(_ uiView: MetalBrushSandboxRootView, context: Context) {}
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
