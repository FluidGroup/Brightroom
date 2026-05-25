//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import SwiftUI
import UIKit

struct BrightroomSteppedSlider<TopMarker: View, Tick: View>: UIViewRepresentable {

  @Environment(\.isEnabled) private var isEnabled
  @Binding var value: Double

  let range: ClosedRange<Double>
  let stepCount: Int
  let style: BrightroomSteppedSliderStyle
  let resetValue: Double?
  let transform: (Double) -> Double
  let hapticIdentity: (Double) -> AnyHashable?
  let onHaptic: () -> Void
  let topMarker: (BrightroomSteppedSliderTickContext) -> TopMarker
  let tick: (BrightroomSteppedSliderTickContext) -> Tick

  init(
    value: Binding<Double>,
    range: ClosedRange<Double>,
    stepCount: Int,
    style: BrightroomSteppedSliderStyle,
    resetValue: Double? = nil,
    transform: @escaping (Double) -> Double,
    hapticIdentity: @escaping (Double) -> AnyHashable?,
    onHaptic: @escaping () -> Void,
    @ViewBuilder topMarker: @escaping (BrightroomSteppedSliderTickContext) -> TopMarker,
    @ViewBuilder tick: @escaping (BrightroomSteppedSliderTickContext) -> Tick
  ) {
    self._value = value
    self.range = range
    self.stepCount = stepCount
    self.style = style
    self.resetValue = resetValue
    self.transform = transform
    self.hapticIdentity = hapticIdentity
    self.onHaptic = onHaptic
    self.topMarker = topMarker
    self.tick = tick
  }

  func makeUIView(context: Context) -> BrightroomSteppedSliderControl<TopMarker, Tick> {
    let uiView = BrightroomSteppedSliderControl(
      configuration: configuration,
      value: value
    )

    uiView.onValueChanged = { newValue in
      Task { @MainActor in
        self.value = newValue
      }
    }

    uiView.isEnabled = isEnabled
    return uiView
  }

  func updateUIView(_ uiView: BrightroomSteppedSliderControl<TopMarker, Tick>, context: Context) {
    uiView.onValueChanged = { newValue in
      Task { @MainActor in
        self.value = newValue
      }
    }

    uiView.isEnabled = isEnabled
    uiView.update(
      configuration: configuration,
      value: value
    )
  }

  private var configuration: BrightroomSteppedSliderConfiguration<TopMarker, Tick> {
    .init(
      range: range,
      stepCount: stepCount,
      style: style,
      resetValue: resetValue,
      transform: transform,
      hapticIdentity: hapticIdentity,
      onHaptic: onHaptic,
      topMarker: topMarker,
      tick: tick
    )
  }
}

struct BrightroomSteppedSliderConfiguration<TopMarker: View, Tick: View> {

  let range: ClosedRange<Double>
  let stepCount: Int
  let style: BrightroomSteppedSliderStyle
  let resetValue: Double?
  let transform: (Double) -> Double
  let hapticIdentity: (Double) -> AnyHashable?
  let onHaptic: () -> Void
  let topMarker: (BrightroomSteppedSliderTickContext) -> TopMarker
  let tick: (BrightroomSteppedSliderTickContext) -> Tick

  var normalizedStepCount: Int {
    max(0, stepCount)
  }

  var contentWidth: CGFloat {
    style.tickWidth + CGFloat(normalizedStepCount) * style.tickPitch
  }

  var contentHeight: CGFloat {
    style.contentHeight
  }

  func tickContext(for index: Int) -> BrightroomSteppedSliderTickContext {
    .init(
      index: index,
      value: rawValue(for: index),
      isMajor: index.isMultiple(of: max(1, style.majorTickInterval))
    )
  }

  func rawValue(for index: Int) -> Double {
    guard normalizedStepCount > 0 else {
      return range.lowerBound
    }

    let ratio = Double(index) / Double(normalizedStepCount)
    return rawValue(forProgress: ratio)
  }

  func rawValue(forProgress progress: Double) -> Double {
    range.lowerBound + (range.upperBound - range.lowerBound) * progress.clamped(to: 0...1)
  }

  func value(forProgress progress: Double) -> Double {
    transform(rawValue(forProgress: progress).clamped(to: range))
  }

  func indexProgress(for value: Double) -> Double {
    guard range.lowerBound != range.upperBound else {
      return 0
    }

    return ((value - range.lowerBound) / (range.upperBound - range.lowerBound))
      .clamped(to: 0...1)
  }

  func floatingIndex(for value: Double) -> CGFloat {
    CGFloat(indexProgress(for: value)) * CGFloat(normalizedStepCount)
  }
}

