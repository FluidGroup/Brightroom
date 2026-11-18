import AppKit
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// The demo's screens, chosen with the toolbar picker.
///
/// Launching with `-startScreen canvas` selects the canvas screen at launch,
/// so checks can open it without clicking.
enum DemoScreen: String, CaseIterable, Identifiable {
  case parametric
  case canvas

  var id: String { rawValue }

  var title: String {
    switch self {
    case .parametric: "Parametric"
    case .canvas: "Canvas"
    }
  }

  static var atLaunch: DemoScreen {
    UserDefaults.standard.string(forKey: "startScreen").flatMap(DemoScreen.init(rawValue:))
      ?? .parametric
  }
}

/// Switches between the parametric screen and the canvas screen.
struct DemoRootView: View {

  @State private var screen = DemoScreen.atLaunch

  var body: some View {
    Group {
      switch screen {
      case .parametric:
        ParametricMacDemoView()
      case .canvas:
        CanvasDemoView()
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Screen", selection: $screen) {
          ForEach(DemoScreen.allCases) { screen in
            Text(screen.title).tag(screen)
          }
        }
        .pickerStyle(.segmented)
      }
    }
  }
}

/// An `ImageEditorDocument` shown by `ImageEditorCanvas` as a viewer, with a
/// few controls bound to the document's feature.
///
/// On macOS the canvas shows the document's evaluated output and zooms and
/// pans with the trackpad or mouse; the controls change the feature, and the
/// canvas follows.
struct CanvasDemoView: View {

  @State private var document = ImageEditorDocument(source: CanvasDemoSample.makeSourceImage())
  @State private var isImporting = false
  @State private var importError: String?

  var body: some View {
    HStack(spacing: 0) {
      controls
        .frame(width: 300)
        .background(.regularMaterial)

      Divider()

      ImageEditorCanvas(document: $document)
        .editingTarget(nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
      open(result)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Canvas")
        .font(.title3.bold())
      Text("Pinch or scroll with Command to zoom; scroll to pan.")
        .font(.caption)
        .foregroundStyle(.secondary)

      slider(
        "Exposure",
        value: optionalValue(
          get: { $0.effects.exposure?.ev },
          set: { $0.effects.exposure = $1.map { ExposureFeature(ev: $0) } }
        ),
        in: -2...2
      )
      slider(
        "Saturation",
        value: optionalValue(
          get: { $0.effects.saturation?.value },
          set: { $0.effects.saturation = $1.map { SaturationFeature(value: $0) } }
        ),
        in: -1...1
      )
      slider(
        "Vignette",
        value: optionalValue(
          get: { $0.vignette?.value },
          set: { $0.vignette = $1.map { VignetteFeature(value: $0) } }
        ),
        in: 0...2
      )

      HStack {
        Button("Undo") { document.undo() }
        Button("Reset") {
          document.feature = ImageEditorDocument(source: document.source).feature
          document.commit()
        }
      }

      Divider()

      Button("Open Image…") { isImporting = true }
      Button("Sample Image") {
        document = ImageEditorDocument(source: CanvasDemoSample.makeSourceImage())
      }
      if let importError {
        Text(importError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Spacer()
    }
    .padding(20)
  }

  private func slider(
    _ title: String,
    value: Binding<Double>,
    in range: ClosedRange<Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range) { isEditing in
        // The host owns the undo granularity: one step per slider drag.
        if !isEditing { document.commit() }
      }
    }
  }

  /// A binding to an optional adjustment of the feature: zero leaves the
  /// adjustment out, so a neutral control adds nothing to the feature.
  private func optionalValue(
    get: @escaping (ImageEditorFeature) -> Double?,
    set: @escaping (inout ImageEditorFeature, Double?) -> Void
  ) -> Binding<Double> {
    Binding(
      get: { get(document.feature) ?? 0 },
      set: { newValue in
        set(&document.feature, newValue == 0 ? nil : newValue)
      }
    )
  }

  private func open(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let isScoped = url.startAccessingSecurityScopedResource()
      defer {
        if isScoped { url.stopAccessingSecurityScopedResource() }
      }
      let source = try SourceImage(data: Data(contentsOf: url))
      document = ImageEditorDocument(source: source)
      importError = nil
    } catch {
      importError = String(describing: error)
    }
  }
}

/// A generated sample image, so the canvas screen works with no file.
enum CanvasDemoSample {

  static let size = CGSize(width: 1600, height: 1067)

  static func makeSourceImage() -> SourceImage {
    let width = Int(size.width)
    let height = Int(size.height)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let gradient = CGGradient(
      colorsSpace: colorSpace,
      colors: [
        CGColor(srgbRed: 0.06, green: 0.09, blue: 0.13, alpha: 1),
        CGColor(srgbRed: 0.82, green: 0.54, blue: 0.28, alpha: 1),
      ] as CFArray,
      locations: [0, 1]
    )!
    context.drawLinearGradient(
      gradient,
      start: .zero,
      end: CGPoint(x: size.width, y: size.height),
      options: []
    )

    // A checkerboard shows zoom and pan detail.
    let cell = 64
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
    for row in 0..<(height / cell + 1) {
      for column in 0..<(width / cell + 1) where (row + column).isMultiple(of: 2) {
        context.fill(CGRect(x: column * cell, y: row * cell, width: cell, height: cell))
      }
    }

    context.setFillColor(CGColor(srgbRed: 0.96, green: 0.24, blue: 0.18, alpha: 0.8))
    context.fill(CGRect(x: 220, y: 0, width: 180, height: size.height))
    context.setFillColor(CGColor(srgbRed: 0.02, green: 0.46, blue: 0.95, alpha: 0.8))
    context.fill(CGRect(x: 1100, y: 0, width: 200, height: size.height))
    context.setFillColor(CGColor(srgbRed: 1, green: 0.96, blue: 0.7, alpha: 0.9))
    context.fillEllipse(in: CGRect(x: 620, y: 300, width: 420, height: 420))

    return SourceImage(cgImage: context.makeImage()!)
  }
}
