import BrightroomEngine
import BrightroomUI
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class MetalBrushSandboxModel {

  let editingStack: EditingStack
  var values = MetalBrushSandboxControlValues()
  var metrics = EditingCanvasMetrics()

  init(source: MetalBrushSandboxSource) {
    editingStack = EditingStack(imageProvider: source.makeImageProvider())
  }

  func reset() {
    editingStack.set(localAdjustments: [])
    metrics = .init()
  }

  func updateValues(
    _ values: MetalBrushSandboxControlValues,
    change: MetalBrushSandboxControlChange
  ) {
    self.values = values

    switch change {
    case .interactionMode, .localEffect, .localEffectValue, .brush, .smoothing:
      break

    case .exposure:
      applyExposure(values.exposure)
    }
  }

  private func applyExposure(_ exposure: Double) {
    editingStack.set(filters: { filters in
      if abs(exposure) < 0.001 {
        filters.exposure = nil
      } else {
        var filter = FilterExposure()
        filter.value = exposure
        filters.exposure = filter
      }
    })
  }
}

struct MetalBrushSandboxRootView: View {

  @State private var model: MetalBrushSandboxModel

  init(source: MetalBrushSandboxSource) {
    _model = State(initialValue: MetalBrushSandboxModel(source: source))
  }

  var body: some View {
    VStack(spacing: 0) {
      SwiftUIEditingCanvasView(
        editingStack: model.editingStack,
        mode: .localAdjustment(effect: model.values.localAdjustmentEffect)
      )
      .interactionMode(model.values.interactionMode)
      .brush(model.values.brush)
      .smoothing(model.values.smoothing)
      .onMetricsChange { metrics in
        model.metrics = metrics
      }
      .background(Color.black)

      MetalBrushSandboxControlsRepresentable(
        values: model.values,
        metrics: model.metrics,
        onReset: {
          model.reset()
        },
        onValuesChange: { values, change in
          model.updateValues(values, change: change)
        }
      )
      .fixedSize(horizontal: false, vertical: true)
    }
    .background(Color.black)
    .accessibilityIdentifier("metal-brush-sandbox-root")
  }
}

private struct MetalBrushSandboxControlsRepresentable: UIViewRepresentable {

  let values: MetalBrushSandboxControlValues
  let metrics: EditingCanvasMetrics
  let onReset: () -> Void
  let onValuesChange: (MetalBrushSandboxControlValues, MetalBrushSandboxControlChange) -> Void

  func makeUIView(context: Context) -> MetalBrushSandboxControlsView {
    let view = MetalBrushSandboxControlsView()
    configure(view)
    return view
  }

  func updateUIView(_ uiView: MetalBrushSandboxControlsView, context: Context) {
    configure(uiView)
  }

  private func configure(_ view: MetalBrushSandboxControlsView) {
    view.configure(values)
    view.updateMetrics(metrics)
    view.onReset = onReset
    view.onValuesChange = onValuesChange
  }
}

struct MetalBrushSandboxControlValues: Equatable {
  var exposure: Double = 0
  var localEffectKind: MetalBrushSandboxLocalEffectKind = .blur
  var brushSize: Double = 56
  var blurRadius: Double = 18
  var localExposure: Double = 0.8
  var hardness: Double = 0.72
  var opacity: Double = 0.9
  var spacing: Double = 0.18
  var smoothingAlgorithm: EditingCanvasStrokeSmoothingAlgorithm = .bezier
  var smoothingStrength: Double = 0.85
  var interactionMode: EditingCanvasInteractionMode = .draw

  var brush: EditingCanvasBrush {
    .init(
      size: brushSize,
      hardness: hardness,
      opacity: opacity,
      spacing: spacing
    )
  }

  var smoothing: EditingCanvasStrokeSmoothingConfiguration {
    .init(
      algorithm: smoothingAlgorithm,
      strength: smoothingStrength
    )
  }