private final class BrightroomSteppedSliderRenderProxy: ObservableObject {
  @Published var viewportWidth: CGFloat = 0
  @Published var contentOffsetX: CGFloat = 0
}

private struct BrightroomSteppedSliderLayoutGeometry: Equatable {
  let boundsWidth: CGFloat
  let contentWidth: CGFloat
  let horizontalContentInset: CGFloat
}

final class BrightroomSteppedSliderControl<TopMarker: View, Tick: View>: UIControl, UIScrollViewDelegate {

  var onValueChanged: (Double) -> Void = { _ in }

  private var configuration: BrightroomSteppedSliderConfiguration<TopMarker, Tick>
  private let proxy = BrightroomSteppedSliderRenderProxy()
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let hostingController: UIHostingController<BrightroomSteppedSliderTrackView<TopMarker, Tick>>
  private let maskGradientLayer: CAGradientLayer = {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.cgColor,
      UIColor.black.cgColor,
      UIColor.clear.cgColor,
    ]
    gradientLayer.locations = [0, 0.4, 0.6, 1]
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 0)
    return gradientLayer
  }()

  private var value: Double
  private var lastHapticIdentity: AnyHashable?
  private var isAnimatingUserSnap = false
  private var isAnimatingProgrammaticScroll = false
  private var lastLayoutGeometry: BrightroomSteppedSliderLayoutGeometry?
  private var hasLaidOut = false

  init(
    configuration: BrightroomSteppedSliderConfiguration<TopMarker, Tick>,
    value: Double
  ) {
    self.configuration = configuration
    self.value = value.clamped(to: configuration.range)
    self.hostingController = UIHostingController(
      rootView: BrightroomSteppedSliderTrackView(
        configuration: configuration,
        proxy: proxy
      )
    )

    super.init(frame: .zero)

    layer.mask = maskGradientLayer
    backgroundColor = .clear

    scrollView.backgroundColor = .clear
    scrollView.decelerationRate = .fast
    scrollView.delegate = self
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = true
    scrollView.delaysContentTouches = false

    addSubview(scrollView)
    scrollView.addSubview(contentView)

    hostingController.view.backgroundColor = .clear
    hostingController.view.isUserInteractionEnabled = false
    contentView.addSubview(hostingController.view)

    let doubleTapGestureRecognizer = UITapGestureRecognizer(
      target: self,
      action: #selector(handleDoubleTap)
    )
    doubleTapGestureRecognizer.numberOfTapsRequired = 2
    doubleTapGestureRecognizer.cancelsTouchesInView = false
    addGestureRecognizer(doubleTapGestureRecognizer)

    isAccessibilityElement = true
    accessibilityTraits.insert(.adjustable)
    updateAccessibilityValue()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isEnabled: Bool {
    didSet {
      scrollView.isScrollEnabled = isEnabled
      accessibilityTraits = isEnabled ? [.adjustable] : [.notEnabled]
    }
  }

  override var intrinsicContentSize: CGSize {
    CGSize(
      width: UIView.noIntrinsicMetric,
      height: UIView.noIntrinsicMetric
    )
  }

  override func contentHuggingPriority(for axis: NSLayoutConstraint.Axis) -> UILayoutPriority {
    switch axis {
    case .horizontal:
      return .defaultLow
    case .vertical:
      return .defaultHigh
    @unknown default:
      return .defaultLow
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    hasLaidOut = true
    maskGradientLayer.frame = bounds
    scrollView.frame = bounds

    let contentSize = CGSize(
      width: configuration.contentWidth,
      height: max(bounds.height, configuration.contentHeight)
    )
    let contentInset = UIEdgeInsets(
      top: 0,
      left: horizontalContentInset,
      bottom: 0,
      right: horizontalContentInset
    )
    let layoutGeometry = BrightroomSteppedSliderLayoutGeometry(
      boundsWidth: bounds.width,
      contentWidth: contentSize.width,
      horizontalContentInset: contentInset.left
    )
    let canPreserveProgrammaticScrollAnimation = isAnimatingProgrammaticScroll && lastLayoutGeometry == layoutGeometry

    contentView.frame = CGRect(origin: .zero, size: contentSize)
    hostingController.view.frame = contentView.bounds
    scrollView.contentSize = contentSize
    scrollView.contentInset = contentInset

    if isUserScrolling {
      updateRenderProxy()
    } else if canPreserveProgrammaticScrollAnimation {
      updateRenderProxy()
    } else {
      setContentOffsetForValue(value, animated: false)
    }

    lastLayoutGeometry = layoutGeometry
  }

  override func accessibilityIncrement() {
    guard isEnabled else {
      return
    }

    applyAccessibilityStep(1)
  }

  override func accessibilityDecrement() {
    guard isEnabled else {
      return
    }

    applyAccessibilityStep(-1)
  }

  func update(
    configuration: BrightroomSteppedSliderConfiguration<TopMarker, Tick>,
    value: Double
  ) {
    self.configuration = configuration
    hostingController.rootView = BrightroomSteppedSliderTrackView(
      configuration: configuration,
      proxy: proxy
    )

    setNeedsLayout()
    setValue(
      value.clamped(to: configuration.range),
      animated: hasLaidOut
    )
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateRenderProxy()

    guard isUserScrolling else {
      return
    }

    commitValueFromCurrentOffset()
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    isAnimatingUserSnap = false
    isAnimatingProgrammaticScroll = false
  }

  func scrollViewWillEndDragging(
    _ scrollView: UIScrollView,
    withVelocity velocity: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>
  ) {
    targetContentOffset.pointee = targetContentOffsetForNearestTick(
      from: targetContentOffset.pointee
    )
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard decelerate == false else {
      return
    }

    snapToNearestTick(animated: true)
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    snapToNearestTick(animated: false)
    commitValueFromCurrentOffset()
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    updateRenderProxy()
    isAnimatingProgrammaticScroll = false

    if isAnimatingUserSnap {
      isAnimatingUserSnap = false
      commitValueFromCurrentOffset()
    }
  }

  private var horizontalContentInset: CGFloat {
    max(0, bounds.width / 2 - configuration.style.tickWidth / 2)
  }

  private var isUserScrolling: Bool {
    scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
  }

  private func setValue(_ newValue: Double, animated: Bool) {
    let clampedValue = newValue.clamped(to: configuration.range)
    let valueChanged = !Self.isEquivalent(value, to: clampedValue)
    value = clampedValue
    updateAccessibilityValue()

    guard valueChanged || !hasLaidOut else {
      return
    }

    guard isUserScrolling == false else {
      return
    }

    setContentOffsetForValue(
      clampedValue,
      animated: animated && hasLaidOut
    )
  }

  private func setContentOffsetForValue(_ value: Double, animated: Bool) {
    let offset = contentOffsetForFloatingIndex(configuration.floatingIndex(for: value))
    let shouldAnimate = animated && distance(from: scrollView.contentOffset, to: offset) > 0.000_001
    isAnimatingProgrammaticScroll = shouldAnimate
    scrollView.setContentOffset(offset, animated: shouldAnimate)

    if shouldAnimate == false {
      updateRenderProxy()
    }
  }

  private func contentOffsetForFloatingIndex(_ floatingIndex: CGFloat) -> CGPoint {
    let tickCenterX = configuration.style.tickWidth / 2 + floatingIndex * configuration.style.tickPitch
    return CGPoint(
      x: tickCenterX - bounds.width / 2,
      y: -scrollView.adjustedContentInset.top
    )
  }

  private func floatingIndex(forContentOffset contentOffset: CGPoint) -> CGFloat {
    guard configuration.style.tickPitch > 0 else {
      return 0
    }

    let visibleCenterX = contentOffset.x + bounds.width / 2
    let floatingIndex = (visibleCenterX - configuration.style.tickWidth / 2) / configuration.style.tickPitch
    return floatingIndex.clamped(to: 0...CGFloat(configuration.normalizedStepCount))
  }

  private func targetContentOffsetForNearestTick(from proposedContentOffset: CGPoint) -> CGPoint {
    let nearestIndex = floatingIndex(forContentOffset: proposedContentOffset).rounded()
    return contentOffsetForFloatingIndex(nearestIndex)
  }

  private func snapToNearestTick(animated: Bool) {
    let targetContentOffset = targetContentOffsetForNearestTick(from: scrollView.contentOffset)
    guard distance(from: scrollView.contentOffset, to: targetContentOffset) > 0.000_001 else {
      updateRenderProxy()
      return
    }

    isAnimatingUserSnap = animated
    scrollView.setContentOffset(targetContentOffset, animated: animated)

    if animated == false {
      isAnimatingUserSnap = false
      updateRenderProxy()
    }
  }

  private func commitValueFromCurrentOffset() {
    guard configuration.normalizedStepCount > 0 else {
      return
    }

    let progress = Double(floatingIndex(forContentOffset: scrollView.contentOffset)) / Double(configuration.normalizedStepCount)
    let newValue = configuration.value(forProgress: progress)
    guard !Self.isEquivalent(value, to: newValue) else {
      return
    }

    value = newValue
    updateAccessibilityValue()
    triggerHapticIfNeeded(for: newValue)
    onValueChanged(newValue)
    sendActions(for: .valueChanged)
  }

  private func applyAccessibilityStep(_ delta: Int) {
    guard configuration.normalizedStepCount > 0 else {
      return
    }

    let currentIndex = Int(configuration.floatingIndex(for: value).rounded())
    let nextIndex = (currentIndex + delta).clamped(to: 0...configuration.normalizedStepCount)
    let progress = Double(nextIndex) / Double(configuration.normalizedStepCount)
    let newValue = configuration.value(forProgress: progress)

    guard !Self.isEquivalent(value, to: newValue) else {
      return
    }

    value = newValue
    updateAccessibilityValue()
    setContentOffsetForValue(newValue, animated: true)
    triggerHapticIfNeeded(for: newValue)
    onValueChanged(newValue)
    sendActions(for: .valueChanged)
  }

  @objc private func handleDoubleTap() {
    guard isEnabled else {
      return
    }

    guard let resetValue = configuration.resetValue?.clamped(to: configuration.range) else {
      return
    }

    guard !Self.isEquivalent(value, to: resetValue) else {
      return
    }

    value = resetValue
    updateAccessibilityValue()
    setContentOffsetForValue(resetValue, animated: true)
    triggerHapticIfNeeded(for: resetValue)
    onValueChanged(resetValue)
    sendActions(for: .valueChanged)
  }

  private func updateRenderProxy() {
    proxy.viewportWidth = bounds.width
    proxy.contentOffsetX = scrollView.contentOffset.x
  }

  private func updateAccessibilityValue() {
    accessibilityValue = String(format: "%.2f", value)
  }

  private func triggerHapticIfNeeded(for value: Double) {
    guard let identity = configuration.hapticIdentity(value) else {
      lastHapticIdentity = nil
      return
    }

    guard identity != lastHapticIdentity else {
      return
    }

    lastHapticIdentity = identity
    configuration.onHaptic()
  }

  private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
  }

  nonisolated private static func isEquivalent(_ lhs: Double, to rhs: Double) -> Bool {
    abs(lhs - rhs) < 0.000_001
  }
}

