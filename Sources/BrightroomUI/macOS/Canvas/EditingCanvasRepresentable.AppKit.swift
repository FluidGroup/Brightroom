#if os(macOS)
import BrightroomParametric
import SwiftUI

/// Hosts the AppKit `EditingCanvasView` once the image and the document are
/// available. The canvas views only, so nothing is written back.
///
/// Internal (not private) so tests can drive its coordinator.
struct EditingCanvasRepresentable: NSViewRepresentable {

  let source: EditingCanvasSource
  let feature: ImageEditorFeature
  var adjustmentRendering: AdjustmentRendering = .standard
  let areAnimationsEnabled: Bool
  /// The points the fit leaves clear around the output on every side.
  let fitMargin: CGFloat
  /// What VoiceOver calls the canvas; nil leaves it unnamed.
  let canvasAccessibilityLabel: String?
  /// Not edited on macOS yet; a non-nil target is reported once in the log.
  let editingTarget: ImageEditorCanvas.Target?
  let onZoomChange: (@MainActor (ImageEditorCanvas.Zoom) -> Void)?
  let onPointerChange: (@MainActor (CGPoint?) -> Void)?
  /// Called from the click itself, so it is passed to the canvas as it is.
  let pointSampling: (@MainActor (CGPoint) -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> EditingCanvasView {
    let view = EditingCanvasView(source: source, feature: feature)
    view.setAdjustmentRendering(adjustmentRendering)
    view.areAnimationsEnabled = areAnimationsEnabled
    view.fitMargin = fitMargin
    view.setAccessibilityLabel(canvasAccessibilityLabel)
    view.reportEditingTarget(editingTarget)
    view.pointSampling = pointSampling
    bindReportHandlers(to: view, coordinator: context.coordinator)
    context.coordinator.register(view, in: context.environment.imageEditorCanvasRegistry)
    return view
  }

  func updateNSView(_ canvasView: EditingCanvasView, context: Context) {
    canvasView.pointSampling = pointSampling
    if canvasView.accessibilityLabel() != canvasAccessibilityLabel {
      canvasView.setAccessibilityLabel(canvasAccessibilityLabel)
    }
    bindReportHandlers(to: canvasView, coordinator: context.coordinator)
    // A new feature can draw a frame at once, and the coordinator delivers
    // what that frame reports after this update.
    context.coordinator.applySwiftUIInputs {
      canvasView.areAnimationsEnabled = areAnimationsEnabled
      canvasView.fitMargin = fitMargin
      canvasView.setAdjustmentRendering(adjustmentRendering)
      canvasView.setFeature(feature)
      canvasView.reportEditingTarget(editingTarget)
    }
    // The canvas can move under another registry.
    context.coordinator.register(canvasView, in: context.environment.imageEditorCanvasRegistry)
  }

  static func dismantleNSView(_ canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.register(canvasView, in: nil)
    canvasView.invalidate()
  }

  private func bindReportHandlers(to canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.bindReportHandlers(
      to: canvasView,
      onZoomChange: onZoomChange ?? { _ in },
      onPointerChange: onPointerChange ?? { _ in }
    )
  }

  /// Registers the canvas for commands and delivers its reports.
  ///
  /// A report made while SwiftUI inputs are applied, or while the canvas
  /// draws from layout, would change the host's state during a view update,
  /// so it is delivered on the next main-actor turn instead; only the latest
  /// waits. A report equal to the last one delivered is dropped.
  @MainActor
  final class Coordinator {

    /// The registry the canvas is registered in, so it receives commands.
    private weak var registry: ImageEditorCanvasRegistry?

    private var isApplyingSwiftUIInputs = false

    private let zoomDelivery = ReportDelivery<ImageEditorCanvas.Zoom>()
    private let pointerDelivery = ReportDelivery<CGPoint?>()

    /// Registers `canvasView` in `registry`, leaving the registry it was in
    /// before; nil only leaves it. Registering again in the same registry
    /// keeps its mount order.
    func register(_ canvasView: EditingCanvasView, in registry: ImageEditorCanvasRegistry?) {
      if self.registry !== registry {
        self.registry?.unregister(canvasView)
        self.registry = registry
      }
      registry?.register(canvasView)
    }

    /// Routes the canvas's reports to the actions, re-bound on every update
    /// because the host's actions can change.
    func bindReportHandlers(
      to canvasView: EditingCanvasView,
      onZoomChange: @escaping @MainActor (ImageEditorCanvas.Zoom) -> Void,
      onPointerChange: @escaping @MainActor (CGPoint?) -> Void
    ) {
      zoomDelivery.action = onZoomChange
      pointerDelivery.action = onPointerChange
      canvasView.onZoomChange = { [weak self, weak canvasView] zoom in
        self?.deliverZoom(zoom, defers: canvasView?.isInLayout == true)
      }
      canvasView.onPointerChange = { [weak self, weak canvasView] point in
        self?.deliverPointer(point, defers: canvasView?.isInLayout == true)
      }
    }

    func applySwiftUIInputs(_ body: () -> Void) {
      isApplyingSwiftUIInputs = true
      defer {
        isApplyingSwiftUIInputs = false
      }

      body()
    }

    /// Delivers a zoom now, or on the next main-actor turn while SwiftUI
    /// inputs are applied or when `defers` is true (a zoom reported from
    /// layout).
    func deliverZoom(_ zoom: ImageEditorCanvas.Zoom, defers: Bool = false) {
      deliver(zoom, through: zoomDelivery, defers: defers)
    }

    /// Delivers a pointer pixel as `deliverZoom(_:defers:)` delivers a zoom.
    func deliverPointer(_ point: CGPoint?, defers: Bool = false) {
      deliver(point, through: pointerDelivery, defers: defers)
    }

    private func deliver<Value: Equatable>(
      _ value: Value,
      through delivery: ReportDelivery<Value>,
      defers: Bool
    ) {
      if isApplyingSwiftUIInputs || defers {
        if delivery.pending == nil {
          scheduleDelivery(of: delivery)
        }
        delivery.pending = value
      } else {
        // A newer value supersedes the pending one.
        delivery.pending = nil
        delivery.deliverIfChanged(value)
      }
    }

    private func scheduleDelivery<Value: Equatable>(of delivery: ReportDelivery<Value>) {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.scheduleDelivery(of: delivery)
          return
        }

        guard let value = delivery.pending else {
          return
        }

        delivery.pending = nil
        delivery.deliverIfChanged(value)
      }
    }

    /// One kind of report on its way to its action.
    @MainActor
    private final class ReportDelivery<Value: Equatable> {

      var action: @MainActor (Value) -> Void = { _ in }

      /// The value waiting for the next main-actor turn.
      var pending: Value?

      private var lastDelivered: Value?

      func deliverIfChanged(_ value: Value) {
        guard value != lastDelivered else {
          return
        }
        lastDelivered = value
        action(value)
      }
    }
  }
}
#endif
