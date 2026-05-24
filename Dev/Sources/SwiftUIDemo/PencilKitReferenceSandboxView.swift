import IOSurface
import PencilKit
import SwiftUI
import UIKit

struct PencilKitReferenceSandboxView: View {

  @State private var metrics = PencilKitReferenceMetrics()
  @State private var resetGeneration = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      PencilKitReferenceCanvasRepresentable(
        metrics: $metrics,
        resetGeneration: resetGeneration
      )
        .accessibilityIdentifier("pencilkit-reference-canvas")

      metricsPanel
        .padding(12)
        .allowsHitTesting(false)
    }
    .background(Color(uiColor: .systemBackground))
    .navigationTitle("PencilKit Reference")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button("Reset") {
          resetGeneration += 1
        }
        .accessibilityIdentifier("pencilkit-reference-reset")
      }
    }
  }

  private var metricsPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Text("Zoom \(metrics.zoomScale, format: .number.precision(.fractionLength(2)))x")
        Text("Subviews \(metrics.subviewClassNames.count)")
        Text("Gestures \(metrics.gestureClassNames.count)")
      }

      Text("Offset \(metrics.contentOffsetDescription)")
      Text("Content \(metrics.contentSizeDescription)")
      Text("Visible \(metrics.visibleRectDescription)")

      if metrics.subviewClassNames.isEmpty == false {
        Text("View \(metrics.subviewClassNames.joined(separator: " > "))")
          .lineLimit(2)
      }

      if metrics.layerClassNames.isEmpty == false {
        Text("Layer \(metrics.layerClassNames.joined(separator: " > "))")
          .lineLimit(2)
      }
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.primary)
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityIdentifier("pencilkit-reference-metrics")
  }
}

private struct PencilKitReferenceCanvasRepresentable: UIViewRepresentable {

  @Binding var metrics: PencilKitReferenceMetrics
  let resetGeneration: Int

  func makeCoordinator() -> Coordinator {
    Coordinator(
      metrics: $metrics,
      resetGeneration: resetGeneration
    )
  }

  func makeUIView(context: Context) -> PKCanvasView {
    let canvasView = PKCanvasView()
    canvasView.accessibilityIdentifier = "pencilkit-reference-pkcanvas"
    canvasView.backgroundColor = .systemBackground
    canvasView.isOpaque = true
    canvasView.alwaysBounceHorizontal = true
    canvasView.alwaysBounceVertical = true
    canvasView.bouncesZoom = true
    canvasView.minimumZoomScale = 0.5
    canvasView.maximumZoomScale = 16
    canvasView.contentSize = context.coordinator.canvasSize
    canvasView.drawingPolicy = .anyInput
    canvasView.tool = PKInkingTool(.pen, color: .systemCyan, width: 10)
    canvasView.delegate = context.coordinator

    context.coordinator.canvasView = canvasView
    PencilKitReferenceDebugProbe.canvasView = canvasView

    DispatchQueue.main.async {
      context.coordinator.installToolPicker(for: canvasView)
      context.coordinator.installDebugDrawingIfNeeded(on: canvasView)
      context.coordinator.refreshMetrics()
      context.coordinator.refreshMetricsAfterDebugDrawingIfNeeded()
    }

    return canvasView
  }

  func updateUIView(_ canvasView: PKCanvasView, context: Context) {
    context.coordinator.metrics = $metrics
    context.coordinator.applyResetIfNeeded(
      resetGeneration,
      to: canvasView
    )

    if canvasView.contentSize != context.coordinator.canvasSize {
      canvasView.contentSize = context.coordinator.canvasSize
    }

    DispatchQueue.main.async {
      context.coordinator.refreshMetrics()
    }
  }

  final class Coordinator: NSObject, PKCanvasViewDelegate {