private struct BrightroomSteppedSliderTrackView<TopMarker: View, Tick: View>: View {

  let configuration: BrightroomSteppedSliderConfiguration<TopMarker, Tick>
  @ObservedObject var proxy: BrightroomSteppedSliderRenderProxy

  var body: some View {
    HStack(spacing: configuration.style.tickSpacing) {
      ForEach(0...configuration.normalizedStepCount, id: \.self) { index in
        let context = configuration.tickContext(for: index)

        BrightroomSteppedSliderTickItem(
          context: context,
          style: configuration.style,
          activeProgress: activeProgress(for: index),
          topMarker: configuration.topMarker,
          tick: configuration.tick
        )
        .frame(width: configuration.style.tickWidth)
      }
    }
    .frame(
      width: configuration.contentWidth,
      height: configuration.contentHeight,
      alignment: .leading
    )
  }

  private func activeProgress(for index: Int) -> CGFloat {
    guard proxy.viewportWidth > 0, configuration.style.tickPitch > 0 else {
      return 0
    }

    let tickCenterX = configuration.style.tickWidth / 2 + CGFloat(index) * configuration.style.tickPitch
    let visibleCenterX = proxy.contentOffsetX + proxy.viewportWidth / 2
    let distance = abs(tickCenterX - visibleCenterX)
    return max(0, 1 - distance / configuration.style.tickPitch)
  }
}

