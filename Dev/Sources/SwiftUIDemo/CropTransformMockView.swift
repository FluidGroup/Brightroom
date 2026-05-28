import SwiftUI
import UIKit

struct CropTransformMockView: View {

  @State private var transformState = CropTransformMockTransformState()
  @State private var metrics = CropTransformMockMetrics()
  @State private var resetRequest = 0
  @State private var fitRequest = 0
  private let initialCornerOffsets: [CropTransformMockCorner: CGPoint]
  private let initialGuideRectRatio: CGRect?

  init() {
    let preset = CropTransformMockPreset.current
    self._transformState = State(initialValue: preset.transformState)
    self.initialCornerOffsets = preset.cornerOffsets
    self.initialGuideRectRatio = preset.guideRectRatio
  }

  var body: some View {
    VStack(spacing: 0) {
      CropTransformMockCanvas(
        image: Asset.horizontalRect.image,
        transformState: transformState,
        initialCornerOffsets: initialCornerOffsets,
        initialGuideRectRatio: initialGuideRectRatio,
        resetRequest: resetRequest,
        fitRequest: fitRequest,
        metrics: $metrics
      )
      .background(Color.black)

      controls
    }
    .navigationTitle("Crop Transform Mock")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button {
          fitRequest += 1
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .accessibilityLabel("Fit")

        Button {
          transformState = .init()
          resetRequest += 1
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .accessibilityLabel("Reset")
      }
    }
  }

  private var controls: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(spacing: 12) {
          sliderRow(
            title: "Rotation",
            value: $transformState.rotationDegrees,
            range: -45...45,
            suffix: "deg"
          )

          sliderRow(
            title: "Perspective X",
            value: $transformState.perspectiveXDegrees,
            range: -45...45,
            suffix: "deg"
          )

          sliderRow(
            title: "Perspective Y",
            value: $transformState.perspectiveYDegrees,
            range: -45...45,
            suffix: "deg"
          )
        }

        HStack(spacing: 18) {
          Toggle("Flip H", isOn: $transformState.flipHorizontal)
          Toggle("Flip V", isOn: $transformState.flipVertical)
        }
        .toggleStyle(.switch)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
          debugLine("Zoom", number(metrics.zoomScale))
          debugLine("Offset", pointText(metrics.contentOffset))
          debugLine("Inset", insetText(metrics.contentInset))
          debugLine("Guide", rectText(metrics.guideRectInView))
          debugLine("Crop", rectText(metrics.cropRectInImage))
          debugLine("Quad", quadText(metrics.quadInImage))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      .padding(16)
    }
    .frame(maxHeight: 260)
    .background(.regularMaterial)
  }

  private func sliderRow(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    suffix: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
        Spacer()
        Text("\(number(value.wrappedValue)) \(suffix)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Slider(value: value, in: range)
    }
  }

  private func debugLine(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .frame(width: 44, alignment: .leading)
      Text(value)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
  }

  private func number(_ value: Double) -> String {
    String(format: "%.1f", value)
  }

  private func number(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
  }

  private func pointText(_ point: CGPoint) -> String {
    "x:\(number(point.x)) y:\(number(point.y))"
  }

  private func rectText(_ rect: CGRect) -> String {
    "x:\(number(rect.minX)) y:\(number(rect.minY)) w:\(number(rect.width)) h:\(number(rect.height))"
  }

  private func insetText(_ inset: UIEdgeInsets) -> String {
    "t:\(number(inset.top)) l:\(number(inset.left)) b:\(number(inset.bottom)) r:\(number(inset.right))"
  }

  private func quadText(_ points: [CGPoint]) -> String {
    points
      .map { "(\(number($0.x)),\(number($0.y)))" }
      .joined(separator: " ")
  }
}

private struct CropTransformMockTransformState: Equatable {
  var rotationDegrees: Double = 0
  var perspectiveXDegrees: Double = 0
  var perspectiveYDegrees: Double = 0
  var flipHorizontal = false
  var flipVertical = false
}

private struct CropTransformMockPreset {
  var transformState: CropTransformMockTransformState
  var cornerOffsets: [CropTransformMockCorner: CGPoint]
  var guideRectRatio: CGRect?