    let canvasSize = CGSize(width: 2400, height: 1800)
    var metrics: Binding<PencilKitReferenceMetrics>
    private var appliedResetGeneration: Int
    private var toolPicker: PKToolPicker?
    weak var canvasView: PKCanvasView?
    private var lastDebugDumpTime: CFTimeInterval = 0
    private var debugDumpIndex = 0
    private let debugDumpURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pencilkit-reference-layer-dumps.txt")
    private let debugDumpEnabled = ProcessInfo.processInfo.environment["PENCILKIT_REFERENCE_AUTODUMP"] == "1"
      || ProcessInfo.processInfo.arguments.contains("--pencilkit-reference-autodump")

    init(
      metrics: Binding<PencilKitReferenceMetrics>,
      resetGeneration: Int
    ) {
      self.metrics = metrics
      self.appliedResetGeneration = resetGeneration
    }

    func installToolPicker(for canvasView: PKCanvasView) {
      let toolPicker = PKToolPicker()
      toolPicker.addObserver(canvasView)
      toolPicker.setVisible(true, forFirstResponder: canvasView)
      canvasView.becomeFirstResponder()
      self.toolPicker = toolPicker
    }

    func applyResetIfNeeded(
      _ resetGeneration: Int,
      to canvasView: PKCanvasView
    ) {
      guard appliedResetGeneration != resetGeneration else {
        return
      }

      canvasView.drawing = PKDrawing()
      appliedResetGeneration = resetGeneration
      refreshMetrics()
    }

    func installDebugDrawingIfNeeded(on canvasView: PKCanvasView) {
      guard debugDumpEnabled else {
        return
      }

      guard canvasView.drawing.strokes.isEmpty else {
        return
      }

      let points = stride(from: 0, through: 1, by: 0.04).enumerated().map { index, progress in
        PKStrokePoint(
          location: CGPoint(
            x: 160 + CGFloat(progress) * 420,
            y: 280 + CGFloat(progress) * 360
          ),
          timeOffset: TimeInterval(index) * 0.01,
          size: CGSize(width: 10, height: 10),
          opacity: 1,
          force: 1,
          azimuth: 0,
          altitude: .pi / 2
        )
      }
      let path = PKStrokePath(controlPoints: points, creationDate: Date())
      let stroke = PKStroke(
        ink: PKInk(.pen, color: .systemCyan),
        path: path
      )
      canvasView.drawing = PKDrawing(strokes: [stroke])
    }

    func refreshMetricsAfterDebugDrawingIfNeeded() {
      guard debugDumpEnabled else {
        return
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        self?.refreshMetrics()
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      refreshMetrics()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      refreshMetrics()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
      refreshMetrics()
    }

    func refreshMetrics() {
      guard let canvasView else {
        return
      }

      metrics.wrappedValue = PencilKitReferenceMetrics(canvasView: canvasView)
      dumpDebugLayerSnapshotIfNeeded(for: canvasView)
    }

    private func dumpDebugLayerSnapshotIfNeeded(for canvasView: PKCanvasView) {
      guard debugDumpEnabled else {
        return
      }

      let now = CACurrentMediaTime()
      guard now - lastDebugDumpTime > 0.5 else {
        return
      }

      lastDebugDumpTime = now
      debugDumpIndex += 1
      let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
      let dump = """
        PK_REFERENCE_LAYER_DUMP_BEGIN index=\(debugDumpIndex) os=\(osVersion)
        \(PencilKitReferenceDebugFormatter.summary(for: canvasView))
        \(PencilKitReferenceDebugFormatter.detailedLayerHierarchy(from: canvasView.layer))
        PK_REFERENCE_LAYER_DUMP_END index=\(debugDumpIndex)
        """
      print(dump)
      appendDebugDump(dump)
    }

    private func appendDebugDump(_ dump: String) {
      guard let data = (dump + "\n").data(using: .utf8) else {
        return
      }

      if FileManager.default.fileExists(atPath: debugDumpURL.path) == false {
        FileManager.default.createFile(atPath: debugDumpURL.path, contents: nil)
      }

      guard let handle = try? FileHandle(forWritingTo: debugDumpURL) else {
        return
      }

      defer {
        try? handle.close()
      }
      do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } catch {
        print("PK_REFERENCE_LAYER_DUMP_WRITE_FAILED \(error)")
      }
    }
  }
}