  var localAdjustmentEffect: EditingStack.Edit.LocalAdjustmentEffect {
    switch localEffectKind {
    case .blur:
      return .gaussianBlur(radius: CGFloat(blurRadius))
    case .exposure:
      return .exposure(value: localExposure)
    }
  }
}

enum MetalBrushSandboxLocalEffectKind: String, CaseIterable, Identifiable {
  case blur
  case exposure

  var id: Self { self }

  var title: String {
    switch self {
    case .blur:
      return "Blur"
    case .exposure:
      return "Exposure"
    }
  }
}

enum MetalBrushSandboxControlChange {
  case interactionMode
  case localEffect
  case exposure
  case localEffectValue
  case brush
  case smoothing
}

final class MetalBrushSandboxControlsView: UIView {

  var onReset: (() -> Void)?
  var onValuesChange: ((MetalBrushSandboxControlValues, MetalBrushSandboxControlChange) -> Void)?

  private var values = MetalBrushSandboxControlValues()
  private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
  private let stackView = UIStackView()
  private let resetButton = UIButton(type: .system)
  private let metricsStackView = UIStackView()
  private let zoomMetricsLabel = UILabel()
  private let strokesMetricsLabel = UILabel()
  private let stampsMetricsLabel = UILabel()
  private let fpsMetricsLabel = UILabel()
  private let modeControl = UISegmentedControl(items: EditingCanvasInteractionMode.allCases.map(\.title))
  private let localEffectControl = UISegmentedControl(items: MetalBrushSandboxLocalEffectKind.allCases.map(\.title))
  private let smoothingControl = UISegmentedControl(items: EditingCanvasStrokeSmoothingAlgorithm.allCases.map(\.title))
  private let exposureRow = MetalBrushSandboxSliderRow(
    title: "Exposure",
    range: -1.5...1.5,
    accessibilityIdentifier: "metal-brush-exposure"
  )
  private let smoothingStrengthRow = MetalBrushSandboxSliderRow(
    title: "Strength",
    range: 0...1,
    accessibilityIdentifier: "metal-brush-smoothing-strength"
  )
  private let blurRadiusRow = MetalBrushSandboxSliderRow(
    title: "Blur",
    range: 0...40,
    accessibilityIdentifier: "metal-brush-blur-radius"
  )
  private let localExposureRow = MetalBrushSandboxSliderRow(
    title: "Local EV",
    range: -1.5...1.5,
    accessibilityIdentifier: "metal-brush-local-exposure"
  )
  private let brushSizeRow = MetalBrushSandboxSliderRow(
    title: "Size",
    range: 8...140,
    accessibilityIdentifier: "metal-brush-size"
  )
  private let hardnessRow = MetalBrushSandboxSliderRow(
    title: "Hardness",
    range: 0...1,
    accessibilityIdentifier: "metal-brush-hardness"
  )
  private let opacityRow = MetalBrushSandboxSliderRow(
    title: "Opacity",
    range: 0.05...1,
    accessibilityIdentifier: "metal-brush-opacity"
  )
  private let spacingRow = MetalBrushSandboxSliderRow(
    title: "Spacing",
    range: 0.05...0.6,
    accessibilityIdentifier: "metal-brush-spacing"
  )

  override init(frame: CGRect) {
    super.init(frame: frame)

    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.required, for: .vertical)
    setupView()
    setupActions()
    updateMetrics(.init())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    let fittingWidth = max(bounds.width - 32, 1)
    let stackSize = stackView.systemLayoutSizeFitting(
      CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    return CGSize(
      width: UIView.noIntrinsicMetric,
      height: stackSize.height + 24 + safeAreaInsets.bottom
    )
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    invalidateIntrinsicContentSize()
  }

