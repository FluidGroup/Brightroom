import BrightroomEngine
import SwiftUI
import UIKit

final class MetalBrushSandboxRootView: UIView {

  private let editingStack: EditingStack
  private let progressView = UIActivityIndicatorView(style: .large)
  private let controlsView = MetalBrushSandboxControlsView()
  private var hostView: MetalBrushSandboxHostView?
  private var values = MetalBrushSandboxControlValues()

  init(image: UIImage) {
    self.editingStack = EditingStack(imageProvider: .init(image: image))
    super.init(frame: .zero)

    backgroundColor = .black
    accessibilityIdentifier = "metal-brush-sandbox-root"
    setupProgressView()
    setupControls()

    editingStack.start { [weak self] in
      self?.installCanvasIfNeeded()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupProgressView() {
    progressView.translatesAutoresizingMaskIntoConstraints = false
    progressView.color = .white
    progressView.startAnimating()
    addSubview(progressView)

    NSLayoutConstraint.activate([
      progressView.centerXAnchor.constraint(equalTo: centerXAnchor),
      progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  private func setupControls() {
    controlsView.configure(values)
    controlsView.onReset = { [weak self] in
      self?.hostView?.reset()
    }
    controlsView.onValuesChange = { [weak self] values, change in
      self?.handleControlValues(values, change: change)
    }
  }

  private func installCanvasIfNeeded() {
    guard hostView == nil, let loadedState = editingStack.loadedState else {
      return
    }

    progressView.stopAnimating()
    progressView.removeFromSuperview()

    let hostView = MetalBrushSandboxHostView(canvasSize: loadedState.metadata.imageSize)
    hostView.translatesAutoresizingMaskIntoConstraints = false
    hostView.onMetricsChange = { [weak self] metrics in
      self?.controlsView.updateMetrics(metrics)
    }
    addSubview(hostView)
    self.hostView = hostView

    controlsView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(controlsView)

    NSLayoutConstraint.activate([
      hostView.topAnchor.constraint(equalTo: topAnchor),
      hostView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostView.bottomAnchor.constraint(equalTo: controlsView.topAnchor),

      controlsView.leadingAnchor.constraint(equalTo: leadingAnchor),
      controlsView.trailingAnchor.constraint(equalTo: trailingAnchor),
      controlsView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    applyExposure(values.exposure)
    applyHostConfiguration()
    hostView.setEditingStack(editingStack, blurRadius: values.blurRadius)
  }

  private func handleControlValues(
    _ values: MetalBrushSandboxControlValues,
    change: MetalBrushSandboxControlChange
  ) {
    self.values = values

    switch change {
    case .interactionMode, .renderMode, .brush, .smoothing:
      applyHostConfiguration()

    case .exposure:
      applyExposure(values.exposure)
      hostView?.reloadEditingStackTiles()

    case .blurRadius:
      hostView?.setEditingStack(editingStack, blurRadius: values.blurRadius)
    }
  }

  private func applyHostConfiguration() {
    hostView?.configure(
      interactionMode: values.interactionMode,
      renderMode: values.renderMode,
      brush: values.brush,
      smoothing: values.smoothing
    )
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

struct MetalBrushSandboxControlValues: Equatable {
  var exposure: Double = 0
  var brushSize: Double = 56
  var blurRadius: Double = 18
  var hardness: Double = 0.72
  var opacity: Double = 0.9
  var spacing: Double = 0.18
  var smoothingAlgorithm: MetalBrushStrokeSmoothingAlgorithm = .bezier
  var smoothingStrength: Double = 0.85
  var interactionMode: MetalBrushSandboxInteractionMode = .draw
  var renderMode: MetalBrushSandboxRenderMode = .full

  var brush: MetalBrushSandboxBrush {
    .init(
      size: brushSize,
      hardness: hardness,
      opacity: opacity,
      spacing: spacing
    )
  }

  var smoothing: MetalBrushStrokeSmoothingConfiguration {
    .init(
      algorithm: smoothingAlgorithm,
      strength: smoothingStrength
    )
  }
}

enum MetalBrushSandboxControlChange {
  case interactionMode
  case renderMode
  case exposure
  case blurRadius
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
  private let modeControl = UISegmentedControl(items: MetalBrushSandboxInteractionMode.allCases.map(\.title))
  private let renderModeControl = UISegmentedControl(items: MetalBrushSandboxRenderMode.allCases.map(\.title))
  private let smoothingControl = UISegmentedControl(items: MetalBrushStrokeSmoothingAlgorithm.allCases.map(\.title))
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
    modeControl.selectedSegmentIndex = MetalBrushSandboxInteractionMode.allCases.firstIndex(of: values.interactionMode) ?? 0
    renderModeControl.selectedSegmentIndex = MetalBrushSandboxRenderMode.allCases.firstIndex(of: values.renderMode) ?? 0
    smoothingControl.selectedSegmentIndex = MetalBrushStrokeSmoothingAlgorithm.allCases.firstIndex(of: values.smoothingAlgorithm) ?? 0
    exposureRow.value = values.exposure
    smoothingStrengthRow.value = values.smoothingStrength
    blurRadiusRow.value = values.blurRadius
    brushSizeRow.value = values.brushSize
    hardnessRow.value = values.hardness
    opacityRow.value = values.opacity
    spacingRow.value = values.spacing
  }

  func updateMetrics(_ metrics: MetalBrushSandboxMetrics) {
    zoomMetricsLabel.text = String(format: "Zoom %.2fx", metrics.zoomScale)
    strokesMetricsLabel.text = "Strokes \(metrics.strokeCount)"
    stampsMetricsLabel.text = "Stamps \(metrics.stampCount)"
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

    for label in [zoomMetricsLabel, strokesMetricsLabel, stampsMetricsLabel] {
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      label.textColor = .secondaryLabel
    }
    zoomMetricsLabel.accessibilityIdentifier = "metal-brush-metrics"
    metricsStackView.addArrangedSubview(zoomMetricsLabel)
    metricsStackView.addArrangedSubview(strokesMetricsLabel)
    metricsStackView.addArrangedSubview(stampsMetricsLabel)
    metricsStackView.addArrangedSubview(UIView())

    modeControl.accessibilityIdentifier = "metal-brush-interaction-mode"
    renderModeControl.accessibilityIdentifier = "metal-brush-render-mode"
    smoothingControl.accessibilityIdentifier = "metal-brush-smoothing"

    let resetRow = UIStackView(arrangedSubviews: [UIView(), resetButton])
    resetRow.axis = .horizontal

    stackView.addArrangedSubview(resetRow)
    stackView.addArrangedSubview(metricsStackView)
    stackView.addArrangedSubview(modeControl)
    stackView.addArrangedSubview(renderModeControl)
    stackView.addArrangedSubview(smoothingControl)
    stackView.addArrangedSubview(exposureRow)
    stackView.addArrangedSubview(smoothingStrengthRow)
    stackView.addArrangedSubview(blurRadiusRow)
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
    renderModeControl.addTarget(self, action: #selector(renderModeControlDidChange), for: .valueChanged)
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
      self?.publish(.blurRadius)
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
    values.interactionMode = MetalBrushSandboxInteractionMode.allCases[safe: modeControl.selectedSegmentIndex] ?? .draw
    publish(.interactionMode)
  }

  @objc
  private func renderModeControlDidChange() {
    values.renderMode = MetalBrushSandboxRenderMode.allCases[safe: renderModeControl.selectedSegmentIndex] ?? .full
    publish(.renderMode)
  }

  @objc
  private func smoothingControlDidChange() {
    values.smoothingAlgorithm = MetalBrushStrokeSmoothingAlgorithm.allCases[safe: smoothingControl.selectedSegmentIndex] ?? .bezier
    publish(.smoothing)
  }

  private func publish(_ change: MetalBrushSandboxControlChange) {
    onValuesChange?(values, change)
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