private struct PencilKitReferenceMetrics: Equatable {

  var zoomScale: CGFloat = 1
  var contentOffset: CGPoint = .zero
  var contentSize: CGSize = .zero
  var boundsSize: CGSize = .zero
  var drawingBounds: CGRect = .null
  var subviewClassNames: [String] = []
  var layerClassNames: [String] = []
  var gestureClassNames: [String] = []

  init() {}

  init(canvasView: PKCanvasView) {
    zoomScale = canvasView.zoomScale
    contentOffset = canvasView.contentOffset
    contentSize = canvasView.contentSize
    boundsSize = canvasView.bounds.size
    drawingBounds = canvasView.drawing.bounds
    subviewClassNames = canvasView.subviews.map { String(describing: type(of: $0)) }
    layerClassNames = canvasView.layer.sublayers?.map { String(describing: type(of: $0)) } ?? []
    gestureClassNames = canvasView.gestureRecognizers?.map { String(describing: type(of: $0)) } ?? []
  }

  var contentOffsetDescription: String {
    "\(Int(contentOffset.x)), \(Int(contentOffset.y))"
  }

  var contentSizeDescription: String {
    "\(Int(contentSize.width)) x \(Int(contentSize.height))"
  }

  var visibleRectDescription: String {
    let width = zoomScale > 0 ? boundsSize.width / zoomScale : 0
    let height = zoomScale > 0 ? boundsSize.height / zoomScale : 0
    return "\(Int(contentOffset.x)), \(Int(contentOffset.y)), \(Int(width)) x \(Int(height))"
  }
}

@objc(PencilKitReferenceDebugProbe)
final class PencilKitReferenceDebugProbe: NSObject {

  static var canvasView: PKCanvasView?

  @objc static func canvasSummary() -> NSString {
    guard let canvasView else {
      return "PencilKitReferenceDebugProbe.canvasView is nil"
    }

    return PencilKitReferenceDebugFormatter.summary(for: canvasView) as NSString
  }

  @objc static func canvasViewHierarchy() -> NSString {
    guard let canvasView else {
      return "PencilKitReferenceDebugProbe.canvasView is nil"
    }

    return PencilKitReferenceDebugFormatter.viewHierarchy(from: canvasView) as NSString
  }

  @objc static func canvasLayerHierarchy() -> NSString {
    guard let canvasView else {
      return "PencilKitReferenceDebugProbe.canvasView is nil"
    }

    return PencilKitReferenceDebugFormatter.layerHierarchy(from: canvasView.layer) as NSString
  }

  @objc static func canvasDetailedLayerHierarchy() -> NSString {
    guard let canvasView else {
      return "PencilKitReferenceDebugProbe.canvasView is nil"
    }

    return PencilKitReferenceDebugFormatter.detailedLayerHierarchy(from: canvasView.layer) as NSString
  }

  @objc static func dumpCanvasSummary() {
    print(canvasSummary())
  }

  @objc static func dumpCanvasViewHierarchy() {
    print(canvasViewHierarchy())
  }

  @objc static func dumpCanvasLayerHierarchy() {
    print(canvasLayerHierarchy())
  }

  @objc static func dumpCanvasDetailedLayerHierarchy() {
    print(canvasDetailedLayerHierarchy())
  }
}

private enum PencilKitReferenceDebugFormatter {

