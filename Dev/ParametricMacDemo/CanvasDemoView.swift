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
/// few controls bound to the document's feature, built from the public API
/// as a host builds its own editor on macOS.
///
/// The canvas and the histogram share one `PreviewSourceLoader` per image,
/// so the image is decoded once. The window's toolbar zooms the canvas
/// through an `ImageEditorCanvasReader`, and the histogram and the color
/// under the pointer come from an `OutputAnalysis` of what the canvas shows.
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

      // One loader per image: the canvas and the histogram share its decode.
      PreviewSourceReader(source: document.source) { loader in
        CanvasViewer(document: $document, previewSourceLoader: loader)
      }
      .id(document.source)
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
      open(result)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Canvas")
        .font(.title3.bold())
      Text("Pinch, scroll with Command, or use the toolbar to zoom; scroll to pan.")
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

/// The canvas of one image, with zoom controls in the window's toolbar and a
/// histogram of what it shows. The reader's identity replaces it, zoom and
/// pointer included, when the image changes.
private struct CanvasViewer: View {

  @Binding private var document: ImageEditorDocument
  private let previewSourceLoader: PreviewSourceLoader

  @State private var zoom: ImageEditorCanvas.Zoom?
  @State private var pointer: CGPoint?

  init(document: Binding<ImageEditorDocument>, previewSourceLoader: PreviewSourceLoader) {
    self._document = document
    self.previewSourceLoader = previewSourceLoader
  }

  var body: some View {
    ImageEditorCanvasReader { canvas in
      ImageEditorCanvas(document: $document, previewSourceLoader: previewSourceLoader)
        .editingTarget(nil)
        .onZoomChange { zoom = $0 }
        .onPointerChange { pointer = $0 }
        .canvasAccessibilityLabel("Photo")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottomLeading) {
          if let previewSource = previewSourceLoader.previewSource {
            HistogramPanel(feature: document.feature, previewSource: previewSource, pointer: pointer)
              .padding(12)
              .allowsHitTesting(false)
          }
        }
        .toolbar {
          zoomControls(canvas)
        }
    }
  }

  /// Zoom out, a slider from the fit to the largest zoom, zoom in, zoom to
  /// fit, and the zoom in percent. They wait for the canvas's first report.
  @ToolbarContentBuilder
  private func zoomControls(_ canvas: ImageEditorCanvasProxy) -> some ToolbarContent {
    ToolbarItemGroup {
      Button("Zoom Out", systemImage: "minus.magnifyingglass") {
        canvas.zoomOut()
      }
      .disabled(zoom?.isFitted ?? true)

      // The reports move the slider, so it follows a pinch too; dragging it
      // zooms at once.
      Slider(value: Binding { zoom?.fraction ?? 0 } set: { canvas.zoom(toFraction: $0) }, in: 0...1)
        .frame(width: 100)
        .disabled(zoom == nil)

      Button("Zoom In", systemImage: "plus.magnifyingglass") {
        canvas.zoomIn()
      }
      .disabled(zoom?.isAtMaximum ?? true)

      Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
        canvas.zoomToFit()
      }
      .disabled(zoom?.isFitted ?? true)

      // Device pixels per pixel of the image.
      Text(zoom?.percent.formatted(.percent) ?? "")
        .monospacedDigit()
        .frame(width: 48, alignment: .trailing)
    }
  }
}

/// A histogram of what the canvas shows and the color under the pointer,
/// from one `OutputAnalysis` of the feature over the shared preview source.
private struct HistogramPanel: View {

  private let feature: ImageEditorFeature
  private let previewSource: PreviewSource
  private let pointer: CGPoint?

  @State private var analysis: OutputAnalysis?

  init(feature: ImageEditorFeature, previewSource: PreviewSource, pointer: CGPoint?) {
    self.feature = feature
    self.previewSource = previewSource
    self.pointer = pointer
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Canvas { context, size in
        guard let levels = analysis?.histogram.levels() else {
          return
        }

        // Pure primaries add up to gray where the channels overlap.
        context.blendMode = .plusLighter
        let channels = [
          (levels.red, Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 0.6)),
          (levels.green, Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 0.6)),
          (levels.blue, Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 0.6)),
        ]
        for (levels, color) in channels {
          context.fill(Self.area(under: levels, in: CGRect(origin: .zero, size: size)), with: .color(color))
        }
      }
      .frame(height: 72)

      Text(readout)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .frame(width: 220)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
    .task(id: feature) {
      // A newer feature cancels the wait, so a slider drag is analyzed once
      // it pauses rather than at every step.
      try? await Task.sleep(for: .milliseconds(100))
      guard Task.isCancelled == false else {
        return
      }

      let analysis = await OutputAnalysis.analyze(feature, over: previewSource)
      if Task.isCancelled == false {
        self.analysis = analysis
      }
    }
  }

  /// The 8-bit Display P3 values of the pixel under the pointer.
  private var readout: String {
    guard let pointer, let color = analysis?.color(atOutputPoint: pointer) else {
      return "R ---  G ---  B ---"
    }
    return "R \(color.red)  G \(color.green)  B \(color.blue)"
  }

  /// The area under `levels`, from the left edge of `rect` to its right edge.
  private static func area(under levels: [Double], in rect: CGRect) -> Path {
    Path { path in
      let step = rect.width / CGFloat(levels.count - 1)
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      for (index, level) in levels.enumerated() {
        path.addLine(to: CGPoint(x: rect.minX + step * CGFloat(index), y: rect.maxY - rect.height * level))
      }
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.closeSubpath()
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