  static var current: Self {
    if ProcessInfo.processInfo.arguments.contains("-CropTransformMockTransformed") {
      return .transformed
    }
    return .identity
  }

  static let identity = Self(
    transformState: .init(),
    cornerOffsets: [:],
    guideRectRatio: nil
  )

  static let transformed = Self(
    transformState: .init(
      rotationDegrees: 12,
      perspectiveXDegrees: 24,
      perspectiveYDegrees: -16,
      flipHorizontal: true,
      flipVertical: false
    ),
    cornerOffsets: [
      .topLeft: CGPoint(x: 46, y: 18),
      .topRight: CGPoint(x: -22, y: 42),
      .bottomRight: CGPoint(x: -50, y: -24),
      .bottomLeft: CGPoint(x: 26, y: -46),
    ],
    guideRectRatio: CGRect(x: 0.10, y: 0.24, width: 0.72, height: 0.40)
  )
}

private struct CropTransformMockMetrics: Equatable {
  var zoomScale: CGFloat = 1
  var contentOffset: CGPoint = .zero
  var contentInset: UIEdgeInsets = .zero
  var guideRectInView: CGRect = .zero
  var cropRectInImage: CGRect = .zero
  var quadInImage: [CGPoint] = []
}

private struct CropTransformMockCanvas: UIViewRepresentable {

  let image: UIImage
  let transformState: CropTransformMockTransformState
  let initialCornerOffsets: [CropTransformMockCorner: CGPoint]
  let initialGuideRectRatio: CGRect?
  let resetRequest: Int
  let fitRequest: Int
  @Binding var metrics: CropTransformMockMetrics

  func makeCoordinator() -> Coordinator {
    Coordinator(metrics: $metrics)
  }

  func makeUIView(context: Context) -> CropTransformMockUIKitView {
    let view = CropTransformMockUIKitView(image: image)
    view.applyInitialCornerOffsets(initialCornerOffsets)
    view.setInitialGuideRectRatio(initialGuideRectRatio)
    view.onMetricsChange = { [weak coordinator = context.coordinator] metrics in
      coordinator?.publish(metrics)
    }
    return view
  }

  func updateUIView(_ uiView: CropTransformMockUIKitView, context: Context) {
    context.coordinator.metrics = $metrics
    uiView.onMetricsChange = { [weak coordinator = context.coordinator] metrics in
      coordinator?.publish(metrics)
    }
    uiView.setImage(image)
    uiView.applyInitialCornerOffsets(initialCornerOffsets)
    uiView.setInitialGuideRectRatio(initialGuideRectRatio)
    uiView.setTransformState(transformState)
    uiView.handleResetRequest(resetRequest)
    uiView.handleFitRequest(fitRequest)
  }

  final class Coordinator {
    var metrics: Binding<CropTransformMockMetrics>

    init(metrics: Binding<CropTransformMockMetrics>) {
      self.metrics = metrics
    }

    func publish(_ newValue: CropTransformMockMetrics) {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.metrics.wrappedValue != newValue else {
          return
        }
        self.metrics.wrappedValue = newValue
      }
    }
  }
}

private enum CropTransformMockCorner: CaseIterable {
  case topLeft
  case topRight
  case bottomRight
  case bottomLeft
}

private enum CropTransformGuideHandleKind: CaseIterable {
  case move
  case top
  case right
  case bottom
  case left
}

private final class CropTransformMockUIKitView: UIView, UIScrollViewDelegate {

  var onMetricsChange: (CropTransformMockMetrics) -> Void = { _ in }

  private let scrollView = CropTransformMockScrollView()
  private let zoomContainerView = UIView()
  private let imagePlaneView = UIView()
  private let imageView = UIImageView()
  private let overlayView = CropTransformPassThroughOverlayView()

  private let dimLayer = CAShapeLayer()
  private let guideLayer = CAShapeLayer()
  private let gridLayer = CAShapeLayer()
  private let quadLayer = CAShapeLayer()