  func configure(_ values: MetalBrushSandboxControlValues) {
    self.values = values
    modeControl.selectedSegmentIndex = EditingCanvasInteractionMode.allCases.firstIndex(of: values.interactionMode) ?? 0
    localEffectControl.selectedSegmentIndex = MetalBrushSandboxLocalEffectKind.allCases.firstIndex(of: values.localEffectKind) ?? 0
    smoothingControl.selectedSegmentIndex = EditingCanvasStrokeSmoothingAlgorithm.allCases.firstIndex(of: values.smoothingAlgorithm) ?? 0
    exposureRow.value = values.exposure
    smoothingStrengthRow.value = values.smoothingStrength
    blurRadiusRow.value = values.blurRadius
    localExposureRow.value = values.localExposure
    brushSizeRow.value = values.brushSize
    hardnessRow.value = values.hardness
    opacityRow.value = values.opacity
    spacingRow.value = values.spacing
    updateLocalEffectRows()
  }

  func updateMetrics(_ metrics: EditingCanvasMetrics) {
    zoomMetricsLabel.text = String(format: "Zoom %.2fx", metrics.zoomScale)
    strokesMetricsLabel.text = "Strokes \(metrics.strokeCount)"
    stampsMetricsLabel.text = "Stamps \(metrics.stampCount)"
    fpsMetricsLabel.text = String(format: "FPS %.0f", metrics.framesPerSecond)
  }

