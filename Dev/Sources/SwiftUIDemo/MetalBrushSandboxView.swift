import CoreImage
import IOSurface
import MetalKit
import os
import simd
import SwiftUI
import UIKit

struct MetalBrushSandboxView: View {

  @Environment(\.dismiss) private var dismiss

  private let image: UIImage

  @State private var brushSize: Double = 56
  @State private var blurRadius: Double = 18
  @State private var hardness: Double = 0.72
  @State private var opacity: Double = 0.9
  @State private var spacing: Double = 0.18
  @State private var smoothingAlgorithm: MetalBrushStrokeSmoothingAlgorithm = .bezier
  @State private var smoothingStrength: Double = 0.85
  @State private var resetID = 0
  @State private var metrics = MetalBrushSandboxMetrics()

  init(image: UIImage = Asset.l1000316.image) {
    self.image = image
  }

  var body: some View {
    VStack(spacing: 0) {
      MetalBrushSandboxRepresentable(
        image: image,
        blurRadius: blurRadius,
        brush: .init(
          size: brushSize,
          hardness: hardness,
          opacity: opacity,
          spacing: spacing
        ),
        smoothing: .init(
          algorithm: smoothingAlgorithm,
          strength: smoothingStrength
        ),
        resetID: resetID,
        onMetricsChange: { metrics = $0 }
      )
      .accessibilityIdentifier("metal-brush-sandbox-canvas")

      controls
    }
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

  private var controls: some View {
    VStack(spacing: 12) {
      HStack {
        Spacer()

        Button("Reset") {
          resetID += 1
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("metal-brush-reset")
      }

      metricsView
        .accessibilityIdentifier("metal-brush-metrics")

      smoothingPicker
        .accessibilityIdentifier("metal-brush-smoothing")

      slider(title: "Strength", value: $smoothingStrength, range: 0...1)
        .accessibilityIdentifier("metal-brush-smoothing-strength")

      slider(title: "Blur", value: $blurRadius, range: 0...40)
        .accessibilityIdentifier("metal-brush-blur-radius")
      slider(title: "Size", value: $brushSize, range: 8...140)
        .accessibilityIdentifier("metal-brush-size")
      slider(title: "Hardness", value: $hardness, range: 0...1)
        .accessibilityIdentifier("metal-brush-hardness")
      slider(title: "Opacity", value: $opacity, range: 0.05...1)
        .accessibilityIdentifier("metal-brush-opacity")
      slider(title: "Spacing", value: $spacing, range: 0.05...0.6)
        .accessibilityIdentifier("metal-brush-spacing")
    }
    .padding(16)
    .background(.regularMaterial)
  }

  private var metricsView: some View {
    HStack(spacing: 10) {
      Text("Zoom \(metrics.zoomScale, format: .number.precision(.fractionLength(2)))x")
      Text("Strokes \(metrics.strokeCount)")
      Text("Stamps \(metrics.stampCount)")
      Spacer(minLength: 0)
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Zoom \(metrics.zoomScale.formatted(.number.precision(.fractionLength(2))))x Strokes \(metrics.strokeCount) Stamps \(metrics.stampCount)"
    )
  }

  private var smoothingPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Smoothing")
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)

      Picker("Smoothing", selection: $smoothingAlgorithm) {
        ForEach(MetalBrushStrokeSmoothingAlgorithm.allCases) { algorithm in
          Text(algorithm.title).tag(algorithm)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  private func slider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>
  ) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)

      Slider(value: value, in: range)

      Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 52, alignment: .trailing)
    }
  }
}

private struct MetalBrushSandboxMetrics: Equatable {
  var zoomScale: Double = 1
  var stampCount: Int = 0
  var strokeCount: Int = 0
}

private struct MetalBrushSandboxRepresentable: UIViewRepresentable {

  let image: UIImage
  let blurRadius: Double
  let brush: MetalBrushSandboxBrush
  let smoothing: MetalBrushStrokeSmoothingConfiguration
  let resetID: Int
  let onMetricsChange: (MetalBrushSandboxMetrics) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(resetID: resetID)
  }

  func makeUIView(context: Context) -> MetalBrushSandboxHostView {
    let view = MetalBrushSandboxHostView(canvasSize: image.metalBrushSandboxCanvasSize)
    view.setCanvasImage(image, blurRadius: blurRadius)
    view.onMetricsChange = { metrics in
      context.coordinator.publish(metrics, to: onMetricsChange)
    }
    view.configure(
      brush: brush,
      smoothing: smoothing
    )
    return view
  }

  func updateUIView(_ uiView: MetalBrushSandboxHostView, context: Context) {
    uiView.setCanvasImage(image, blurRadius: blurRadius)
    uiView.onMetricsChange = { metrics in
      context.coordinator.publish(metrics, to: onMetricsChange)
    }
    uiView.configure(
      brush: brush,
      smoothing: smoothing
    )

    guard context.coordinator.resetID != resetID else {
      return
    }

    context.coordinator.resetID = resetID
    uiView.reset()
  }

  final class Coordinator {
    var resetID: Int
    private var metrics = MetalBrushSandboxMetrics()

    init(resetID: Int) {
      self.resetID = resetID
    }

    func publish(
      _ newMetrics: MetalBrushSandboxMetrics,
      to handler: @escaping (MetalBrushSandboxMetrics) -> Void
    ) {
      guard metrics != newMetrics else {
        return
      }

      metrics = newMetrics
      DispatchQueue.main.async {
        handler(newMetrics)
      }
    }
  }
}

private struct MetalBrushSandboxBrush: Equatable {
  var size: Double
  var hardness: Double
  var opacity: Double
  var spacing: Double
}

private struct MetalBrushSandboxStrokeRecord {
  let stamps: [CGPoint]
  let brush: MetalBrushSandboxBrush
  let bounds: CGRect

  init(stamps: [CGPoint], brush: MetalBrushSandboxBrush) {
    self.stamps = stamps
    self.brush = brush

    let radius = CGFloat(brush.size / 2)
    var minX = CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    for stamp in stamps {
      if stamp.x < minX { minX = stamp.x }
      if stamp.y < minY { minY = stamp.y }
      if stamp.x > maxX { maxX = stamp.x }
      if stamp.y > maxY { maxY = stamp.y }
    }
    if stamps.isEmpty {
      self.bounds = .zero
    } else {
      self.bounds = CGRect(
        x: minX - radius - 1,
        y: minY - radius - 1,
        width: (maxX - minX) + 2 * radius + 2,
        height: (maxY - minY) + 2 * radius + 2
      )
    }
  }
}

private struct MetalBrushStrokeSmoothingConfiguration: Equatable {
  var algorithm: MetalBrushStrokeSmoothingAlgorithm
  var strength: Double
}

private enum MetalBrushStrokeSmoothingAlgorithm: String, CaseIterable, Identifiable {
  case raw
  case bezier
  case catmullRom
  case movingAverage

  var id: Self {
    return self
  }

  var title: String {
    switch self {
    case .raw:
      return "Raw"
    case .bezier:
      return "Bezier"
    case .catmullRom:
      return "Catmull"
    case .movingAverage:
      return "Avg"
    }
  }
}

private struct MetalBrushStrokeSmoother {

  private var configuration = MetalBrushStrokeSmoothingConfiguration(
    algorithm: .bezier,
    strength: 0.85
  )
  private var stabilizer = StrokeStabilizer()
  private var bezier = BezierStrokeSmoother()
  private var catmullRom = CatmullRomStrokeSmoother()
  private var movingAverage = MovingAverageStrokeSmoother()

  mutating func configure(_ configuration: MetalBrushStrokeSmoothingConfiguration) {
    guard self.configuration != configuration else {
      return
    }

    self.configuration = configuration
    reset()
  }

  mutating func begin(at point: CGPoint) {
    reset()
    stabilizer.begin(at: point)

    switch configuration.algorithm {
    case .raw:
      break
    case .bezier:
      bezier.begin(at: point)
    case .catmullRom:
      catmullRom.begin(at: point)
    case .movingAverage:
      movingAverage.begin(at: point)
    }
  }

  mutating func append(
    _ inputPoints: [CGPoint],
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    let preparedPoints = stabilizer.append(
      inputPoints,
      strength: configuration.strength,
      sampleDistance: sampleDistance
    )
    return appendPrepared(preparedPoints, sampleDistance: sampleDistance)
  }

  mutating func finish(
    at point: CGPoint,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    let preparedPoints = stabilizer.finish(
      at: point,
      strength: configuration.strength,
      sampleDistance: sampleDistance
    )
    guard let endPoint = preparedPoints.last else {
      reset()
      return []
    }

    var output = appendPrepared(Array(preparedPoints.dropLast()), sampleDistance: sampleDistance)
    output += finishPrepared(at: endPoint, sampleDistance: sampleDistance)
    reset()
    return output
  }

  mutating func reset() {
    stabilizer.reset()
    bezier.reset()
    catmullRom.reset()
    movingAverage.reset()
  }

  private mutating func appendPrepared(
    _ points: [CGPoint],
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    switch configuration.algorithm {
    case .raw:
      return points
    case .bezier:
      return bezier.append(points, sampleDistance: sampleDistance)
    case .catmullRom:
      return catmullRom.append(points, sampleDistance: sampleDistance)
    case .movingAverage:
      return movingAverage.append(points, sampleDistance: sampleDistance)
    }
  }

  private mutating func finishPrepared(
    at point: CGPoint,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    switch configuration.algorithm {
    case .raw:
      return [point]
    case .bezier:
      return bezier.finish(at: point, sampleDistance: sampleDistance)
    case .catmullRom:
      return catmullRom.finish(at: point, sampleDistance: sampleDistance)
    case .movingAverage:
      return movingAverage.finish(at: point, sampleDistance: sampleDistance)
    }
  }
}

private struct StrokeStabilizer {

  private var stabilizedPoint: CGPoint?

  mutating func begin(at point: CGPoint) {
    reset()
    stabilizedPoint = point
  }

  mutating func append(
    _ inputPoints: [CGPoint],
    strength: Double,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    inputPoints.map {
      append($0, strength: strength, sampleDistance: sampleDistance)
    }
  }

  mutating func finish(
    at point: CGPoint,
    strength: Double,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    let stabilizedEnd = append(point, strength: strength, sampleDistance: sampleDistance)
    guard strength > 0.001 else {
      reset()
      return [point]
    }

    let catchUpPoints = LinearSegment(start: stabilizedEnd, end: point)
      .sampledPoints(maxSegmentLength: sampleDistance)
      .dropFirst()

    reset()
    return [stabilizedEnd] + Array(catchUpPoints)
  }

  mutating func reset() {
    stabilizedPoint = nil
  }