private struct BrightroomSteppedSliderTickItem<TopMarker: View, Tick: View>: View {

  let context: BrightroomSteppedSliderTickContext
  let style: BrightroomSteppedSliderStyle
  let activeProgress: CGFloat
  let topMarker: (BrightroomSteppedSliderTickContext) -> TopMarker
  let tick: (BrightroomSteppedSliderTickContext) -> Tick

  var body: some View {
    VStack(spacing: 3) {
      topMarker(context)

      tick(context)
        .frame(width: style.tickWidth, height: style.tickHeight)
        .scaleEffect(
          x: Self.scaleWidth(
            activeProgress: activeProgress,
            style: style
          ),
          y: Self.scaleHeight(
            activeProgress: activeProgress,
            style: style
          ),
          anchor: .center
        )
    }
    .frame(height: style.contentHeight)
  }

  nonisolated private static func scaleWidth(
    activeProgress: CGFloat,
    style: BrightroomSteppedSliderStyle
  ) -> CGFloat {
    scale(
      activeProgress: activeProgress,
      inactiveLength: style.tickWidth,
      activeLength: style.activeTickWidth
    )
  }

  nonisolated private static func scaleHeight(
    activeProgress: CGFloat,
    style: BrightroomSteppedSliderStyle
  ) -> CGFloat {
    scale(
      activeProgress: activeProgress,
      inactiveLength: style.tickHeight,
      activeLength: style.activeTickHeight
    )
  }