  private func setupView() {
    backgroundColor = .clear
    accessibilityIdentifier = "metal-brush-controls"

    effectView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(effectView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 10
    effectView.contentView.addSubview(stackView)

    resetButton.setTitle("Reset", for: .normal)
    resetButton.accessibilityIdentifier = "metal-brush-reset"

    metricsStackView.axis = .horizontal
    metricsStackView.spacing = 10
    metricsStackView.alignment = .center
    metricsStackView.distribution = .fill

    for label in [zoomMetricsLabel, strokesMetricsLabel, stampsMetricsLabel, fpsMetricsLabel] {
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      label.textColor = .secondaryLabel
    }
    zoomMetricsLabel.accessibilityIdentifier = "metal-brush-metrics"
    metricsStackView.addArrangedSubview(zoomMetricsLabel)
    metricsStackView.addArrangedSubview(strokesMetricsLabel)
    metricsStackView.addArrangedSubview(stampsMetricsLabel)
    metricsStackView.addArrangedSubview(fpsMetricsLabel)
    metricsStackView.addArrangedSubview(UIView())

    modeControl.accessibilityIdentifier = "metal-brush-interaction-mode"
    localEffectControl.accessibilityIdentifier = "metal-brush-local-effect"
    smoothingControl.accessibilityIdentifier = "metal-brush-smoothing"

    let resetRow = UIStackView(arrangedSubviews: [UIView(), resetButton])
    resetRow.axis = .horizontal

    stackView.addArrangedSubview(resetRow)
    stackView.addArrangedSubview(metricsStackView)
    stackView.addArrangedSubview(modeControl)
    stackView.addArrangedSubview(localEffectControl)
    stackView.addArrangedSubview(smoothingControl)
    stackView.addArrangedSubview(exposureRow)
    stackView.addArrangedSubview(smoothingStrengthRow)
    stackView.addArrangedSubview(blurRadiusRow)
    stackView.addArrangedSubview(localExposureRow)
    stackView.addArrangedSubview(brushSizeRow)
    stackView.addArrangedSubview(hardnessRow)
    stackView.addArrangedSubview(opacityRow)
    stackView.addArrangedSubview(spacingRow)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 12),
      stackView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 16),
      stackView.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -16),
      stackView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
  }

  private func setupActions() {
    resetButton.addTarget(self, action: #selector(resetButtonDidTap), for: .touchUpInside)
    modeControl.addTarget(self, action: #selector(modeControlDidChange), for: .valueChanged)
    localEffectControl.addTarget(self, action: #selector(localEffectControlDidChange), for: .valueChanged)
    smoothingControl.addTarget(self, action: #selector(smoothingControlDidChange), for: .valueChanged)

    exposureRow.onValueChange = { [weak self] value in
      self?.values.exposure = value
      self?.publish(.exposure)
    }
    smoothingStrengthRow.onValueChange = { [weak self] value in
      self?.values.smoothingStrength = value
      self?.publish(.smoothing)
    }
    blurRadiusRow.onValueChange = { [weak self] value in
      self?.values.blurRadius = value
      self?.publish(.localEffectValue)
    }
    localExposureRow.onValueChange = { [weak self] value in
      self?.values.localExposure = value
      self?.publish(.localEffectValue)
    }
    brushSizeRow.onValueChange = { [weak self] value in
      self?.values.brushSize = value
      self?.publish(.brush)
    }
    hardnessRow.onValueChange = { [weak self] value in
      self?.values.hardness = value
      self?.publish(.brush)
    }
    opacityRow.onValueChange = { [weak self] value in
      self?.values.opacity = value
      self?.publish(.brush)
    }
    spacingRow.onValueChange = { [weak self] value in
      self?.values.spacing = value
      self?.publish(.brush)
    }
  }

  @objc
  private func resetButtonDidTap() {
    onReset?()
  }

  @objc
  private func modeControlDidChange() {
    values.interactionMode = EditingCanvasInteractionMode.allCases[safe: modeControl.selectedSegmentIndex] ?? .draw
    publish(.interactionMode)
  }

  @objc
  private func localEffectControlDidChange() {
    values.localEffectKind = MetalBrushSandboxLocalEffectKind.allCases[safe: localEffectControl.selectedSegmentIndex] ?? .blur
    updateLocalEffectRows()
    publish(.localEffect)
  }

  @objc
  private func smoothingControlDidChange() {
    values.smoothingAlgorithm = EditingCanvasStrokeSmoothingAlgorithm.allCases[safe: smoothingControl.selectedSegmentIndex] ?? .bezier
    publish(.smoothing)
  }

  private func publish(_ change: MetalBrushSandboxControlChange) {
    onValuesChange?(values, change)
  }

  private func updateLocalEffectRows() {
    blurRadiusRow.isHidden = values.localEffectKind != .blur
    localExposureRow.isHidden = values.localEffectKind != .exposure
    invalidateIntrinsicContentSize()
  }
}

private final class MetalBrushSandboxSliderRow: UIView {

  var onValueChange: ((Double) -> Void)?

  var value: Double {
    get { Double(slider.value) }
    set {
      slider.value = Float(newValue)
      updateValueLabel(newValue)
    }
  }

  private let range: ClosedRange<Double>
  private let titleLabel = UILabel()
  private let slider = UISlider()
  private let valueLabel = UILabel()

  init(
    title: String,
    range: ClosedRange<Double>,
    accessibilityIdentifier: String
  ) {
    self.range = range
    super.init(frame: .zero)

    titleLabel.text = title
    titleLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    titleLabel.textColor = .secondaryLabel

    slider.minimumValue = Float(range.lowerBound)
    slider.maximumValue = Float(range.upperBound)
    slider.accessibilityIdentifier = accessibilityIdentifier

    valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    valueLabel.textColor = .secondaryLabel
    valueLabel.textAlignment = .right

    setupView()
    slider.addTarget(self, action: #selector(sliderValueDidChange), for: .valueChanged)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    let stackView = UIStackView(arrangedSubviews: [titleLabel, slider, valueLabel])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.spacing = 12
    addSubview(stackView)

    NSLayoutConstraint.activate([
      titleLabel.widthAnchor.constraint(equalToConstant: 72),
      valueLabel.widthAnchor.constraint(equalToConstant: 52),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @objc
  private func sliderValueDidChange() {
    let clampedValue = min(max(Double(slider.value), range.lowerBound), range.upperBound)
    updateValueLabel(clampedValue)
    onValueChange?(clampedValue)
  }

  private func updateValueLabel(_ value: Double) {
    valueLabel.text = String(format: "%.2f", value)
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else {
      return nil
    }
    return self[index]
  }
}