  private mutating func append(
    _ point: CGPoint,
    strength: Double,
    sampleDistance: CGFloat
  ) -> CGPoint {
    guard let currentPoint = stabilizedPoint else {
      stabilizedPoint = point
      return point
    }

    let clampedStrength = min(max(CGFloat(strength), 0), 1)
    guard clampedStrength > 0.001 else {
      stabilizedPoint = point
      return point
    }

    let distance = currentPoint.distance(to: point)
    let lagDistance = max(sampleDistance, 1) * (2 + clampedStrength * 24)
    let distanceResponse = min(distance / lagDistance, 1)
    let baseResponse = max(0.035, 1 - clampedStrength * 0.965)
    let response = min(max(baseResponse + distanceResponse * 0.16, 0.035), 1)
    let nextPoint = currentPoint.interpolate(to: point, progress: response)
    stabilizedPoint = nextPoint
    return nextPoint
  }
}

private struct BezierStrokeSmoother {

  private var controlPointIndex = 0
  private var points = Array(repeating: CGPoint.zero, count: 5)

  mutating func begin(at point: CGPoint) {
    reset()
    points[0] = point
  }

  mutating func append(
    _ inputPoints: [CGPoint],
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    inputPoints.flatMap { append($0, sampleDistance: sampleDistance) }
  }

  mutating func finish(
    at point: CGPoint,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    var output = append(point, sampleDistance: sampleDistance)

    switch controlPointIndex {
    case 0:
      break

    case 1:
      output.append(points[1])

    case 2:
      output += QuadraticBezierSegment(
        start: points[0],
        control: points[1],
        end: points[2]
      )
      .sampledPoints(maxSegmentLength: sampleDistance)

    case 3:
      output += CubicBezierSegment(
        start: points[0],
        control1: points[1],
        control2: points[2],
        end: points[3]
      )
      .sampledPoints(maxSegmentLength: sampleDistance)

    default:
      break
    }

    reset()
    return output
  }

  mutating func reset() {
    controlPointIndex = 0
    points = Array(repeating: CGPoint.zero, count: 5)
  }

  private mutating func append(
    _ point: CGPoint,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    controlPointIndex += 1
    points[controlPointIndex] = point

    guard controlPointIndex == 4 else {
      return []
    }

    points[3] = points[2].midpoint(to: points[4])

    let smoothedPoints = CubicBezierSegment(
      start: points[0],
      control1: points[1],
      control2: points[2],
      end: points[3]
    )
    .sampledPoints(maxSegmentLength: sampleDistance)

    points[0] = points[3]
    points[1] = points[4]
    controlPointIndex = 1

    return smoothedPoints
  }
}

private struct CatmullRomStrokeSmoother {

  private var points: [CGPoint] = []

  mutating func begin(at point: CGPoint) {
    reset()
    points = [point]
  }

  mutating func append(
    _ inputPoints: [CGPoint],
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    inputPoints.flatMap { append($0, sampleDistance: sampleDistance) }
  }

  mutating func finish(
    at point: CGPoint,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    var output = append(point, sampleDistance: sampleDistance)

    switch points.count {
    case 0, 1:
      output.append(point)

    case 2:
      output += LinearSegment(start: points[0], end: points[1])
        .sampledPoints(maxSegmentLength: sampleDistance)

    default:
      if let lastPoint = points.last {
        points.append(lastPoint)

        while points.count >= 4 {
          output += emitSegment(sampleDistance: sampleDistance)
        }
      }
    }

    reset()
    return output
  }

  mutating func reset() {
    points.removeAll(keepingCapacity: true)
  }

  private mutating func append(
    _ point: CGPoint,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    points.append(point)

    guard points.count >= 4 else {
      return []
    }

    return emitSegment(sampleDistance: sampleDistance)
  }

  private mutating func emitSegment(sampleDistance: CGFloat) -> [CGPoint] {
    let segment = CatmullRomSegment(
      point0: points[0],
      point1: points[1],
      point2: points[2],
      point3: points[3]
    )
    points.removeFirst()
    return segment.sampledPoints(maxSegmentLength: sampleDistance)
  }
}

private struct MovingAverageStrokeSmoother {

  private let windowSize = 4
  private var recentPoints: [CGPoint] = []

  mutating func begin(at point: CGPoint) {
    reset()
    recentPoints = [point]
  }

  mutating func append(
    _ inputPoints: [CGPoint],
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    inputPoints.flatMap { append($0) }
  }

  mutating func finish(
    at point: CGPoint,
    sampleDistance: CGFloat
  ) -> [CGPoint] {
    var output = append(point)

    if (output.last?.distance(to: point) ?? .greatestFiniteMagnitude) > 0.5 {
      output.append(point)
    }

    reset()
    return output
  }

  mutating func reset() {
    recentPoints.removeAll(keepingCapacity: true)
  }

  private mutating func append(_ point: CGPoint) -> [CGPoint] {
    recentPoints.append(point)

    if recentPoints.count > windowSize {
      recentPoints.removeFirst(recentPoints.count - windowSize)
    }

    return [averagePoint]
  }

  private var averagePoint: CGPoint {
    let total = recentPoints.reduce(CGPoint.zero) { partialResult, point in
      CGPoint(
        x: partialResult.x + point.x,
        y: partialResult.y + point.y
      )
    }
    let count = CGFloat(max(recentPoints.count, 1))

    return CGPoint(
      x: total.x / count,
      y: total.y / count
    )
  }
}

private struct LinearSegment {
  var start: CGPoint
  var end: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let length = start.distance(to: end)
    let count = max(Int(ceil(length / max(maxSegmentLength, 1))), 1)

    return (0...count).map { index in
      start.interpolate(to: end, progress: CGFloat(index) / CGFloat(count))
    }
  }
}

private struct CubicBezierSegment {
  var start: CGPoint
  var control1: CGPoint
  var control2: CGPoint
  var end: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let estimatedLength = start.distance(to: control1)
      + control1.distance(to: control2)
      + control2.distance(to: end)
    let count = max(Int(ceil(estimatedLength / max(maxSegmentLength, 1))), 4)

    return (0...count).map { index in
      point(at: CGFloat(index) / CGFloat(count))
    }
  }

  private func point(at t: CGFloat) -> CGPoint {
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT * oneMinusT
    let b = 3 * oneMinusT * oneMinusT * t
    let c = 3 * oneMinusT * t * t
    let d = t * t * t

    return CGPoint(
      x: start.x * a + control1.x * b + control2.x * c + end.x * d,
      y: start.y * a + control1.y * b + control2.y * c + end.y * d
    )
  }
}

private struct CatmullRomSegment {
  var point0: CGPoint
  var point1: CGPoint
  var point2: CGPoint
  var point3: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let count = max(Int(ceil(point1.distance(to: point2) / max(maxSegmentLength, 1))), 4)

    return (0...count).map { index in
      point(at: CGFloat(index) / CGFloat(count))
    }
  }

  private func point(at t: CGFloat) -> CGPoint {
    let t2 = t * t
    let t3 = t2 * t

    return CGPoint(
      x: 0.5 * (
        2 * point1.x
          + (-point0.x + point2.x) * t
          + (2 * point0.x - 5 * point1.x + 4 * point2.x - point3.x) * t2
          + (-point0.x + 3 * point1.x - 3 * point2.x + point3.x) * t3
      ),
      y: 0.5 * (
        2 * point1.y
          + (-point0.y + point2.y) * t
          + (2 * point0.y - 5 * point1.y + 4 * point2.y - point3.y) * t2
          + (-point0.y + 3 * point1.y - 3 * point2.y + point3.y) * t3
      )
    )
  }
}

private struct QuadraticBezierSegment {
  var start: CGPoint
  var control: CGPoint
  var end: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let estimatedLength = start.distance(to: control) + control.distance(to: end)
    let count = max(Int(ceil(estimatedLength / max(maxSegmentLength, 1))), 2)

    return (0...count).map { index in
      point(at: CGFloat(index) / CGFloat(count))
    }
  }

  private func point(at t: CGFloat) -> CGPoint {
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT
    let b = 2 * oneMinusT * t
    let c = t * t

    return CGPoint(
      x: start.x * a + control.x * b + end.x * c,
      y: start.y * a + control.y * b + end.y * c
    )
  }
}

private final class MetalBrushSandboxScrollView: UIScrollView {}

private final class MetalBrushSandboxAttachmentContentView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-attachment-content-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class MetalBrushSandboxImageCanvasView: UIView {

  private let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .black
    isOpaque = true
    isUserInteractionEnabled = false
    clipsToBounds = true
    accessibilityIdentifier = "metal-brush-image-canvas-view"

    imageView.frame = bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    imageView.contentMode = .scaleToFill
    imageView.isOpaque = true
    imageView.backgroundColor = .black
    addSubview(imageView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setImage(_ image: UIImage) {
    guard imageView.image !== image else {
      return
    }
    imageView.image = image
  }
}

private struct MetalBrushTilePosition: Hashable {
  let col: Int
  let row: Int
}

private final class MetalBrushTileEntry {
  let layer: CALayer
  let canvasRect: CGRect
  var renderedContentsScale: CGFloat = 0
  var renderGeneration: Int = 0

  init(layer: CALayer, canvasRect: CGRect) {
    self.layer = layer
    self.canvasRect = canvasRect
  }
}

private enum MetalBrushTileDisplayContent {
  case iosurface(IOSurface)

  var layerContents: Any {
    switch self {
    case .iosurface(let surface):
      return surface
    }
  }
}

private final class MetalBrushSandboxCommittedCanvasView: UIView {

  struct RendererContext {
    let device: MTLDevice
    let brushPipeline: MTLRenderPipelineState
    let tileCompositePipeline: MTLRenderPipelineState
    var blurredImageTexture: MTLTexture?
  }

  private let canvasSize: CGSize
  private let baseTilePointSize: CGFloat = 512
  private let maxContentsScale: CGFloat = 64
  private let tileTransitionRenderRetryLimit = 2
  private let strokesLock = OSAllocatedUnfairLock<[MetalBrushSandboxStrokeRecord]>(initialState: [])
  private var tiles: [MetalBrushTilePosition: MetalBrushTileEntry] = [:]
  private var currentContentsScale: CGFloat = 0
  private var currentTilePointSize: CGFloat = 0
  private var visibleContentRect: CGRect = .zero
  private var tileGridTransitionGeneration = 0
  private var retainedTransitionLayers: [CALayer] = []
  private var rendererContext: RendererContext?
  private var tileQueue: MTLCommandQueue?
  private let renderQueue = DispatchQueue(
    label: "metal-brush-sandbox.tile-render",
    qos: .userInitiated,
    attributes: .concurrent
  )

