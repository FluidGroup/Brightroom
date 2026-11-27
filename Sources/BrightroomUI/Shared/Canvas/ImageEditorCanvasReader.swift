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

/// A view that gives its content a proxy for commands to the
/// `ImageEditorCanvas` inside it, the way `ScrollViewReader` gives a
/// `ScrollViewProxy`.
///
/// ```swift
/// ImageEditorCanvasReader { canvas in
///   VStack {
///     ImageEditorCanvas(document: $document)
///     #if os(iOS)
///     Button("Rotate") { canvas.rotateCounterclockwise() }
///     #elseif os(macOS)
///     Button("Zoom In") { canvas.zoomIn() }
///     #endif
///   }
/// }
/// ```
///
/// Call the proxy from actions, such as a button's, not while the content
/// is being built. On iOS the proxy edits the crop; on macOS, where the
/// canvas has no crop guide yet, it zooms.
public struct ImageEditorCanvasReader<Content: View>: View {

  @State private var registry = ImageEditorCanvasRegistry()

  private let content: (ImageEditorCanvasProxy) -> Content

  public init(@ViewBuilder content: @escaping (ImageEditorCanvasProxy) -> Content) {
    self.content = content
  }

  public var body: some View {
    content(ImageEditorCanvasProxy(registry: registry))
      .environment(\.imageEditorCanvasRegistry, registry)
  }
}

/// Sends commands to the `ImageEditorCanvas` inside an
/// `ImageEditorCanvasReader`.
///
/// Each command runs on the canvas at once, and any change it makes is
/// reported before the command returns: the crop guide through
/// `onCropGuideChange(_:)`, a document change through the canvas's binding,
/// and the zoom through `onZoomChange(_:)`. An animated zoom is the
/// exception: its command starts the motion, and the zoom is reported from
/// the frames of the motion.
///
/// A command does nothing when no canvas is mounted, for example while the
/// canvas is still preparing its image. With several canvases under one
/// reader, commands go to the one mounted most recently that is still
/// mounted.
///
/// The crop commands are iOS only, and the zoom commands macOS only.
@MainActor
public struct ImageEditorCanvasProxy {

  private let registry: ImageEditorCanvasRegistry

  init(registry: ImageEditorCanvasRegistry) {
    self.registry = registry
  }

  /// Resets the crop guide to the whole image, level and unturned, and
  /// unlocks its aspect ratio. The document is not written; apply the
  /// pending crop to write it.
  ///
  /// `ImageEditor`'s Reset does more: it writes every parameter of the
  /// document back to its initial value, and the canvas reloads the crop
  /// from the document under the lock the editor passes (kept by a `.fixed`
  /// policy, released by `.selectable`). To do the same, write the feature
  /// you want through the binding, and the lock through
  /// `lockedAspectRatio(_:)`, instead of calling this.
  @available(macOS, unavailable, message: "The macOS canvas has no crop guide yet.")
  public func resetCrop() {
    #if os(iOS)
    registry.canvasView?.resetCrop()
    #endif
  }

  /// Turns the output a further quarter counterclockwise on screen, turning
  /// a locked aspect ratio with it. The document is not written; apply the
  /// pending crop to write it.
  @available(macOS, unavailable, message: "The macOS canvas has no crop guide yet.")
  public func rotateCounterclockwise() {
    #if os(iOS)
    registry.canvasView?.rotateCounterclockwise()
    #endif
  }

  /// Writes the crop guide's pending crop to the document's
  /// `feature.crop`, through the canvas's binding, before returning. Nothing
  /// is written when it selects the same pixels as the document's crop.
  ///
  /// The canvas never commits. Because the write happens before this
  /// returns, `canvas.applyPendingCrop(); document.commit()` puts the crop
  /// in the undo step.
  ///
  /// A straighten edit still in progress (`straightenAngle(_:isEditing:)`
  /// with `isEditing: true` as of the canvas's last update) is first
  /// recorded at the angle on screen, as the end of the edit records it.
  @available(macOS, unavailable, message: "The macOS canvas has no crop guide yet.")
  public func applyPendingCrop() {
    #if os(iOS)
    registry.canvasView?.applyPendingCrop()
    #endif
  }

  /// Zooms in by a factor of two about the centre, from where a running
  /// zoom is heading, so steps compound; at most to the largest zoom. The
  /// zoom animates and is reported from the frames of its motion, unless the
  /// canvas's `areAnimationsEnabled` is false or Reduce Motion is on; then
  /// it applies at once and is reported before this returns.
  @available(iOS, unavailable, message: "The iOS canvas takes no zoom commands yet.")
  public func zoomIn() {
    #if os(macOS)
    registry.canvasView?.zoomIn()
    #endif
  }

  /// Zooms out by a factor of two about the centre, from where a running
  /// zoom is heading, so steps compound; at most to the fit. Animated and
  /// reported as `zoomIn()` is.
  @available(iOS, unavailable, message: "The iOS canvas takes no zoom commands yet.")
  public func zoomOut() {
    #if os(macOS)
    registry.canvasView?.zoomOut()
    #endif
  }

  /// Zooms to the fit, where the whole output shows. Animated and reported
  /// as `zoomIn()` is.
  @available(iOS, unavailable, message: "The iOS canvas takes no zoom commands yet.")
  public func zoomToFit() {
    #if os(macOS)
    registry.canvasView?.zoomToFit()
    #endif
  }

  /// Zooms at once about the centre to `fraction` (clamped to 0...1) of the
  /// way from the fit to the largest zoom, as `ImageEditorCanvas.Zoom.fraction`
  /// measures it, and reports the zoom before returning: what a zoom slider
  /// sets.
  @available(iOS, unavailable, message: "The iOS canvas takes no zoom commands yet.")
  public func zoom(toFraction fraction: Double) {
    #if os(macOS)
    registry.canvasView?.zoom(toFraction: fraction)
    #endif
  }
}

/// The canvases mounted under one registry in the environment
/// (`imageEditorCanvasRegistry`), such as an `ImageEditorCanvasReader`'s, in
/// mount order.
///
/// It is not observable: registering happens during view updates, and
/// must not change SwiftUI state.
@MainActor
final class ImageEditorCanvasRegistry {

  private struct Entry {
    weak var canvasView: EditingCanvasView?
  }

  private var entries: [Entry] = []

  /// The most recently registered canvas that is still registered and
  /// alive.
  var canvasView: EditingCanvasView? {
    entries.last { $0.canvasView != nil }?.canvasView
  }

  /// Adds `canvasView` as the most recent canvas, unless it is registered
  /// already.
  func register(_ canvasView: EditingCanvasView) {
    entries.removeAll { $0.canvasView == nil }
    guard entries.contains(where: { $0.canvasView === canvasView }) == false else {
      return
    }
    entries.append(Entry(canvasView: canvasView))
  }

  func unregister(_ canvasView: EditingCanvasView) {
    entries.removeAll { $0.canvasView == nil || $0.canvasView === canvasView }
  }
}

extension EnvironmentValues {

  @Entry var imageEditorCanvasRegistry: ImageEditorCanvasRegistry? = nil
}