  static func summary(for canvasView: PKCanvasView) -> String {
    let gestureLines = (canvasView.gestureRecognizers ?? []).map { recognizer in
      let typeName = String(describing: type(of: recognizer))
      return "  \(typeName) state=\(recognizer.state.rawValue) enabled=\(recognizer.isEnabled) cancels=\(recognizer.cancelsTouchesInView)"
    }
    .joined(separator: "\n")

    return """
    PKCanvasView summary
    frame=\(canvasView.frame)
    bounds=\(canvasView.bounds)
    contentSize=\(canvasView.contentSize)
    contentOffset=\(canvasView.contentOffset)
    zoomScale=\(canvasView.zoomScale)
    minZoom=\(canvasView.minimumZoomScale)
    maxZoom=\(canvasView.maximumZoomScale)
    drawingBounds=\(canvasView.drawing.bounds)
    subviews=\(canvasView.subviews.map { String(describing: type(of: $0)) })
    layers=\((canvasView.layer.sublayers ?? []).map { String(describing: type(of: $0)) })
    gestures:
    \(gestureLines)
    """
  }

  static func viewHierarchy(from view: UIView) -> String {
    lines(for: view, depth: 0).joined(separator: "\n")
  }

  static func layerHierarchy(from layer: CALayer) -> String {
    lines(for: layer, depth: 0).joined(separator: "\n")
  }

  static func detailedLayerHierarchy(from layer: CALayer) -> String {
    detailedLines(for: layer, depth: 0).joined(separator: "\n")
  }

  private static func lines(for view: UIView, depth: Int) -> [String] {
    let indent = String(repeating: "  ", count: depth)
    let viewLine = "\(indent)\(String(describing: type(of: view))) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden) alpha=\(view.alpha)"
    return [viewLine] + view.subviews.flatMap { lines(for: $0, depth: depth + 1) }
  }

  private static func lines(for layer: CALayer, depth: Int) -> [String] {
    let indent = String(repeating: "  ", count: depth)
    let layerLine = "\(indent)\(String(describing: type(of: layer))) frame=\(layer.frame) bounds=\(layer.bounds) hidden=\(layer.isHidden) opacity=\(layer.opacity)"
    return [layerLine] + (layer.sublayers ?? []).flatMap { lines(for: $0, depth: depth + 1) }
  }

  private static func detailedLines(for layer: CALayer, depth: Int) -> [String] {
    let indent = String(repeating: "  ", count: depth)
    let layerLine = [
      "\(indent)\(String(describing: type(of: layer)))",
      "name=\(layer.name ?? "-")",
      "frame=\(layer.frame)",
      "bounds=\(layer.bounds)",
      "contentsScale=\(String(format: "%.4f", layer.contentsScale))",
      "rasterizationScale=\(String(format: "%.4f", layer.rasterizationScale))",
      "opaque=\(layer.isOpaque)",
      "hidden=\(layer.isHidden)",
      "opacity=\(String(format: "%.3f", layer.opacity))",
      "contents=\(contentsDescription(for: layer.contents))",
    ].joined(separator: " ")
    return [layerLine] + (layer.sublayers ?? []).flatMap { detailedLines(for: $0, depth: depth + 1) }
  }

  private static func contentsDescription(for contents: Any?) -> String {
    guard let contents else {
      return "nil"
    }

    if let surface = contents as? IOSurface {
      return [
        "IOSurface",
        "width=\(IOSurfaceGetWidth(surface))",
        "height=\(IOSurfaceGetHeight(surface))",
        "bytesPerRow=\(IOSurfaceGetBytesPerRow(surface))",
        "pixelFormat=\(fourCCDescription(IOSurfaceGetPixelFormat(surface)))",
        "values=\(surfaceValuesDescription(surface))",
      ].joined(separator: "(") + ")"
    }

    return String(describing: type(of: contents))
  }

  private static func fourCCDescription(_ value: OSType) -> String {
    let scalarValues = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    let string = String(bytes: scalarValues, encoding: .macOSRoman) ?? "\(value)"
    return "\(string)/\(value)"
  }

  private static func surfaceValuesDescription(_ surface: IOSurface) -> String {
    guard let values = IOSurfaceCopyAllValues(surface) as? [String: Any] else {
      return "nil"
    }

    return values.keys.sorted().map { key in
      "\(key):\(values[key] ?? "nil")"
    }
    .joined(separator: ",")
  }
}