  private struct ScheduledTileRender {
    let entry: MetalBrushTileEntry
    let generation: Int
    let strokes: [MetalBrushSandboxStrokeRecord]
    let canvasRect: CGRect
    let contentsScale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let rendererContext: RendererContext
    let tileQueue: MTLCommandQueue
  }

  private struct RenderedTile {
    let scheduled: ScheduledTileRender
    let displayContent: MetalBrushTileDisplayContent
  }

  var strokeCount: Int {
    strokesLock.withLock { $0.count }
  }

  var committedStampCount: Int {
    strokesLock.withLock { strokes in
      strokes.reduce(0) { $0 + $1.stamps.count }
    }
  }

  init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    super.init(frame: CGRect(origin: .zero, size: canvasSize))

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-committed-canvas-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setRendererContext(_ context: RendererContext) {
    rendererContext = context
    tileQueue = context.device.makeCommandQueue()
  }

  func setBlurredImageTexture(_ texture: MTLTexture?) {
    rendererContext?.blurredImageTexture = texture
    let entriesNeedingRender = syncVisibleTiles(
      schedulesRender: false,
      forcesRender: true
    )
    scheduleBatchedRender(entriesNeedingRender, completion: nil)
  }

  func addStroke(_ record: MetalBrushSandboxStrokeRecord, completion: (() -> Void)? = nil) {
    strokesLock.withLock { $0.append(record) }
    invalidateTiles(intersecting: record.bounds, completion: completion)
  }

  func reset() {
    strokesLock.withLock { $0.removeAll(keepingCapacity: true) }
    for (_, entry) in tiles {
      entry.layer.removeFromSuperlayer()
    }
    tiles.removeAll(keepingCapacity: true)
    removeRetainedTransitionLayers()
    currentContentsScale = 0
    currentTilePointSize = 0
  }

  func setViewport(
    visibleContentRect rawRect: CGRect,
    zoomScale: CGFloat,
    isInteracting: Bool
  ) {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let clipped = rawRect.intersection(canvasRect)
    visibleContentRect = clipped.isNull || clipped.isEmpty ? canvasRect : clipped

    let targetScale = targetContentsScale(for: zoomScale)
    let scaleChanged = abs(currentContentsScale - targetScale) > 0.001
    let shouldCommitScaleChange = isInteracting == false && scaleChanged
    if currentContentsScale == 0 || shouldCommitScaleChange {
      currentContentsScale = targetScale
    }
    if currentContentsScale == 0 {
      currentContentsScale = targetScale
    }

    let targetTilePointSize = targetTilePointSize(for: zoomScale)
    let tileSizeChanged = abs(currentTilePointSize - targetTilePointSize) > 0.01
    if currentTilePointSize == 0 || (isInteracting == false && tileSizeChanged) {
      if currentTilePointSize != 0, tileSizeChanged {
        transitionTileGrid(to: targetTilePointSize)
        return
      }
      currentTilePointSize = targetTilePointSize
    }
    if currentTilePointSize == 0 {
      currentTilePointSize = targetTilePointSize
    }

    if shouldCommitScaleChange {
      let entriesNeedingRender = syncVisibleTiles(schedulesRender: false)
      scheduleBatchedRender(entriesNeedingRender, completion: nil)
    } else {
      syncVisibleTiles()
    }
  }

  private func targetContentsScale(for zoomScale: CGFloat) -> CGFloat {
    let screenScale = window?.screen.scale ?? UIScreen.main.scale
    return min(max(zoomScale, 0.01) * screenScale, maxContentsScale)
  }

  private func targetTilePointSize(for zoomScale: CGFloat) -> CGFloat {
    let lodScale = tileLODScale(for: zoomScale)
    let maxTilePointSize = max(canvasSize.width, canvasSize.height)
    return min(baseTilePointSize / lodScale, maxTilePointSize)
  }

  private func tileLODScale(for zoomScale: CGFloat) -> CGFloat {
    var scale: CGFloat = 1
    let zoom = max(zoomScale, 1)
    while scale < zoom {
      scale *= 2
    }
    return scale
  }

  @discardableResult
  private func syncVisibleTiles(
    schedulesRender: Bool = true,
    hidesCreatedLayers: Bool = false,
    forcesRender: Bool = false
  ) -> [MetalBrushTileEntry] {
    guard rendererContext != nil else { return [] }
    let tilePointSize = currentTilePointSize
    guard tilePointSize > 0 else { return [] }
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let margin = tilePointSize
    let visibleWithMargin = visibleContentRect.insetBy(dx: -margin, dy: -margin).intersection(canvasRect)
    guard visibleWithMargin.isNull == false, visibleWithMargin.isEmpty == false else {
      return []
    }

    let minCol = max(Int(floor(visibleWithMargin.minX / tilePointSize)), 0)
    let minRow = max(Int(floor(visibleWithMargin.minY / tilePointSize)), 0)
    let maxCol = Int(floor((visibleWithMargin.maxX - 0.001) / tilePointSize))
    let maxRow = Int(floor((visibleWithMargin.maxY - 0.001) / tilePointSize))

    var requiredPositions: Set<MetalBrushTilePosition> = []
    var entriesNeedingRender: [MetalBrushTileEntry] = []
    if minCol <= maxCol, minRow <= maxRow {
      for row in minRow...maxRow {
        for col in minCol...maxCol {
          let position = MetalBrushTilePosition(col: col, row: row)
          guard let rect = tileCanvasRect(for: position) else { continue }
          requiredPositions.insert(position)
          let entry: MetalBrushTileEntry
          if let existing = tiles[position] {
            entry = existing
          } else {
            entry = makeTileEntry(
              at: position,
              canvasRect: rect,
              isHidden: hidesCreatedLayers
            )
            tiles[position] = entry
          }
          if forcesRender
            || entry.layer.contents == nil
            || abs(entry.renderedContentsScale - currentContentsScale) > 0.001
          {
            entriesNeedingRender.append(entry)
            if schedulesRender {
              scheduleRender(entry)
            }
          }
        }
      }
    }

    let positionsToRemove = tiles.keys.filter { requiredPositions.contains($0) == false }
    for position in positionsToRemove {
      guard let entry = tiles[position] else { continue }
      entry.layer.removeFromSuperlayer()
      tiles[position] = nil
    }

    return entriesNeedingRender
  }

  private func tileCanvasRect(for position: MetalBrushTilePosition) -> CGRect? {
    let tilePointSize = currentTilePointSize
    guard tilePointSize > 0 else { return nil }
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let origin = CGPoint(
      x: CGFloat(position.col) * tilePointSize,
      y: CGFloat(position.row) * tilePointSize
    )
    let rect = CGRect(origin: origin, size: CGSize(width: tilePointSize, height: tilePointSize))
      .intersection(canvasRect)
    guard rect.isNull == false, rect.isEmpty == false else { return nil }
    return rect
  }

  private func makeTileEntry(
    at position: MetalBrushTilePosition,
    canvasRect: CGRect,
    isHidden: Bool = false
  ) -> MetalBrushTileEntry {
    let layer = CALayer()
    layer.frame = canvasRect
    layer.actions = [
      "contents": NSNull(),
      "contentsScale": NSNull(),
      "hidden": NSNull(),
      "opacity": NSNull(),
    ]
    layer.isOpaque = false
    layer.isHidden = isHidden
    self.layer.addSublayer(layer)
    return MetalBrushTileEntry(layer: layer, canvasRect: canvasRect)
  }

  private func transitionTileGrid(to tilePointSize: CGFloat) {
    tileGridTransitionGeneration += 1
    let generation = tileGridTransitionGeneration
    let previousTilePointSize = currentTilePointSize
    let retiringTiles = tiles
    let retiringLayers = retiringTiles.values.map(\.layer)
    retainedTransitionLayers.append(contentsOf: retiringLayers)

    tiles.removeAll(keepingCapacity: true)
    currentTilePointSize = tilePointSize

    let entriesNeedingRender = syncVisibleTiles(
      schedulesRender: false,
      hidesCreatedLayers: true
    )
    guard entriesNeedingRender.isEmpty == false else {
      completeTileGridTransition(
        generation: generation,
        entries: [],
        retiringTiles: retiringTiles,
        previousTilePointSize: previousTilePointSize,
        retryCount: 0
      )
      return
    }

    scheduleBatchedRender(entriesNeedingRender) { [weak self] in
      self?.completeTileGridTransition(
        generation: generation,
        entries: entriesNeedingRender,
        retiringTiles: retiringTiles,
        previousTilePointSize: previousTilePointSize,
        retryCount: 0
      )
    }
  }