  nonisolated private static func scale(
    activeProgress: CGFloat,
    inactiveLength: CGFloat,
    activeLength: CGFloat
  ) -> CGFloat {
    guard inactiveLength > 0 else { return 1 }

    let lengthRatio = activeLength / inactiveLength
    return 1 + (lengthRatio - 1) * activeProgress
  }
}

struct BrightroomSteppedSliderStyle {
  var tickWidth: CGFloat
  var tickSpacing: CGFloat
  var tickHeight: CGFloat
  var activeTickWidth: CGFloat
  var activeTickHeight: CGFloat
  var majorTickInterval: Int

  var tickPitch: CGFloat {
    tickWidth + tickSpacing
  }

  fileprivate var contentHeight: CGFloat {
    activeTickHeight + 9
  }

  init(
    tickWidth: CGFloat,
    tickSpacing: CGFloat,
    tickHeight: CGFloat,
    activeTickWidth: CGFloat?,
    activeTickHeight: CGFloat?,
    majorTickInterval: Int
  ) {
    self.tickWidth = tickWidth
    self.tickSpacing = tickSpacing
    self.tickHeight = tickHeight
    self.activeTickWidth = activeTickWidth ?? tickWidth
    self.activeTickHeight = activeTickHeight ?? tickHeight
    self.majorTickInterval = majorTickInterval
  }
}

struct BrightroomSteppedSliderTickContext {
  let index: Int
  let value: Double
  let isMajor: Bool
}

private extension Double {
  func clamped(to range: ClosedRange<Double>) -> Double {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

private extension CGFloat {
  func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

private extension Int {
  func clamped(to range: ClosedRange<Int>) -> Int {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

#if DEBUG
#Preview("Brightroom Stepped Slider") {
  BrightroomSteppedSliderPreview()
}

private struct BrightroomSteppedSliderPreview: View {

  @State private var exposureValue: Double = 0
  @State private var rotationValue: Double = 0
  @State private var strengthValue: Double = 0

  var body: some View {
    VStack(spacing: 28) {
      previewItem(
        title: "Centered",
        value: $exposureValue,
        range: -1...1,
        stepCount: 200,
        style: .previewDense,
        accent: .red,
        markerValue: 0
      )

      previewItem(
        title: "Rotation",
        value: $rotationValue,
        range: -45...45,
        stepCount: 90,
        style: .previewRotation,
        accent: .white,
        markerValue: 0
      )
      .padding(.vertical, 12)
      .padding(.horizontal, 16)
      .background(Color.black)

      previewItem(
        title: "Positive Only",
        value: $strengthValue,
        range: 0...1,
        stepCount: 100,
        style: .previewDense,
        accent: .blue,
        markerValue: 0
      )
    }
    .padding(24)
    .frame(width: 560)
  }

  private func previewItem(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    stepCount: Int,
    style: BrightroomSteppedSliderStyle,
    accent: Color,
    markerValue: Double
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      BrightroomSteppedSlider(
        value: value,
        range: range,
        stepCount: stepCount,
        style: style,
        resetValue: markerValue,
        transform: { $0 },
        hapticIdentity: { _ in nil },
        onHaptic: {},
        topMarker: { context in
          Circle()
            .frame(width: 6, height: 6)
            .opacity(context.isMarker(markerValue) && value.wrappedValue != markerValue ? 1 : 0)
        },
        tick: { context in
          Capsule()
            .foregroundStyle(context.isMajor ? Color.primary : Color.secondary)
        }
      )
      .frame(height: 50)
      .tint(accent)
    }
  }
}

private extension BrightroomSteppedSliderStyle {
  static let previewDense = BrightroomSteppedSliderStyle(
    tickWidth: 2,
    tickSpacing: 4,
    tickHeight: 16,
    activeTickWidth: 3,
    activeTickHeight: 24,
    majorTickInterval: 10
  )

  static let previewRotation = BrightroomSteppedSliderStyle(
    tickWidth: 1,
    tickSpacing: 4,
    tickHeight: 16,
    activeTickWidth: 3,
    activeTickHeight: 24,
    majorTickInterval: 5
  )
}

private extension BrightroomSteppedSliderTickContext {
  func isMarker(_ markerValue: Double) -> Bool {
    abs(value - markerValue) < 0.000_001
  }
}
#endif
