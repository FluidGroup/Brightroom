import BrightroomEngine
import BrightroomUI
import SwiftUI

struct EditingCanvasCropProbeView: View {

  private enum DisplayRectMode: String, CaseIterable, Identifiable {
    case full = "Full"
    case fourFive = "4:5"
    case fiveFour = "5:4"
    case square = "Square"
    case leftHalf = "Left"

    var id: Self { self }
  }

  private enum RenderMode: String, CaseIterable, Identifiable {
    case viewport = "Viewport"
    case rendered = "Rendered"

    var id: Self { self }

    var canvasMode: EditingCanvasMode {
      switch self {
      case .viewport:
        return .viewportBase
      case .rendered:
        return .renderedEditPreview
      }
    }
  }

  @State private var editingStack = Mocks.makeEditingStack(image: Asset.l1000316.image)
  @State private var isLoaded = false
  @State private var imageSize: CGSize = .zero
  @State private var displayRectMode: DisplayRectMode = .fourFive
  @State private var renderMode: RenderMode = .viewport
  @State private var metrics = EditingCanvasMetrics()

  var body: some View {
    VStack(spacing: 16) {
      VStack(spacing: 8) {
        Picker("Display", selection: $displayRectMode) {
          ForEach(DisplayRectMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Picker("Render", selection: $renderMode) {
          ForEach(RenderMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }
      .padding(.horizontal, 16)

      ZStack {
        Color(uiColor: .secondarySystemBackground)

        if isLoaded {
          SwiftUIEditingCanvasView(
            editingStack: editingStack,
            mode: renderMode.canvasMode
          )
          .interactionMode(.view)
          .displayedImageRect(displayRect)
          .onMetricsChange { metrics = $0 }
          .overlay(alignment: .topLeading) {
            Rectangle()
              .stroke(Color.blue.opacity(0.55), lineWidth: 2)
          }
          .accessibilityIdentifier("editing.canvas.crop.probe.canvas")
        } else {
          ProgressView()
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .padding(.horizontal, 16)

      VStack(alignment: .leading, spacing: 4) {
        Text("image: \(debugDescription(imageSize))")
        Text("display: \(debugDescription(displayRect))")
        Text(String(format: "zoom: %.3f  fps: %.0f", metrics.zoomScale, metrics.framesPerSecond))
      }
      .font(.system(size: 12, design: .monospaced))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)

      Spacer()
    }
    .navigationTitle("Canvas Crop Probe")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      editingStack.start {
        imageSize = editingStack.loadedState?.metadata.imageSize ?? .zero
        isLoaded = true
      }
    }
  }

  private var displayRect: CGRect? {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return nil
    }

    let imageBounds = CGRect(origin: .zero, size: imageSize)
    switch displayRectMode {
    case .full:
      return imageBounds
    case .fourFive:
      return PixelAspectRatio(width: 4, height: 5).rectThatFits(in: imageBounds)
    case .fiveFour:
      return PixelAspectRatio(width: 5, height: 4).rectThatFits(in: imageBounds)
    case .square:
      return PixelAspectRatio(width: 1, height: 1).rectThatFits(in: imageBounds)
    case .leftHalf:
      return CGRect(
        x: 0,
        y: 0,
        width: imageSize.width / 2,
        height: imageSize.height
      )
    }
  }

  private func debugDescription(_ size: CGSize) -> String {
    "\(Int(size.width))x\(Int(size.height))"
  }

  private func debugDescription(_ rect: CGRect?) -> String {
    guard let rect else {
      return "nil"
    }

    return String(
      format: "x:%.0f y:%.0f w:%.0f h:%.0f",
      rect.minX,
      rect.minY,
      rect.width,
      rect.height
    )
  }
}

#Preview {
  NavigationStack {
    EditingCanvasCropProbeView()
  }
}