  private var guideHandles: [CropTransformGuideHandleKind: CropTransformGuideHandleView] = [:]
  private var handles: [CropTransformMockCorner: CropTransformCornerHandleView] = [:]
  private var cornerOffsets: [CropTransformMockCorner: CGPoint] = [:]
  private var panStartOffsets: [CropTransformMockCorner: CGPoint] = [:]
  private var guidePanStartRect: CGRect?

  private var transformState = CropTransformMockTransformState()
  private var imageSize: CGSize = .zero
  private var lastResetRequest = 0
  private var lastFitRequest = 0
  private var hasAppliedInitialCornerOffsets = false
  private var initialGuideRectRatio: CGRect?
  private var needsInitialFit = true
  private var cropRect: CGRect = .zero
  private let minimumGuideSize = CGSize(width: 96, height: 96)

  init(image: UIImage) {
    super.init(frame: .zero)
    initialize()
    setImage(image)
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
    imageSize = image.size
    configureImageGeometry()
    needsInitialFit = true
    setNeedsLayout()
  }

  func setTransformState(_ transformState: CropTransformMockTransformState) {
    guard self.transformState != transformState else {
      return
    }

    self.transformState = transformState
    applyImageTransform()
    updateZoomScaleLimits()
    emitMetrics()
  }

  func applyInitialCornerOffsets(_ offsets: [CropTransformMockCorner: CGPoint]) {
    guard hasAppliedInitialCornerOffsets == false else {
      return
    }

    hasAppliedInitialCornerOffsets = true
    for (corner, offset) in offsets {
      cornerOffsets[corner] = offset
    }
    updateOverlayLayers()
    emitMetrics()
  }

  func setInitialGuideRectRatio(_ ratio: CGRect?) {
    guard cropRect == .zero else {
      return
    }
    initialGuideRectRatio = ratio
  }

  func handleResetRequest(_ request: Int) {
    guard lastResetRequest != request else {
      return
    }

    lastResetRequest = request
    resetGuide()
    fitImage(animated: false)
  }

  func handleFitRequest(_ request: Int) {
    guard lastFitRequest != request else {
      return
    }

    lastFitRequest = request
    fitImage(animated: true)
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    if scrollView.frame != bounds {
      scrollView.frame = bounds
      scrollView.guideHitTestRect = cropRect
    }

    if cropRect == .zero {
      setGuideRect(makeInitialCropRect(in: bounds), shouldUpdateZoom: false)
    } else {
      setGuideRect(cropRect, shouldUpdateZoom: false)
    }

    if needsInitialFit, cropRect != .zero {
      updateZoomScaleLimits()
      fitImage(animated: false)
    }

    overlayView.frame = bounds
    updateOverlayLayers()
    emitMetrics()
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    zoomContainerView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    updateScrollViewContentInset()
    clampContentOffsetToFillGuide()
    emitMetrics()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    emitMetrics()
  }

  private func initialize() {
    backgroundColor = .black
    clipsToBounds = true

    scrollView.delegate = self
    scrollView.backgroundColor = .clear
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.bounces = false
    scrollView.bouncesZoom = false
    scrollView.decelerationRate = .fast
    scrollView.clipsToBounds = true
    scrollView.alwaysBounceVertical = false
    scrollView.alwaysBounceHorizontal = false
    scrollView.contentInsetAdjustmentBehavior = .never
    addSubview(scrollView)

    imageView.contentMode = .scaleToFill
    imageView.clipsToBounds = true
    imagePlaneView.layer.allowsEdgeAntialiasing = true
    imagePlaneView.layer.isDoubleSided = true
    imagePlaneView.addSubview(imageView)
    zoomContainerView.addSubview(imagePlaneView)
    scrollView.addSubview(zoomContainerView)

    overlayView.isUserInteractionEnabled = true
    addSubview(overlayView)

    dimLayer.fillRule = .evenOdd
    dimLayer.fillColor = UIColor.black.withAlphaComponent(0.56).cgColor
    overlayView.layer.addSublayer(dimLayer)

    guideLayer.fillColor = UIColor.clear.cgColor
    guideLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
    guideLayer.lineWidth = 1.5
    overlayView.layer.addSublayer(guideLayer)

    gridLayer.fillColor = UIColor.clear.cgColor
    gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.42).cgColor
    gridLayer.lineWidth = 1
    overlayView.layer.addSublayer(gridLayer)

    quadLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.12).cgColor
    quadLayer.strokeColor = UIColor.systemYellow.cgColor
    quadLayer.lineWidth = 2
    overlayView.layer.addSublayer(quadLayer)

    for kind in CropTransformGuideHandleKind.allCases {
      let handle = CropTransformGuideHandleView(kind: kind)
      handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleGuidePan(_:))))
      overlayView.addSubview(handle)
      guideHandles[kind] = handle
    }

    for corner in CropTransformMockCorner.allCases {
      let handle = CropTransformCornerHandleView(corner: corner)
      handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleCornerPan(_:))))
      overlayView.addSubview(handle)
      handles[corner] = handle
      cornerOffsets[corner] = .zero
    }
  }

  private func configureImageGeometry() {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return
    }

    scrollView.setZoomScale(1, animated: false)
    zoomContainerView.frame = CGRect(origin: .zero, size: imageSize)
    imagePlaneView.frame = zoomContainerView.bounds
    imageView.frame = imagePlaneView.bounds
    scrollView.contentSize = imageSize
    applyImageTransform()
  }

  private func makeDefaultCropRect(in bounds: CGRect) -> CGRect {
    guard bounds.width > 0, bounds.height > 0 else {
      return .zero
    }

    let available = makeGuideAllowedRect(in: bounds)
    let aspectRatio = CGSize(width: 4, height: 3)
    let size = aspectRatio.sizeThatFits(in: available.size)
    return CGRect(
      x: available.midX - size.width / 2,
      y: available.midY - size.height / 2,
      width: size.width,
      height: size.height
    ).integral
  }

  private func makeInitialCropRect(in bounds: CGRect) -> CGRect {
    guard let initialGuideRectRatio else {
      return makeDefaultCropRect(in: bounds)
    }

    let available = makeGuideAllowedRect(in: bounds)
    return CGRect(
      x: available.minX + available.width * initialGuideRectRatio.minX,
      y: available.minY + available.height * initialGuideRectRatio.minY,
      width: available.width * initialGuideRectRatio.width,
      height: available.height * initialGuideRectRatio.height
    ).integral
  }

  private func makeGuideAllowedRect(in bounds: CGRect) -> CGRect {
    bounds.insetBy(dx: 26, dy: 28)
  }

  private func updateZoomScaleLimits() {
    guard imageSize.width > 0, imageSize.height > 0, cropRect.width > 0, cropRect.height > 0 else {
      return
    }

    let requiredSize = cropRect.size.rotatedBoundingSize(
      radians: CGFloat(transformState.rotationDegrees * .pi / 180)
    )
    let perspectiveBoost = 1 + CGFloat(
      (abs(transformState.perspectiveXDegrees) + abs(transformState.perspectiveYDegrees)) / 160
    )
    let minimumZoomScale = max(
      requiredSize.width / imageSize.width,
      requiredSize.height / imageSize.height
    ) * perspectiveBoost
    let clampedMinimumZoomScale = max(0.01, min(minimumZoomScale, 4))

    scrollView.minimumZoomScale = clampedMinimumZoomScale
    scrollView.maximumZoomScale = max(clampedMinimumZoomScale * 8, clampedMinimumZoomScale + 0.01)

    if scrollView.zoomScale < clampedMinimumZoomScale {
      scrollView.setZoomScale(clampedMinimumZoomScale, animated: false)
    }

    updateScrollViewContentInset()
  }

  private func fitImage(animated: Bool) {
    guard imageSize.width > 0, imageSize.height > 0, cropRect.width > 0, cropRect.height > 0 else {
      needsInitialFit = true
      return
    }

    updateZoomScaleLimits()
    needsInitialFit = false

    let updates = {
      self.scrollView.setZoomScale(self.scrollView.minimumZoomScale, animated: false)
      self.updateScrollViewContentInset()
      self.scrollView.setContentOffset(self.centeredContentOffsetForGuide(), animated: false)
      self.emitMetrics()
    }

    if animated {
      UIViewPropertyAnimator(duration: 0.25, dampingRatio: 1, animations: updates)
        .startAnimation()
    } else {
      UIView.performWithoutAnimation(updates)
    }
  }

  private func applyImageTransform() {
    var transform = CATransform3DIdentity
    transform.m34 = -1 / 850
    transform = CATransform3DScale(
      transform,
      transformState.flipHorizontal ? -1 : 1,
      transformState.flipVertical ? -1 : 1,
      1
    )
    transform = CATransform3DRotate(
      transform,
      CGFloat(transformState.rotationDegrees * .pi / 180),
      0,
      0,
      1
    )
    transform = CATransform3DRotate(
      transform,
      CGFloat(transformState.perspectiveXDegrees * .pi / 180),
      0,
      1,
      0
    )
    transform = CATransform3DRotate(
      transform,
      CGFloat(transformState.perspectiveYDegrees * .pi / 180),
      1,
      0,
      0
    )
    imagePlaneView.layer.transform = transform
  }

  private func resetGuide() {
    for corner in CropTransformMockCorner.allCases {
      cornerOffsets[corner] = .zero
    }
    setGuideRect(makeDefaultCropRect(in: bounds), shouldUpdateZoom: true)
    updateOverlayLayers()
    emitMetrics()
  }

  private func setGuideRect(_ rect: CGRect, shouldUpdateZoom: Bool) {
    let nextRect = constrainedGuideRect(rect)
    guard nextRect != cropRect else {
      return
    }

    cropRect = nextRect
    scrollView.guideHitTestRect = nextRect
    constrainCornerOffsetsForCurrentGuide()

    if shouldUpdateZoom {
      updateZoomScaleLimits()
    } else {
      updateScrollViewContentInset()
    }
    clampContentOffsetToFillGuide()
    updateOverlayLayers()
    emitMetrics()
  }

  private func updateScrollViewContentInset() {
    guard scrollView.bounds.width > 0, scrollView.bounds.height > 0, cropRect != .zero else {
      scrollView.contentInset = .zero
      return
    }

    let contentInsetRect = cropRect.rotatedAroundCenter(
      radians: CGFloat(-transformState.rotationDegrees * .pi / 180)
    )
    let inset = UIEdgeInsets(
      top: contentInsetRect.minY,
      left: contentInsetRect.minX,
      bottom: scrollView.bounds.height - contentInsetRect.maxY,
      right: scrollView.bounds.width - contentInsetRect.maxX
    )

    if scrollView.contentInset != inset {
      scrollView.contentInset = inset
    }
  }

  private func centeredContentOffsetForGuide() -> CGPoint {
    let contentSize = scrollView.contentSize
    let proposed = CGPoint(
      x: contentSize.width / 2 - cropRect.midX,
      y: contentSize.height / 2 - cropRect.midY
    )
    return clampedContentOffset(proposed)
  }

  private func clampContentOffsetToFillGuide() {
    let clamped = clampedContentOffset(scrollView.contentOffset)
    if clamped != scrollView.contentOffset {
      scrollView.setContentOffset(clamped, animated: false)
    }
  }

  private func clampedContentOffset(_ proposed: CGPoint) -> CGPoint {
    let minimum = minimumContentOffset
    let maximum = maximumContentOffset

    return CGPoint(
      x: proposed.x.clamped(
        to: min(minimum.x, maximum.x)...max(minimum.x, maximum.x)
      ),
      y: proposed.y.clamped(
        to: min(minimum.y, maximum.y)...max(minimum.y, maximum.y)
      )
    )
  }

  private var minimumContentOffset: CGPoint {
    CGPoint(
      x: -scrollView.contentInset.left,
      y: -scrollView.contentInset.top
    )
  }

  private var maximumContentOffset: CGPoint {
    let contentInsetRect = cropRect.rotatedAroundCenter(
      radians: CGFloat(-transformState.rotationDegrees * .pi / 180)
    )
    return CGPoint(
      x: scrollView.contentSize.width - contentInsetRect.maxX,
      y: scrollView.contentSize.height - contentInsetRect.maxY
    )
  }

  private func constrainedGuideRect(_ rect: CGRect) -> CGRect {
    let allowed = makeGuideAllowedRect(in: bounds)
    guard allowed.width > 0, allowed.height > 0 else {
      return .zero
    }

    var rect = rect.standardized
    rect.size.width = min(max(rect.width, minimumGuideSize.width), allowed.width)
    rect.size.height = min(max(rect.height, minimumGuideSize.height), allowed.height)
    rect.origin.x = rect.origin.x.clamped(to: allowed.minX...(allowed.maxX - rect.width))
    rect.origin.y = rect.origin.y.clamped(to: allowed.minY...(allowed.maxY - rect.height))
    return rect.integral
  }

  private func constrainCornerOffsetsForCurrentGuide() {
    for corner in CropTransformMockCorner.allCases {
      cornerOffsets[corner] = constrainedOffset(cornerOffsets[corner] ?? .zero, for: corner)
    }
  }

  private func updateOverlayLayers() {
    guard cropRect != .zero else {
      return
    }

    let dimPath = UIBezierPath(rect: bounds)
    dimPath.append(UIBezierPath(rect: cropRect))
    dimLayer.path = dimPath.cgPath

    guideLayer.path = UIBezierPath(rect: cropRect).cgPath
    gridLayer.path = makeGridPath(in: cropRect).cgPath

    let quadPath = UIBezierPath()
    let points = quadPointsInView()
    if let first = points.first {
      quadPath.move(to: first)
      points.dropFirst().forEach { quadPath.addLine(to: $0) }
      quadPath.close()
    }
    quadLayer.path = quadPath.cgPath

    for corner in CropTransformMockCorner.allCases {
      handles[corner]?.center = point(for: corner)
    }

    updateGuideHandleFrames()
  }

  private func updateGuideHandleFrames() {
    guideHandles[.move]?.center = CGPoint(x: cropRect.midX, y: cropRect.midY)
    guideHandles[.top]?.frame = CGRect(
      x: cropRect.midX - 52,
      y: cropRect.minY - 16,
      width: 104,
      height: 32
    )
    guideHandles[.right]?.frame = CGRect(
      x: cropRect.maxX - 16,
      y: cropRect.midY - 52,
      width: 32,
      height: 104
    )
    guideHandles[.bottom]?.frame = CGRect(
      x: cropRect.midX - 52,
      y: cropRect.maxY - 16,
      width: 104,
      height: 32
    )
    guideHandles[.left]?.frame = CGRect(
      x: cropRect.minX - 16,
      y: cropRect.midY - 52,
      width: 32,
      height: 104
    )
  }

  private func makeGridPath(in rect: CGRect) -> UIBezierPath {
    let path = UIBezierPath()
    for index in 1...2 {
      let progress = CGFloat(index) / 3
      let x = rect.minX + rect.width * progress
      path.move(to: CGPoint(x: x, y: rect.minY))
      path.addLine(to: CGPoint(x: x, y: rect.maxY))

      let y = rect.minY + rect.height * progress
      path.move(to: CGPoint(x: rect.minX, y: y))
      path.addLine(to: CGPoint(x: rect.maxX, y: y))
    }
    return path
  }

  private func quadPointsInView() -> [CGPoint] {
    CropTransformMockCorner.allCases.map(point(for:))
  }

  private func point(for corner: CropTransformMockCorner) -> CGPoint {
    let base: CGPoint
    switch corner {
    case .topLeft:
      base = CGPoint(x: cropRect.minX, y: cropRect.minY)
    case .topRight:
      base = CGPoint(x: cropRect.maxX, y: cropRect.minY)
    case .bottomRight:
      base = CGPoint(x: cropRect.maxX, y: cropRect.maxY)
    case .bottomLeft:
      base = CGPoint(x: cropRect.minX, y: cropRect.maxY)
    }

    let offset = cornerOffsets[corner] ?? .zero
    return CGPoint(x: base.x + offset.x, y: base.y + offset.y)
  }

  @objc private func handleCornerPan(_ gesture: UIPanGestureRecognizer) {
    guard let handle = gesture.view as? CropTransformCornerHandleView else {
      return
    }

    let corner = handle.corner
    switch gesture.state {
    case .began:
      panStartOffsets[corner] = cornerOffsets[corner] ?? .zero
    case .changed, .ended:
      let start = panStartOffsets[corner] ?? .zero
      let translation = gesture.translation(in: self)
      cornerOffsets[corner] = constrainedOffset(
        CGPoint(x: start.x + translation.x, y: start.y + translation.y),
        for: corner
      )
      updateOverlayLayers()
      emitMetrics()
    case .cancelled, .failed:
      panStartOffsets[corner] = nil
    case .possible:
      break
    @unknown default:
      break
    }
  }

  @objc private func handleGuidePan(_ gesture: UIPanGestureRecognizer) {
    guard let handle = gesture.view as? CropTransformGuideHandleView else {
      return
    }

    switch gesture.state {
    case .began:
      guidePanStartRect = cropRect
    case .changed, .ended:
      let start = guidePanStartRect ?? cropRect
      let translation = gesture.translation(in: self)
      setGuideRect(
        proposedGuideRect(
          from: start,
          kind: handle.kind,
          translation: translation
        ),
        shouldUpdateZoom: true
      )
    case .cancelled, .failed:
      guidePanStartRect = nil
    case .possible:
      break
    @unknown default:
      break
    }
  }

  private func proposedGuideRect(
    from start: CGRect,
    kind: CropTransformGuideHandleKind,
    translation: CGPoint
  ) -> CGRect {
    let allowed = makeGuideAllowedRect(in: bounds)
    var rect = start

    switch kind {
    case .move:
      rect.origin.x = (start.origin.x + translation.x)
        .clamped(to: allowed.minX...(allowed.maxX - start.width))
      rect.origin.y = (start.origin.y + translation.y)
        .clamped(to: allowed.minY...(allowed.maxY - start.height))
    case .top:
      let minY = (start.minY + translation.y)
        .clamped(to: allowed.minY...(start.maxY - minimumGuideSize.height))
      rect.origin.y = minY
      rect.size.height = start.maxY - minY
    case .right:
      let maxX = (start.maxX + translation.x)
        .clamped(to: (start.minX + minimumGuideSize.width)...allowed.maxX)
      rect.size.width = maxX - start.minX
    case .bottom:
      let maxY = (start.maxY + translation.y)
        .clamped(to: (start.minY + minimumGuideSize.height)...allowed.maxY)
      rect.size.height = maxY - start.minY
    case .left:
      let minX = (start.minX + translation.x)
        .clamped(to: allowed.minX...(start.maxX - minimumGuideSize.width))
      rect.origin.x = minX
      rect.size.width = start.maxX - minX
    }

    return rect
  }

  private func constrainedOffset(_ offset: CGPoint, for corner: CropTransformMockCorner) -> CGPoint {
    let limit = min(cropRect.width, cropRect.height) * 0.42
    let xRange: ClosedRange<CGFloat>
    let yRange: ClosedRange<CGFloat>

    switch corner {
    case .topLeft:
      xRange = 0...limit
      yRange = 0...limit
    case .topRight:
      xRange = -limit...0
      yRange = 0...limit
    case .bottomRight:
      xRange = -limit...0
      yRange = -limit...0
    case .bottomLeft:
      xRange = 0...limit
      yRange = -limit...0
    }

    return CGPoint(
      x: offset.x.clamped(to: xRange),
      y: offset.y.clamped(to: yRange)
    )
  }

  private func emitMetrics() {
    guard imageSize.width > 0, imageSize.height > 0, scrollView.zoomScale > 0 else {
      return
    }

    let cropRectInImage = CGRect(
      x: (scrollView.contentOffset.x + cropRect.minX) / scrollView.zoomScale,
      y: (scrollView.contentOffset.y + cropRect.minY) / scrollView.zoomScale,
      width: cropRect.width / scrollView.zoomScale,
      height: cropRect.height / scrollView.zoomScale
    )

    let quadInImage = quadPointsInView().map { point -> CGPoint in
      let pointInScrollView = convert(point, to: scrollView)
      return CGPoint(
        x: (pointInScrollView.x + scrollView.contentOffset.x) / scrollView.zoomScale,
        y: (pointInScrollView.y + scrollView.contentOffset.y) / scrollView.zoomScale
      )
    }

    onMetricsChange(
      CropTransformMockMetrics(
        zoomScale: scrollView.zoomScale,
        contentOffset: scrollView.contentOffset,
        contentInset: scrollView.contentInset,
        guideRectInView: cropRect,
        cropRectInImage: cropRectInImage,
        quadInImage: quadInImage
      )
    )
  }
}