  private func completeTileGridTransition(
    generation: Int,
    entries: [MetalBrushTileEntry],
    retiringTiles: [MetalBrushTilePosition: MetalBrushTileEntry],
    previousTilePointSize: CGFloat,
    retryCount: Int
  ) {
    let retiringLayers = retiringTiles.values.map(\.layer)
    guard generation == tileGridTransitionGeneration else {
      removeRetainedTransitionLayers(retiringLayers)
      return
    }

    let visibleEntries = entries.filter { $0.layer.superlayer === layer }
    let hasMissingRenderedTile = visibleEntries.contains { $0.layer.contents == nil }
    guard hasMissingRenderedTile == false else {
      guard retryCount < tileTransitionRenderRetryLimit else {
        abortTileGridTransition(
          generation: generation,
          newEntries: visibleEntries,
          retiringTiles: retiringTiles,
          previousTilePointSize: previousTilePointSize
        )
        return
      }

      scheduleBatchedRender(visibleEntries) { [weak self] in
        self?.completeTileGridTransition(
          generation: generation,
          entries: visibleEntries,
          retiringTiles: retiringTiles,
          previousTilePointSize: previousTilePointSize,
          retryCount: retryCount + 1
        )
      }
      return
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for entry in visibleEntries {
      entry.layer.isHidden = false
    }
    for layer in retiringLayers {
      layer.removeFromSuperlayer()
    }
    CATransaction.commit()
    removeRetainedTransitionLayers(retiringLayers)
  }

  private func abortTileGridTransition(
    generation: Int,
    newEntries: [MetalBrushTileEntry],
    retiringTiles: [MetalBrushTilePosition: MetalBrushTileEntry],
    previousTilePointSize: CGFloat
  ) {
    guard generation == tileGridTransitionGeneration else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for entry in newEntries {
      entry.layer.removeFromSuperlayer()
    }
    for entry in retiringTiles.values where entry.layer.superlayer == nil {
      layer.addSublayer(entry.layer)
    }
    CATransaction.commit()

    tiles = retiringTiles
    currentTilePointSize = previousTilePointSize
    let retiringLayers = retiringTiles.values.map(\.layer)
    retainedTransitionLayers.removeAll { retainedLayer in
      retiringLayers.contains { $0 === retainedLayer }
    }
  }

  private func invalidateTiles(intersecting bounds: CGRect, completion: (() -> Void)? = nil) {
    let tilePointSize = currentTilePointSize
    guard tilePointSize > 0 else {
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let visibleWithMargin = visibleContentRect.insetBy(dx: -tilePointSize, dy: -tilePointSize).intersection(canvasRect)
    let intersectingTiles = tiles.filter { $0.value.canvasRect.intersects(bounds) }
    let visibleEntries = intersectingTiles.compactMap { _, entry -> MetalBrushTileEntry? in
      if entry.canvasRect.intersects(visibleWithMargin) {
        return entry
      } else {
        return nil
      }
    }

    for (position, entry) in intersectingTiles where entry.canvasRect.intersects(visibleWithMargin) == false {
      entry.layer.removeFromSuperlayer()
      tiles[position] = nil
    }

    guard visibleEntries.isEmpty == false else {
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    scheduleBatchedRender(visibleEntries, completion: completion)
  }

  private func removeAllTiles(keepingCapacity: Bool) {
    for (_, entry) in tiles {
      entry.layer.removeFromSuperlayer()
    }
    tiles.removeAll(keepingCapacity: keepingCapacity)
    removeRetainedTransitionLayers()
  }

  private func removeRetainedTransitionLayers(_ layers: [CALayer]? = nil) {
    let layersToRemove = layers ?? retainedTransitionLayers
    for layer in layersToRemove {
      layer.removeFromSuperlayer()
    }

    if layers == nil {
      retainedTransitionLayers.removeAll(keepingCapacity: true)
    } else {
      retainedTransitionLayers.removeAll { retainedLayer in
        layersToRemove.contains { $0 === retainedLayer }
      }
    }
  }

  private func scheduleRender(_ entry: MetalBrushTileEntry, completion: (() -> Void)? = nil) {
    guard let scheduled = makeScheduledRender(for: entry) else {
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    renderQueue.async { [weak self] in
      guard let self else { return }
      guard let displayContent = self.renderTileContent(for: scheduled) else {
        DispatchQueue.main.async {
          completion?()
        }
        return
      }

      DispatchQueue.main.async {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.applyRenderedTile(.init(scheduled: scheduled, displayContent: displayContent))
        CATransaction.commit()
        completion?()
      }
    }
  }

  private func scheduleBatchedRender(
    _ entries: [MetalBrushTileEntry],
    completion: (() -> Void)?
  ) {
    let scheduledRenders = entries.compactMap(makeScheduledRender)
    guard scheduledRenders.isEmpty == false else {
      DispatchQueue.main.async {
        completion?()
      }
      return
    }

    let renderedTilesLock = OSAllocatedUnfairLock<[RenderedTile]>(initialState: [])
    let group = DispatchGroup()
    for scheduled in scheduledRenders {
      group.enter()
      renderQueue.async { [weak self] in
        defer {
          group.leave()
        }
        guard let self else { return }
        guard let displayContent = self.renderTileContent(for: scheduled) else { return }
        renderedTilesLock.withLock {
          $0.append(.init(scheduled: scheduled, displayContent: displayContent))
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else {
        completion?()
        return
      }
      let renderedTiles = renderedTilesLock.withLock { $0 }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      CATransaction.setCompletionBlock {
        completion?()
      }
      for renderedTile in renderedTiles {
        self.applyRenderedTile(renderedTile)
      }
      CATransaction.commit()
    }
  }

  private func makeScheduledRender(for entry: MetalBrushTileEntry) -> ScheduledTileRender? {
    guard let rendererContext, let tileQueue else {
      return nil
    }

    entry.renderGeneration += 1
    let generation = entry.renderGeneration
    let canvasRect = entry.canvasRect
    let contentsScale = currentContentsScale
    return ScheduledTileRender(
      entry: entry,
      generation: generation,
      strokes: strokesLock.withLock { $0 },
      canvasRect: canvasRect,
      contentsScale: contentsScale,
      pixelWidth: alignedPixelSize(canvasRect.width * contentsScale),
      pixelHeight: alignedPixelSize(canvasRect.height * contentsScale),
      rendererContext: rendererContext,
      tileQueue: tileQueue
    )
  }

  private func renderTileContent(for scheduled: ScheduledTileRender) -> MetalBrushTileDisplayContent? {
    guard let surface = renderTileSurface(
      canvasRect: scheduled.canvasRect,
      pixelWidth: scheduled.pixelWidth,
      pixelHeight: scheduled.pixelHeight,
      strokes: scheduled.strokes,
      context: scheduled.rendererContext,
      tileQueue: scheduled.tileQueue
    ) else {
      return nil
    }
    return makeTileDisplayContent(from: surface)
  }

  private func applyRenderedTile(_ rendered: RenderedTile) {
    let entry = rendered.scheduled.entry
    guard entry.renderGeneration == rendered.scheduled.generation else {
      return
    }
    guard entry.layer.superlayer === layer else {
      return
    }

    entry.layer.contentsScale = rendered.scheduled.contentsScale
    entry.layer.contents = rendered.displayContent.layerContents
    entry.renderedContentsScale = rendered.scheduled.contentsScale
  }

  private func alignedPixelSize(_ value: CGFloat) -> Int {
    let raw = max(Int(value.rounded()), 4)
    return (raw + 3) & ~3
  }

  private func renderTileSurface(
    canvasRect: CGRect,
    pixelWidth: Int,
    pixelHeight: Int,
    strokes: [MetalBrushSandboxStrokeRecord],
    context: RendererContext,
    tileQueue: MTLCommandQueue
  ) -> IOSurface? {
    guard let blurredImageTexture = context.blurredImageTexture else {
      return nil
    }

    let bytesPerRow = pixelWidth * 4
    let attrs: [IOSurfacePropertyKey: Any] = [
      .allocSize: bytesPerRow * pixelHeight,
      .width: pixelWidth,
      .height: pixelHeight,
      .bytesPerElement: 4,
      .bytesPerRow: bytesPerRow,
      .cacheMode: 0,
      .name: "MetalBrushSandbox",
      .pixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
      .pixelSizeCastingAllowed: true,
    ]
    guard let surface = IOSurface(properties: attrs) else { return nil }

    let surfaceDescriptor = MTLTextureDescriptor()
    surfaceDescriptor.pixelFormat = .bgra8Unorm
    surfaceDescriptor.width = pixelWidth
    surfaceDescriptor.height = pixelHeight
    surfaceDescriptor.usage = [.renderTarget, .shaderRead]
    surfaceDescriptor.storageMode = .shared
    guard let surfaceTexture = context.device.makeTexture(
      descriptor: surfaceDescriptor,
      iosurface: surface,
      plane: 0
    ) else {
      return nil
    }

    let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: pixelWidth,
      height: pixelHeight,
      mipmapped: false
    )
    maskDescriptor.usage = [.renderTarget, .shaderRead]
    maskDescriptor.storageMode = .private
    guard let maskTexture = context.device.makeTexture(descriptor: maskDescriptor) else {
      return nil
    }

    guard let commandBuffer = tileQueue.makeCommandBuffer() else { return nil }

    let clearDescriptor = MTLRenderPassDescriptor()
    clearDescriptor.colorAttachments[0].texture = maskTexture
    clearDescriptor.colorAttachments[0].loadAction = .clear
    clearDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    clearDescriptor.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: clearDescriptor)?.endEncoding()

    encodeStrokes(
      strokes,
      canvasRect: canvasRect,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      into: maskTexture,
      brushPipeline: context.brushPipeline,
      commandBuffer: commandBuffer
    )

    let compositeDescriptor = MTLRenderPassDescriptor()
    compositeDescriptor.colorAttachments[0].texture = surfaceTexture
    compositeDescriptor.colorAttachments[0].loadAction = .dontCare
    compositeDescriptor.colorAttachments[0].storeAction = .store
    guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositeDescriptor) else {
      return nil
    }

    compositeEncoder.setRenderPipelineState(context.tileCompositePipeline)
    compositeEncoder.setFragmentTexture(maskTexture, index: 0)
    compositeEncoder.setFragmentTexture(blurredImageTexture, index: 1)
    var compositeUniforms = MetalBrushTileCompositeUniforms(
      canvasOrigin: canvasRect.origin.simdFloat2,
      canvasSize: canvasRect.size.simdFloat2,
      imageSize: canvasSize.simdFloat2
    )
    compositeEncoder.setFragmentBytes(
      &compositeUniforms,
      length: MemoryLayout<MetalBrushTileCompositeUniforms>.stride,
      index: 0
    )
    compositeEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    compositeEncoder.endEncoding()

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    return surface
  }

  private func makeTileDisplayContent(from surface: IOSurface) -> MetalBrushTileDisplayContent? {
    .iosurface(surface)
  }

  private func encodeStrokes(
    _ strokes: [MetalBrushSandboxStrokeRecord],
    canvasRect: CGRect,
    pixelWidth: Int,
    pixelHeight: Int,
    into texture: MTLTexture,
    brushPipeline: MTLRenderPipelineState,
    commandBuffer: MTLCommandBuffer
  ) {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .load
    descriptor.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }
    encoder.setRenderPipelineState(brushPipeline)

    let scaleX = Double(pixelWidth) / Double(canvasRect.width)
    let scaleY = Double(pixelHeight) / Double(canvasRect.height)
    let scale = (scaleX + scaleY) * 0.5
    let targetSize = SIMD2(Float(pixelWidth), Float(pixelHeight))

    for stroke in strokes where stroke.bounds.intersects(canvasRect) {
      let radius = CGFloat(stroke.brush.size / 2)
      let pixelRadius = Float(Double(radius) * scale)
      let hardness = Float(stroke.brush.hardness)
      let opacity = Float(stroke.brush.opacity)
      for stamp in stroke.stamps {
        let stampMinX = stamp.x - radius
        let stampMinY = stamp.y - radius
        let stampMaxX = stamp.x + radius
        let stampMaxY = stamp.y + radius
        if stampMaxX < canvasRect.minX || stampMinX > canvasRect.maxX
          || stampMaxY < canvasRect.minY || stampMinY > canvasRect.maxY
        {
          continue
        }
        var uniforms = MetalBrushUniforms(
          canvasSize: targetSize,
          center: SIMD2(
            Float((stamp.x - canvasRect.minX) * scaleX),
            Float((stamp.y - canvasRect.minY) * scaleY)
          ),
          radius: pixelRadius,
          hardness: hardness,
          opacity: opacity
        )
        encoder.setVertexBytes(
          &uniforms,
          length: MemoryLayout<MetalBrushUniforms>.stride,
          index: 0
        )
        encoder.setFragmentBytes(
          &uniforms,
          length: MemoryLayout<MetalBrushUniforms>.stride,
          index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      }
    }

    encoder.endEncoding()
  }
}

private final class MetalBrushSandboxTiledCanvasView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-tiled-canvas-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class MetalBrushSandboxTiledView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-tiled-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class MetalBrushSandboxSelectionGestureView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    accessibilityIdentifier = "metal-brush-selection-gesture-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class MetalBrushSandboxTiledGestureView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    accessibilityIdentifier = "metal-brush-tiled-gesture-view"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private final class MetalBrushSandboxHostView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

  private let canvasSize: CGSize
  private let scrollView = MetalBrushSandboxScrollView()
  private let attachmentContentView = MetalBrushSandboxAttachmentContentView()
  private let imageCanvasView = MetalBrushSandboxImageCanvasView()
  private let committedCanvasView: MetalBrushSandboxCommittedCanvasView
  private let tiledCanvasView = MetalBrushSandboxTiledCanvasView()
  private let tiledView = MetalBrushSandboxTiledView()
  private let selectionGestureView = MetalBrushSandboxSelectionGestureView()
  private let tiledGestureView = MetalBrushSandboxTiledGestureView()
  private let drawingGestureRecognizer = MetalBrushDrawingGestureRecognizer(
    target: nil,
    action: nil
  )
  private let canvasView: MetalBrushSandboxCanvasView?
  private let fallbackLabel = UILabel()
  private var didSetInitialZoom = false
  private var previousLayoutBoundsSize: CGSize = .zero
  private weak var protectedNavigationController: UINavigationController?
  private var previousInteractivePopGestureEnabled: Bool?
  private var currentCanvasImage: UIImage?
  private var currentBlurRadius: Double?
  var onMetricsChange: ((MetalBrushSandboxMetrics) -> Void)?

  init(canvasSize: CGSize) {
    self.canvasSize = canvasSize
    self.canvasView = MTLCreateSystemDefaultDevice().map {
      MetalBrushSandboxCanvasView(canvasSize: canvasSize, device: $0)
    }
    self.committedCanvasView = MetalBrushSandboxCommittedCanvasView(canvasSize: canvasSize)

    super.init(frame: .zero)

    backgroundColor = .black
    accessibilityIdentifier = "metal-brush-sandbox-host"

    scrollView.delegate = self
    scrollView.backgroundColor = .clear
    scrollView.isOpaque = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.bouncesZoom = true
    scrollView.alwaysBounceHorizontal = true
    scrollView.alwaysBounceVertical = true
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
    addSubview(scrollView)

    attachmentContentView.frame = CGRect(origin: .zero, size: canvasSize)
    imageCanvasView.frame = attachmentContentView.bounds
    committedCanvasView.frame = attachmentContentView.bounds
    attachmentContentView.addSubview(imageCanvasView)
    attachmentContentView.addSubview(committedCanvasView)
    scrollView.addSubview(attachmentContentView)
    scrollView.addSubview(tiledCanvasView)
    scrollView.addSubview(tiledView)
    scrollView.contentSize = canvasSize

    if let canvasView, let device = canvasView.sharedDevice {
      canvasView.frame = tiledCanvasView.bounds
      canvasView.isUserInteractionEnabled = false
      canvasView.onMetricsChange = { [weak self] in
        self?.publishMetrics()
      }
      canvasView.onStrokeCommit = { [weak self] record, completion in
        self?.commit(record: record, completion: completion)
      }
      committedCanvasView.setRendererContext(
        .init(
          device: device,
          brushPipeline: canvasView.sharedBrushPipeline,
          tileCompositePipeline: canvasView.sharedTileCompositePipeline,
          blurredImageTexture: canvasView.sharedBlurredImageTexture
        )
      )
      tiledCanvasView.addSubview(canvasView)
    } else {
      fallbackLabel.text = "Metal is unavailable"
      fallbackLabel.textColor = .white
      fallbackLabel.textAlignment = .center
      tiledCanvasView.addSubview(fallbackLabel)
    }

    tiledView.addSubview(selectionGestureView)
    tiledView.addSubview(tiledGestureView)

    drawingGestureRecognizer.delegate = self
    drawingGestureRecognizer.onBegin = { [weak self] point in
      guard let self else { return }
      canvasView?.beginStroke(at: contentPoint(fromViewportPoint: point))
    }
    drawingGestureRecognizer.onMove = { [weak self] points in
      guard let self else { return }
      canvasView?.appendStroke(
        points: points.map { self.contentPoint(fromViewportPoint: $0) }
      )
    }
    drawingGestureRecognizer.onEnd = { [weak self] point in
      guard let self else { return }
      canvasView?.endStroke(at: contentPoint(fromViewportPoint: point))
    }
    drawingGestureRecognizer.onCancel = { [weak canvasView] in
      canvasView?.cancelStroke()
    }
    tiledGestureView.addGestureRecognizer(drawingGestureRecognizer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    restoreNavigationBackGesture()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()

    if window == nil {
      restoreNavigationBackGesture()
    } else {
      protectNavigationBackGesture()
      DispatchQueue.main.async { [weak self] in
        self?.protectNavigationBackGesture()
      }
    }
  }

  func configure(
    brush: MetalBrushSandboxBrush,
    smoothing: MetalBrushStrokeSmoothingConfiguration
  ) {
    canvasView?.configure(brush: brush, smoothing: smoothing)
    updateVisibleContentRect()
  }

  func setCanvasImage(_ image: UIImage, blurRadius: Double) {
    imageCanvasView.setImage(image)

    guard currentCanvasImage !== image || currentBlurRadius != blurRadius else {
      return
    }

    currentCanvasImage = image
    currentBlurRadius = blurRadius

    let normalizedImage = image.metalBrushSandboxNormalizedImage(canvasSize: canvasSize)
    let blurredImage = normalizedImage.metalBrushSandboxBlurredImage(radius: blurRadius)
    canvasView?.setBlurredImage(blurredImage)
    committedCanvasView.setBlurredImageTexture(canvasView?.sharedBlurredImageTexture)
  }

  func reset() {
    canvasView?.reset()
    committedCanvasView.reset()
    updateVisibleContentRect()
    publishMetrics()
  }

  private func commit(record: MetalBrushSandboxStrokeRecord, completion: @escaping () -> Void) {
    committedCanvasView.addStroke(record, completion: completion)
    publishMetrics()
  }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    updateVisibleContentRect(isInteracting: false)
    publishMetrics()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    protectNavigationBackGesture()

    let previousBoundsSize = previousLayoutBoundsSize
    let boundsSizeChanged = previousBoundsSize != .zero && previousBoundsSize != bounds.size
    let visibleCenter = boundsSizeChanged ? visibleContentCenter() : nil
    let shouldRefitToMinimumZoom = isAtMinimumZoomScale

    previousLayoutBoundsSize = bounds.size
    scrollView.frame = bounds
    attachmentContentView.bounds = CGRect(origin: .zero, size: canvasSize)
    imageCanvasView.frame = attachmentContentView.bounds
    committedCanvasView.frame = attachmentContentView.bounds
    updateViewportLayerFrames()

    updateZoomScaleIfNeeded(refitsToMinimum: shouldRefitToMinimumZoom)
    centerContentIfNeeded()
    restoreVisibleContentCenterIfNeeded(visibleCenter)
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    attachmentContentView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerContentIfNeeded()
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateViewportLayerFrames()
    updateVisibleContentRect()
    publishMetrics()
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    if isDrawingGesture(gestureRecognizer) || isDrawingGesture(otherGestureRecognizer) {
      return isViewportGesture(gestureRecognizer) || isViewportGesture(otherGestureRecognizer)
    }

    return false
  }

  private func isDrawingGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === drawingGestureRecognizer
  }

  private func isViewportGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === scrollView.panGestureRecognizer || gestureRecognizer === scrollView.pinchGestureRecognizer
  }

