import BrightroomEngine
import SwiftUI
import UIKit

public struct SwiftUIEditingCanvasView: View {

  private let editingStack: EditingStack
  private var mode: EditingCanvasMode
  private var interactionMode: EditingCanvasInteractionMode?
  private var displayedImageRect: CGRect?
  private var brush = EditingCanvasBrush()
  private var smoothing = EditingCanvasStrokeSmoothingConfiguration()
  private var onMetricsChange: ((EditingCanvasMetrics) -> Void)?

  public init(
    editingStack: EditingStack,
    mode: EditingCanvasMode = .viewportBase
  ) {
    self.editingStack = editingStack
    self.mode = mode
  }

  public var body: some View {
    ZStack {
      if let loadedState = editingStack.loadedState {
        LoadedEditingCanvasRepresentable(
          editingStack: editingStack,
          canvasSize: loadedState.metadata.imageSize,
          mode: mode,
          interactionMode: interactionMode ?? mode.defaultInteractionMode,
          displayedImageRect: displayedImageRect ?? loadedState.currentEdit.crop.cropExtent,
          brush: brush,
          smoothing: smoothing,
          onMetricsChange: onMetricsChange
        )
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      editingStack.start()
    }
  }

  public func mode(_ mode: EditingCanvasMode) -> Self {
    var modified = self
    modified.mode = mode
    return modified
  }

  public func interactionMode(_ interactionMode: EditingCanvasInteractionMode) -> Self {
    var modified = self
    modified.interactionMode = interactionMode
    return modified
  }

  public func displayedImageRect(_ rect: CGRect?) -> Self {
    var modified = self
    modified.displayedImageRect = rect
    return modified
  }

  public func brush(_ brush: EditingCanvasBrush) -> Self {
    var modified = self
    modified.brush = brush
    return modified
  }

  public func smoothing(_ smoothing: EditingCanvasStrokeSmoothingConfiguration) -> Self {
    var modified = self
    modified.smoothing = smoothing
    return modified
  }

  public func onMetricsChange(_ handler: @escaping (EditingCanvasMetrics) -> Void) -> Self {
    var modified = self
    modified.onMetricsChange = handler
    return modified
  }
}

private struct LoadedEditingCanvasRepresentable: UIViewRepresentable {

  let editingStack: EditingStack
  let canvasSize: CGSize
  let mode: EditingCanvasMode
  let interactionMode: EditingCanvasInteractionMode
  let displayedImageRect: CGRect
  let brush: EditingCanvasBrush
  let smoothing: EditingCanvasStrokeSmoothingConfiguration
  let onMetricsChange: ((EditingCanvasMetrics) -> Void)?

  func makeUIView(context: Context) -> _EditingCanvasView {
    let view = _EditingCanvasView(canvasSize: canvasSize)
    configure(view)
    view.setEditingStack(editingStack, mode: mode)
    return view
  }

  func updateUIView(_ uiView: _EditingCanvasView, context: Context) {
    configure(uiView)
    uiView.setEditingStack(editingStack, mode: mode)
  }

  private func configure(_ view: _EditingCanvasView) {
    view.onMetricsChange = onMetricsChange
    view.setDisplayedContentRect(displayedImageRect)
    view.configure(
      mode: mode,
      interactionMode: interactionMode,
      brush: brush,
      smoothing: smoothing
    )
  }
}