private final class CropTransformMockScrollView: UIScrollView {

  var guideHitTestRect: CGRect = .zero

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guideHitTestRect
      .offsetBy(dx: bounds.origin.x, dy: bounds.origin.y)
      .insetBy(dx: -8, dy: -8)
      .contains(point)
  }
}

private final class CropTransformPassThroughOverlayView: UIView {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    subviews.contains { subview in
      guard subview.isHidden == false, subview.alpha > 0.01 else {
        return false
      }
      let convertedPoint = convert(point, to: subview)
      return subview.point(inside: convertedPoint, with: event)
    }
  }
}

private final class CropTransformGuideHandleView: UIView {

  let kind: CropTransformGuideHandleKind
  private let visibleView = UIView()

  init(kind: CropTransformGuideHandleKind) {
    self.kind = kind
    super.init(frame: kind == .move ? CGRect(x: 0, y: 0, width: 42, height: 42) : .zero)

    backgroundColor = .clear
    addSubview(visibleView)
    visibleView.backgroundColor = UIColor.white.withAlphaComponent(0.92)
    visibleView.layer.borderWidth = 1
    visibleView.layer.borderColor = UIColor.black.withAlphaComponent(0.42).cgColor
    visibleView.isUserInteractionEnabled = false
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.22
    layer.shadowRadius = 6
    layer.shadowOffset = CGSize(width: 0, height: 2)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    switch kind {
    case .move:
      visibleView.frame = bounds.insetBy(dx: 6, dy: 6)
      visibleView.layer.cornerRadius = visibleView.bounds.width / 2
    case .top, .bottom:
      visibleView.frame = CGRect(
        x: (bounds.width - 52) / 2,
        y: (bounds.height - 5) / 2,
        width: 52,
        height: 5
      )
      visibleView.layer.cornerRadius = 2.5
    case .left, .right:
      visibleView.frame = CGRect(
        x: (bounds.width - 5) / 2,
        y: (bounds.height - 52) / 2,
        width: 5,
        height: 52
      )
      visibleView.layer.cornerRadius = 2.5
    }
  }
}