  private func protectNavigationBackGesture() {
    guard
      window != nil,
      protectedNavigationController == nil,
      let navigationController = enclosingNavigationController
    else {
      return
    }

    protectedNavigationController = navigationController
    previousInteractivePopGestureEnabled = navigationController.interactivePopGestureRecognizer?.isEnabled
    navigationController.interactivePopGestureRecognizer?.isEnabled = false
  }

  private func restoreNavigationBackGesture() {
    guard let navigationController = protectedNavigationController else {
      return
    }

    if let previousInteractivePopGestureEnabled {
      navigationController.interactivePopGestureRecognizer?.isEnabled = previousInteractivePopGestureEnabled
    }

    protectedNavigationController = nil
    previousInteractivePopGestureEnabled = nil
  }

  private var enclosingNavigationController: UINavigationController? {
    navigationControllerFromResponderChain ?? window?.rootViewController?
      .firstNavigationController(containing: self)
  }

  private var navigationControllerFromResponderChain: UINavigationController? {
    var responder: UIResponder? = self

    while let currentResponder = responder {
      if let navigationController = currentResponder as? UINavigationController {
        return navigationController
      }

      if let viewController = currentResponder as? UIViewController {
        return viewController.navigationController
      }

      responder = currentResponder.next
    }

    return nil
  }

  private var isAtMinimumZoomScale: Bool {
    abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
  }

  private func updateViewportLayerFrames() {
    let viewportFrame = CGRect(
      origin: scrollView.bounds.origin,
      size: scrollView.bounds.size
    )

    tiledCanvasView.frame = viewportFrame
    tiledView.frame = viewportFrame

    canvasView?.frame = tiledCanvasView.bounds
    canvasView?.contentScaleFactor = window?.screen.scale ?? UIScreen.main.scale
    fallbackLabel.frame = tiledCanvasView.bounds

    selectionGestureView.frame = tiledView.bounds
    tiledGestureView.frame = tiledView.bounds
  }

  private func updateZoomScaleIfNeeded(refitsToMinimum: Bool) {
    guard bounds.width > 0, bounds.height > 0 else {
      return
    }

    let fitScale = min(
      bounds.width / max(canvasSize.width, 1),
      bounds.height / max(canvasSize.height, 1)
    )
    let minimumZoomScale = min(fitScale, 1)

    scrollView.minimumZoomScale = minimumZoomScale
    scrollView.maximumZoomScale = max(16, minimumZoomScale * 8)

    if didSetInitialZoom == false {
      didSetInitialZoom = true
      scrollView.setZoomScale(minimumZoomScale, animated: false)
      return
    }

    if refitsToMinimum || scrollView.zoomScale < minimumZoomScale {
      scrollView.setZoomScale(minimumZoomScale, animated: false)
    } else if scrollView.zoomScale > scrollView.maximumZoomScale {
      scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
    }
  }

  private func centerContentIfNeeded() {
    let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
    let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)

    scrollView.contentInset = UIEdgeInsets(
      top: verticalInset,
      left: horizontalInset,
      bottom: verticalInset,
      right: horizontalInset
    )
  }

  private func visibleContentCenter() -> CGPoint? {
    let visibleRect = scrollView.convert(scrollView.bounds, to: attachmentContentView)
      .intersection(CGRect(origin: .zero, size: canvasSize))

    guard visibleRect.isNull == false, visibleRect.isEmpty == false else {
      return nil
    }

    return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
  }

  private func restoreVisibleContentCenterIfNeeded(_ center: CGPoint?) {
    guard let center else {
      return
    }

    let scaledCenter = CGPoint(
      x: center.x * scrollView.zoomScale,
      y: center.y * scrollView.zoomScale
    )
    let proposedOffset = CGPoint(
      x: scaledCenter.x - scrollView.bounds.width / 2,
      y: scaledCenter.y - scrollView.bounds.height / 2
    )

    scrollView.setContentOffset(
      clampedContentOffset(proposedOffset),
      animated: false
    )
  }

  private func clampedContentOffset(_ contentOffset: CGPoint) -> CGPoint {
    let minimumX = -scrollView.contentInset.left
    let minimumY = -scrollView.contentInset.top
    let maximumX = max(
      minimumX,
      scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right
    )
    let maximumY = max(
      minimumY,
      scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
    )

    return CGPoint(
      x: min(max(contentOffset.x, minimumX), maximumX),
      y: min(max(contentOffset.y, minimumY), maximumY)
    )
  }

  private func updateVisibleContentRect(isInteracting: Bool? = nil) {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let viewportContentRect = scrollView.convert(scrollView.bounds, to: attachmentContentView)
    let liveVisibleRect = viewportContentRect
      .intersection(canvasRect)

    let effectiveLiveRect: CGRect
    if liveVisibleRect.isNull || liveVisibleRect.isEmpty {
      effectiveLiveRect = canvasRect
    } else {
      effectiveLiveRect = liveVisibleRect
    }
    let visibleCanvasFrame = attachmentContentView.convert(effectiveLiveRect, to: tiledCanvasView)

    let visibleRect = viewportContentRect
      .insetBy(dx: -2, dy: -2)
      .intersection(canvasRect)

    let effectiveRect: CGRect
    if visibleRect.isNull || visibleRect.isEmpty {
      effectiveRect = canvasRect
    } else {
      effectiveRect = visibleRect
    }

    canvasView?.setViewport(
      visibleContentRect: effectiveLiveRect,
      visibleCanvasFrame: visibleCanvasFrame,
      zoomScale: scrollView.zoomScale
    )

    let interacting = isInteracting ?? (scrollView.isZooming || scrollView.isDragging || scrollView.isDecelerating)
    committedCanvasView.setViewport(
      visibleContentRect: effectiveRect,
      zoomScale: scrollView.zoomScale,
      isInteracting: interacting
    )
  }

  private func contentPoint(fromViewportPoint point: CGPoint) -> CGPoint {
    tiledGestureView.convert(point, to: attachmentContentView)
  }

  private func publishMetrics() {
    let liveStamps = canvasView?.stampCount ?? 0
    let committedStamps = committedCanvasView.committedStampCount
    onMetricsChange?(
      MetalBrushSandboxMetrics(
        zoomScale: Double(scrollView.zoomScale),
        stampCount: liveStamps + committedStamps,
        strokeCount: committedCanvasView.strokeCount
      )
    )
  }
}

private extension UIViewController {

  func firstNavigationController(containing descendant: UIView) -> UINavigationController? {
    if let navigationController = self as? UINavigationController,
       descendant.isDescendant(of: navigationController.view) {
      return navigationController
    }

    for child in children {
      if let navigationController = child.firstNavigationController(containing: descendant) {
        return navigationController
      }
    }

    if let presentedViewController,
       let navigationController = presentedViewController.firstNavigationController(
         containing: descendant
       ) {
      return navigationController
    }

    return nil
  }
}

private final class MetalBrushDrawingGestureRecognizer: UIGestureRecognizer {

  var onBegin: ((CGPoint) -> Void)?
  var onMove: (([CGPoint]) -> Void)?
  var onEnd: ((CGPoint) -> Void)?
  var onCancel: (() -> Void)?

  private let directTouchDrawingThreshold: CGFloat = 8
  private weak var activeTouch: UITouch?
  private var activeTouchType: UITouch.TouchType?
  private var initialPoint: CGPoint?
  private var didBeginDrawing = false

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)

    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    allowedTouchTypes = [
      NSNumber(value: UITouch.TouchType.direct.rawValue),
      NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]
  }

  override func reset() {
    super.reset()
    activeTouch = nil
    activeTouchType = nil
    initialPoint = nil
    didBeginDrawing = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard activeTouch == nil else {
      finishAsViewportGesture()
      return
    }

    guard
      event.allTouches?.count == 1,
      touches.count == 1,
      let touch = touches.first
    else {
      state = .failed
      return
    }

    activeTouch = touch
    activeTouchType = touch.type
    initialPoint = touch.location(in: view)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard
      event.allTouches?.count == 1,
      let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else {
      finishAsViewportGesture()
      return
    }

    let currentPoint = activeTouch.location(in: view)
    guard didBeginDrawing || shouldBeginDrawing(at: currentPoint) else {
      return
    }

    beginDrawingIfNeeded(at: currentPoint)
    let coalescedTouches = event.coalescedTouches(for: activeTouch) ?? [activeTouch]
    let points = coalescedTouches.map { $0.location(in: view) }
    onMove?(points)
    if state == .began {
      return
    }
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard
      let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else {
      return
    }

    beginDrawingIfNeeded(at: activeTouch.location(in: view))
    onEnd?(activeTouch.location(in: view))
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    finishAsViewportGesture()
  }

  private func shouldBeginDrawing(at point: CGPoint) -> Bool {
    guard activeTouchType != .pencil, let initialPoint else {
      return true
    }

    return initialPoint.distance(to: point) >= directTouchDrawingThreshold
  }

  private func beginDrawingIfNeeded(at point: CGPoint) {
    guard didBeginDrawing == false else {
      return
    }

    didBeginDrawing = true
    state = .began
    onBegin?(initialPoint ?? point)
  }

  private func finishAsViewportGesture() {
    guard didBeginDrawing else {
      state = .failed
      return
    }

    onCancel?()
    state = .cancelled
  }
}

private struct MetalBrushUniforms {
  var canvasSize: SIMD2<Float>
  var center: SIMD2<Float>
  var radius: Float
  var hardness: Float
  var opacity: Float
  var _padding: Float = 0
}

private struct MetalBrushTileCompositeUniforms {
  var canvasOrigin: SIMD2<Float>
  var canvasSize: SIMD2<Float>
  var imageSize: SIMD2<Float>
}

private struct MetalBrushLiveOverlayUniforms {
  var visibleOrigin: SIMD2<Float>
  var visibleSize: SIMD2<Float>
  var viewportOrigin: SIMD2<Float>
  var viewportSize: SIMD2<Float>
  var drawableSize: SIMD2<Float>
  var imageSize: SIMD2<Float>
}

private final class MetalBrushSandboxCanvasView: MTKView, MTKViewDelegate {

  private typealias BrushUniforms = MetalBrushUniforms
  private static let maximumLiveTextureDimension = 8192
  private enum LiveFrameRate {
    static let minimum = 60
    static let maximum = 120

    static func targetMaximum(for screen: UIScreen?) -> Int {
      let screenMaximum = screen?.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
      return min(max(screenMaximum, minimum), maximum)
    }

    static func range(for screen: UIScreen?) -> CAFrameRateRange {
      let maximumFramesPerSecond = Float(targetMaximum(for: screen))
      return CAFrameRateRange(
        minimum: Float(minimum),
        maximum: maximumFramesPerSecond,
        preferred: maximumFramesPerSecond
      )
    }
  }

  private let canvasSize: CGSize
  private let commandQueue: MTLCommandQueue
  private let brushPipeline: MTLRenderPipelineState
  private let liveOverlayPipeline: MTLRenderPipelineState
  private let tileCompositePipeline: MTLRenderPipelineState
  private var liveStrokeTexture: MTLTexture?
  private var blurredImageTexture: MTLTexture?
  private var brush = MetalBrushSandboxBrush(
    size: 56,
    hardness: 0.72,
    opacity: 0.9,
    spacing: 0.18
  )
  private var smoothing = MetalBrushStrokeSmoothingConfiguration(
    algorithm: .bezier,
    strength: 0.85
  )
  private var visibleContentRect: CGRect
  private var visibleCanvasFrame: CGRect = .zero
  private var strokeSmoother = MetalBrushStrokeSmoother()
  private var lastStampPoint: CGPoint?
  private var activeStrokeStamps: [CGPoint] = []
  private var pendingLiveStamps: [CGPoint] = []
  private var liveDisplayLink: CADisplayLink?
  private var liveOverlayGeneration = 0
  private var lastLiveMetricsPublishTime: CFTimeInterval = 0
  private let liveMetricsPublishInterval: CFTimeInterval = 1.0 / 12.0
  var stampCount: Int {
    activeStrokeStamps.count
  }
  var onMetricsChange: (() -> Void)?
  var onStrokeCommit: ((MetalBrushSandboxStrokeRecord, @escaping () -> Void) -> Void)?

  var sharedDevice: MTLDevice? { device }
  var sharedBrushPipeline: MTLRenderPipelineState { brushPipeline }
  var sharedTileCompositePipeline: MTLRenderPipelineState { tileCompositePipeline }
  var sharedBlurredImageTexture: MTLTexture? { blurredImageTexture }

  init(canvasSize: CGSize, device: MTLDevice) {
    self.canvasSize = canvasSize
    self.commandQueue = device.makeCommandQueue()!
    self.visibleContentRect = CGRect(origin: .zero, size: canvasSize)

    do {
      let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
      self.brushPipeline = try Self.makeBrushPipeline(device: device, library: library)
      self.liveOverlayPipeline = try Self.makeLiveOverlayPipeline(device: device, library: library)
      self.tileCompositePipeline = try Self.makeTileCompositePipeline(device: device, library: library)
    } catch {
      fatalError("Failed to create Metal Brush Sandbox pipeline: \(error)")
    }

    super.init(frame: .zero, device: device)

    backgroundColor = .clear
    isOpaque = false
    layer.isOpaque = false
    framebufferOnly = false
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    enableSetNeedsDisplay = true
    isPaused = true
    preferredFramesPerSecond = LiveFrameRate.targetMaximum(for: nil)
    autoResizeDrawable = true
    isMultipleTouchEnabled = true
    delegate = self
    accessibilityIdentifier = "metal-brush-sandbox-metal-view"
    isAccessibilityElement = true
    accessibilityLabel = "Metal Brush Canvas"
    isHidden = true
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.maximumDrawableCount = 3
    }