private final class CropTransformCornerHandleView: UIView {

  let corner: CropTransformMockCorner

  init(corner: CropTransformMockCorner) {
    self.corner = corner
    super.init(frame: CGRect(x: 0, y: 0, width: 26, height: 26))

    backgroundColor = .systemYellow
    layer.cornerRadius = 13
    layer.borderWidth = 2
    layer.borderColor = UIColor.black.withAlphaComponent(0.7).cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.28
    layer.shadowRadius = 8
    layer.shadowOffset = CGSize(width: 0, height: 2)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private extension CGSize {
  func sizeThatFits(in bounds: CGSize) -> CGSize {
    guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else {
      return .zero
    }

    let scale = min(bounds.width / width, bounds.height / height)
    return CGSize(width: width * scale, height: height * scale)
  }

  func rotatedBoundingSize(radians: CGFloat) -> CGSize {
    let rect = CGRect(origin: .zero, size: self)
      .applying(CGAffineTransform(rotationAngle: radians))
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }
}

private extension CGRect {
  func rotatedAroundCenter(radians: CGFloat) -> CGRect {
    let rotated = CGRect(origin: .zero, size: size)
      .applying(CGAffineTransform(rotationAngle: radians))

    return CGRect(
      x: midX - rotated.width / 2,
      y: midY - rotated.height / 2,
      width: rotated.width,
      height: rotated.height
    )
  }
}

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

#Preview {
  NavigationStack {
    CropTransformMockView()
  }
}