    makeLayerTextures()
    reset()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopLiveDisplayLink()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updatePreferredFrameRate()
  }

  func configure(
    brush: MetalBrushSandboxBrush,
    smoothing: MetalBrushStrokeSmoothingConfiguration
  ) {
    self.brush = brush

    if self.smoothing != smoothing {
      self.smoothing = smoothing
      strokeSmoother.configure(smoothing)
      cancelActiveStroke()
      lastStampPoint = nil
    }

    if isHidden == false {
      setNeedsDisplay()
    }
  }

  func setBlurredImage(_ image: UIImage) {
    guard let cgImage = image.cgImage else {
      blurredImageTexture = nil
      return
    }

    blurredImageTexture = makeImageTexture(from: cgImage)

    if isHidden == false {
      setNeedsDisplay()
    }
  }

  private func makeImageTexture(from cgImage: CGImage) -> MTLTexture? {
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue

    guard
      let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      return nil
    }

    context.draw(
      cgImage,
      in: CGRect(x: 0, y: 0, width: width, height: height)
    )

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device?.makeTexture(descriptor: descriptor) else {
      return nil
    }

    texture.replace(
      region: MTLRegionMake2D(0, 0, width, height),
      mipmapLevel: 0,
      withBytes: pixels,
      bytesPerRow: bytesPerRow
    )
    return texture
  }

  func setViewport(
    visibleContentRect rect: CGRect,
    visibleCanvasFrame frame: CGRect,
    zoomScale: CGFloat
  ) {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let nextRect = rect.intersection(canvasRect)
    let nextFrame = frame

    guard nextRect.isNull == false, nextRect.isEmpty == false else {
      return
    }

    guard visibleContentRect.equalTo(nextRect) == false
      || visibleCanvasFrame.equalTo(nextFrame) == false
    else {
      return
    }

    visibleContentRect = nextRect
    visibleCanvasFrame = nextFrame
    if isHidden == false {
      setNeedsDisplay()
    }
    onMetricsChange?()
  }

  func reset() {
    cancelActiveStroke()
    onMetricsChange?()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    if activeStrokeStamps.isEmpty == false {
      cancelActiveStroke()
    }
    liveStrokeTexture = makeStrokeTexture(size: size)
  }

  func draw(in view: MTKView) {
    renderLiveOverlay()
  }

  func beginStroke(at rawPoint: CGPoint) {
    ensureLiveStrokeTextureMatchesDrawable()
    liveOverlayGeneration += 1
    isHidden = false
    activeStrokeStamps.removeAll(keepingCapacity: true)
    clearLiveStrokeTexture(hidesOverlay: false)
    let point = clampedContentPoint(rawPoint)
    strokeSmoother.begin(at: point)
    lastStampPoint = point
    renderLiveStamps([point], flushImmediately: true)
  }

  func appendStroke(points rawPoints: [CGPoint]) {
    guard rawPoints.isEmpty == false else {
      return
    }

    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let inputPoints = rawPoints.map { clampedContentPoint($0) }
    let smoothedPoints = strokeSmoother.append(
      inputPoints,
      sampleDistance: sampleDistance
    )
    let stamps = smoothedPoints.flatMap { point -> [CGPoint] in
      stampPoints(to: point)
    }

    renderLiveStamps(stamps)
  }

  func endStroke(at rawPoint: CGPoint) {
    let sampleDistance = max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
    let point = clampedContentPoint(rawPoint)
    let smoothedPoints = strokeSmoother.finish(
      at: point,
      sampleDistance: sampleDistance
    )
    let stamps = smoothedPoints.flatMap { point -> [CGPoint] in
      stampPoints(to: point)
    }

    renderLiveStamps(stamps, flushImmediately: true)
    commitActiveStroke()
    strokeSmoother.reset()
    lastStampPoint = nil
  }

  func cancelStroke() {
    cancelActiveStroke()
  }

  private func makeLayerTextures() {
    liveStrokeTexture = nil
  }

  private func makeStrokeTexture(size: CGSize) -> MTLTexture? {
    guard let device else {
      return nil
    }

    let width = max(Int(size.width.rounded(.up)), 1)
    let height = max(Int(size.height.rounded(.up)), 1)
    guard width <= Self.maximumLiveTextureDimension,
          height <= Self.maximumLiveTextureDimension
    else {
      return nil
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    return device.makeTexture(descriptor: descriptor)
  }

  private func makeLiveStrokeTextureForCurrentDrawable() -> MTLTexture? {
    let size = drawableSize
    let fallback = CGSize(
      width: max(bounds.width, 1) * contentScaleFactor,
      height: max(bounds.height, 1) * contentScaleFactor
    )
    let target = size.width > 0 && size.height > 0 ? size : fallback
    return makeStrokeTexture(size: target)
  }

  private func ensureLiveStrokeTextureMatchesDrawable() {
    let target = drawableSize
    guard target.width > 0, target.height > 0 else {
      return
    }
    let current = liveStrokeTexture
    if let current,
       current.width == Int(target.width.rounded(.up)),
       current.height == Int(target.height.rounded(.up))
    {
      return
    }
    liveStrokeTexture = makeStrokeTexture(size: target)
  }

  private func clearLiveStrokeTexture(hidesOverlay: Bool = true) {
    if hidesOverlay {
      isHidden = true
    }
    clearTexture(liveStrokeTexture)
    setNeedsDisplay()
  }

  private func clearTexture(_ texture: MTLTexture?) {
    guard
      let texture,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    encodeClearTexture(texture, commandBuffer: commandBuffer)
    commandBuffer.commit()
  }

  private func encodeClearTexture(_ texture: MTLTexture?, commandBuffer: MTLCommandBuffer) {
    guard let texture else {
      return
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store

    commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
  }

  private func cancelActiveStroke() {
    liveOverlayGeneration += 1
    strokeSmoother.reset()
    activeStrokeStamps.removeAll(keepingCapacity: true)
    pendingLiveStamps.removeAll(keepingCapacity: true)
    stopLiveDisplayLink()
    clearLiveStrokeTexture()
    lastStampPoint = nil
  }

  private func stampPoints(to point: CGPoint) -> [CGPoint] {
    guard let lastStampPoint else {
      self.lastStampPoint = point
      return [point]
    }

    let distance = hypot(point.x - lastStampPoint.x, point.y - lastStampPoint.y)
    let spacing = max(CGFloat(brush.size * brush.spacing), 1)

    guard distance >= spacing else {
      return []
    }

    let count = Int(distance / spacing)
    guard count > 0 else {
      return []
    }

    var stamps: [CGPoint] = []
    var newestStampPoint = lastStampPoint

    for index in 1...count {
      let progress = CGFloat(index) * spacing / distance
      let stamp = CGPoint(
        x: lastStampPoint.x + (point.x - lastStampPoint.x) * progress,
        y: lastStampPoint.y + (point.y - lastStampPoint.y) * progress
      )
      stamps.append(stamp)
      newestStampPoint = stamp
    }

    self.lastStampPoint = newestStampPoint
    return stamps
  }

  private func renderLiveStamps(_ stamps: [CGPoint], flushImmediately: Bool = false) {
    guard stamps.isEmpty == false else {
      return
    }

    activeStrokeStamps += stamps
    pendingLiveStamps += stamps
    isHidden = false
    startLiveDisplayLinkIfNeeded()

    if flushImmediately {
      flushPendingLiveStamps()
      publishLiveMetricsIfNeeded(force: true)
    } else {
      publishLiveMetricsIfNeeded()
    }
  }

  private func commitActiveStroke() {
    guard activeStrokeStamps.isEmpty == false else {
      clearLiveStrokeTexture()
      return
    }

    flushPendingLiveStamps()
    stopLiveDisplayLink()

    let stamps = activeStrokeStamps
    activeStrokeStamps.removeAll(keepingCapacity: true)
    let generation = liveOverlayGeneration

    let record = MetalBrushSandboxStrokeRecord(stamps: stamps, brush: brush)
    let clearLiveOverlay = { [weak self] in
      guard let self else { return }
      self.finishCommittedStrokeOverlay(for: generation)
    }

    if let onStrokeCommit {
      onStrokeCommit(record, clearLiveOverlay)
    } else {
      clearLiveOverlay()
    }
  }

  private func finishCommittedStrokeOverlay(for generation: Int) {
    if Thread.isMainThread == false {
      DispatchQueue.main.async { [weak self] in
        self?.finishCommittedStrokeOverlay(for: generation)
      }
      return
    }

    guard liveOverlayGeneration == generation, activeStrokeStamps.isEmpty else {
      return
    }

    isHidden = true
    onMetricsChange?()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.liveOverlayGeneration == generation, self.activeStrokeStamps.isEmpty else {
        return
      }
      self.clearTexture(self.liveStrokeTexture)
    }
  }

  private func renderStamps(
    _ stamps: [CGPoint],
    into texture: MTLTexture?
  ) {
    guard
      stamps.isEmpty == false,
      let texture,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    encodeLiveStamps(stamps, into: texture, commandBuffer: commandBuffer)
    commandBuffer.commit()
    setNeedsDisplay()
  }

  private func startLiveDisplayLinkIfNeeded() {
    guard liveDisplayLink == nil else { return }

    let displayLink = CADisplayLink(
      target: self,
      selector: #selector(liveDisplayLinkDidTick(_:))
    )
    displayLink.preferredFrameRateRange = LiveFrameRate.range(for: window?.screen)
    displayLink.add(to: .main, forMode: .common)
    liveDisplayLink = displayLink
  }

  private func updatePreferredFrameRate() {
    preferredFramesPerSecond = LiveFrameRate.targetMaximum(for: window?.screen)
    liveDisplayLink?.preferredFrameRateRange = LiveFrameRate.range(for: window?.screen)
  }

  private func stopLiveDisplayLink() {
    liveDisplayLink?.invalidate()
    liveDisplayLink = nil
  }

  @objc private func liveDisplayLinkDidTick(_ displayLink: CADisplayLink) {
    flushPendingLiveStamps()
    publishLiveMetricsIfNeeded(now: displayLink.timestamp)
  }

  private func flushPendingLiveStamps() {
    guard pendingLiveStamps.isEmpty == false else {
      return
    }

    let stamps = pendingLiveStamps
    pendingLiveStamps.removeAll(keepingCapacity: true)
    renderStamps(stamps, into: liveStrokeTexture)
  }

  private func publishLiveMetricsIfNeeded(
    force: Bool = false,
    now: CFTimeInterval = CACurrentMediaTime()
  ) {
    guard force || now - lastLiveMetricsPublishTime >= liveMetricsPublishInterval else {
      return
    }

    lastLiveMetricsPublishTime = now
    onMetricsChange?()
  }

  private func encodeLiveStamps(
    _ canvasStamps: [CGPoint],
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) {
    let visible = visibleContentRect
    let viewportFrame = visibleCanvasFrame
    let target = drawableSize
    guard
      canvasStamps.isEmpty == false,
      visible.width > 0, visible.height > 0,
      viewportFrame.width > 0, viewportFrame.height > 0,
      bounds.width > 0, bounds.height > 0,
      target.width > 0, target.height > 0
    else {
      return
    }

    let drawableScaleX = target.width / bounds.width
    let drawableScaleY = target.height / bounds.height
    let contentToViewScaleX = viewportFrame.width / visible.width
    let contentToViewScaleY = viewportFrame.height / visible.height
    let pixelScaleX = contentToViewScaleX * drawableScaleX
    let pixelScaleY = contentToViewScaleY * drawableScaleY
    let brushPixelScale = (pixelScaleX + pixelScaleY) * 0.5
    let targetSize = SIMD2(Float(target.width), Float(target.height))
    let hardness = Float(brush.hardness)
    let opacity = Float(brush.opacity)
    let pixelRadius = Float(brush.size / 2 * Double(brushPixelScale))

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .load
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(brushPipeline)

    for stamp in canvasStamps {
      var uniforms = BrushUniforms(
        canvasSize: targetSize,
        center: SIMD2(
          Float((viewportFrame.minX + (stamp.x - visible.minX) * contentToViewScaleX) * drawableScaleX),
          Float((viewportFrame.minY + (stamp.y - visible.minY) * contentToViewScaleY) * drawableScaleY)
        ),
        radius: pixelRadius,
        hardness: hardness,
        opacity: opacity
      )

      encoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    encoder.endEncoding()
  }

  private func renderLiveOverlay() {
    guard
      let liveStrokeTexture,
      let blurredImageTexture,
      let drawable = currentDrawable,
      let descriptor = currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return
    }

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return
    }

    encoder.setRenderPipelineState(liveOverlayPipeline)
    encoder.setFragmentTexture(liveStrokeTexture, index: 0)
    encoder.setFragmentTexture(blurredImageTexture, index: 1)
    let drawableScaleX = drawableSize.width / max(bounds.width, 1)
    let drawableScaleY = drawableSize.height / max(bounds.height, 1)
    var overlayUniforms = MetalBrushLiveOverlayUniforms(
      visibleOrigin: visibleContentRect.origin.simdFloat2,
      visibleSize: visibleContentRect.size.simdFloat2,
      viewportOrigin: CGPoint(
        x: visibleCanvasFrame.minX * drawableScaleX,
        y: visibleCanvasFrame.minY * drawableScaleY
      ).simdFloat2,
      viewportSize: CGSize(
        width: visibleCanvasFrame.width * drawableScaleX,
        height: visibleCanvasFrame.height * drawableScaleY
      ).simdFloat2,
      drawableSize: drawableSize.simdFloat2,
      imageSize: canvasSize.simdFloat2
    )
    encoder.setFragmentBytes(
      &overlayUniforms,
      length: MemoryLayout<MetalBrushLiveOverlayUniforms>.stride,
      index: 0
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func clampedContentPoint(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: min(max(point.x, 0), canvasSize.width),
      y: min(max(point.y, 0), canvasSize.height)
    )
  }

  private static func makeBrushPipeline(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "brushVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "brushFragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].rgbBlendOperation = .add
    descriptor.colorAttachments[0].alphaBlendOperation = .add
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func makeLiveOverlayPipeline(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "liveOverlayFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  fileprivate static func makeTileCompositePipeline(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "tileCompositeFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct BrushUniforms {
    float2 canvasSize;
    float2 center;
    float radius;
    float hardness;
    float opacity;
    float padding;
  };

  struct LiveOverlayUniforms {
    float2 visibleOrigin;
    float2 visibleSize;
    float2 viewportOrigin;
    float2 viewportSize;
    float2 drawableSize;
    float2 imageSize;
  };

  struct TileCompositeUniforms {
    float2 canvasOrigin;
    float2 canvasSize;
    float2 imageSize;
  };

  struct BrushVertexOut {
    float4 position [[position]];
    float2 local;
  };

  struct DisplayVertexOut {
    float4 position [[position]];
    float2 uv;
  };

  vertex BrushVertexOut brushVertex(
    uint vertexID [[vertex_id]],
    constant BrushUniforms& brush [[buffer(0)]]
  ) {
    constexpr float2 corners[4] = {
      float2(-1.0, -1.0),
      float2( 1.0, -1.0),
      float2(-1.0,  1.0),
      float2( 1.0,  1.0)
    };

    float2 local = corners[vertexID];
    float2 pixel = brush.center + local * brush.radius;
    float2 position = float2(
      pixel.x / brush.canvasSize.x * 2.0 - 1.0,
      1.0 - pixel.y / brush.canvasSize.y * 2.0
    );

    BrushVertexOut out;
    out.position = float4(position, 0.0, 1.0);
    out.local = local;
    return out;
  }

  fragment float4 brushFragment(
    BrushVertexOut in [[stage_in]],
    constant BrushUniforms& brush [[buffer(0)]]
  ) {
    float distanceFromCenter = length(in.local);
    if (distanceFromCenter > 1.0) {
      return float4(0.0);
    }

    float alpha = 1.0;
    if (brush.hardness < 0.999) {
      float start = clamp(brush.hardness, 0.0, 0.998);
      alpha = 1.0 - smoothstep(start, 1.0, distanceFromCenter);
    }

    alpha *= brush.opacity;
    return float4(alpha, alpha, alpha, alpha);
  }

  vertex DisplayVertexOut displayVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
      float2(-1.0, -1.0),
      float2( 1.0, -1.0),
      float2(-1.0,  1.0),
      float2( 1.0,  1.0)
    };
    constexpr float2 uvs[4] = {
      float2(0.0, 1.0),
      float2(1.0, 1.0),
      float2(0.0, 0.0),
      float2(1.0, 0.0)
    };

    DisplayVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
  }

  fragment float4 liveOverlayFragment(
    DisplayVertexOut in [[stage_in]],
    constant LiveOverlayUniforms& overlay [[buffer(0)]],
    texture2d<float> liveStrokeTexture [[texture(0)]],
    texture2d<float> blurredImageTexture [[texture(1)]]
  ) {
    constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

    float liveAlpha = clamp(liveStrokeTexture.sample(textureSampler, in.uv).a, 0.0, 1.0);
    float2 drawablePixel = in.uv * overlay.drawableSize;
    float2 viewportSize = max(overlay.viewportSize, float2(1.0));
    float2 viewportPosition = (drawablePixel - overlay.viewportOrigin) / viewportSize;
    float2 canvasPoint = overlay.visibleOrigin + viewportPosition * overlay.visibleSize;
    float2 imageUV = clamp(canvasPoint / overlay.imageSize, float2(0.0), float2(1.0));
    float3 blurredColor = blurredImageTexture.sample(textureSampler, imageUV).rgb;

    return float4(blurredColor * liveAlpha, liveAlpha);
  }

  fragment float4 tileCompositeFragment(
    DisplayVertexOut in [[stage_in]],
    constant TileCompositeUniforms& composite [[buffer(0)]],
    texture2d<float> maskTexture [[texture(0)]],
    texture2d<float> blurredImageTexture [[texture(1)]]
  ) {
    constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

    float maskAlpha = clamp(maskTexture.sample(textureSampler, in.uv).a, 0.0, 1.0);
    float2 canvasPoint = composite.canvasOrigin + in.uv * composite.canvasSize;
    float2 imageUV = clamp(canvasPoint / composite.imageSize, float2(0.0), float2(1.0));
    float3 blurredColor = blurredImageTexture.sample(textureSampler, imageUV).rgb;

    return float4(blurredColor * maskAlpha, maskAlpha);
  }
  """
}

private extension CGSize {
  var simdFloat2: SIMD2<Float> {
    SIMD2(Float(width), Float(height))
  }
}

private enum MetalBrushSandboxImageProcessing {
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  static let ciContext = CIContext(options: [
    .workingColorSpace: colorSpace,
    .outputColorSpace: colorSpace,
  ])
}

private extension UIImage {
  var metalBrushSandboxCanvasSize: CGSize {
    let scale = max(self.scale, 1)
    return CGSize(
      width: max((size.width * scale).rounded(), 1),
      height: max((size.height * scale).rounded(), 1)
    )
  }

  func metalBrushSandboxNormalizedImage(canvasSize: CGSize) -> UIImage {
    let targetSize = CGSize(
      width: max(canvasSize.width.rounded(), 1),
      height: max(canvasSize.height.rounded(), 1)
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(origin: .zero, size: targetSize))
      draw(in: CGRect(origin: .zero, size: targetSize))
    }
  }

  func metalBrushSandboxBlurredImage(radius: Double) -> UIImage {
    guard radius > 0.01, let cgImage else {
      return self
    }

    let inputImage = CIImage(cgImage: cgImage)
    let extent = inputImage.extent
    let blurredImage = inputImage
      .clampedToExtent()
      .applyingFilter(
        "CIGaussianBlur",
        parameters: [kCIInputRadiusKey: radius]
      )
      .cropped(to: extent)

    guard let blurredCGImage = MetalBrushSandboxImageProcessing.ciContext.createCGImage(
      blurredImage,
      from: extent
    ) else {
      return self
    }

    return UIImage(cgImage: blurredCGImage, scale: 1, orientation: .up)
  }
}

private extension CGPoint {
  var simdFloat2: SIMD2<Float> {
    SIMD2(Float(x), Float(y))
  }

  func distance(to point: CGPoint) -> CGFloat {
    hypot(x - point.x, y - point.y)
  }

  func midpoint(to point: CGPoint) -> CGPoint {
    CGPoint(
      x: (x + point.x) / 2,
      y: (y + point.y) / 2
    )
  }

  func interpolate(to point: CGPoint, progress: CGFloat) -> CGPoint {
    CGPoint(
      x: x + (point.x - x) * progress,
      y: y + (point.y - y) * progress
    )
  }
}
