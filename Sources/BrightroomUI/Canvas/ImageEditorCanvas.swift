//
// Copyright (c) 2021 Muukii <muukii.app@gmail.com>
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

import UIKit
import SwiftUI
import BrightroomEngine
import BrightroomParametric

public struct ImageEditorCanvas: View {

  /// The `straightenAngle(_:isEditing:)` input.
  struct StraightenAngleInput: Equatable {
    var angle: Angle?
    var isEditing: Bool
  }

  /// Applies a canvas change to the binding's latest document.
  ///
  /// A change from a canvas prepared for another image is dropped: its crop
  /// and strokes are pixel coordinates of that image, so applying them to
  /// this document would corrupt it. That happens when the host replaces the
  /// document with one of another image while a change is still queued.
  @MainActor
  static func apply(
    _ change: EditingCanvasView.FeatureChange,
    preparedFor source: SourceImage,
    to document: Binding<ImageEditorDocument>
  ) {
    var next = document.wrappedValue
    guard next.source == source else {
      return
    }
    change(&next.feature)
    // Writing an equal value would still invalidate the host's views.
    if next != document.wrappedValue {
      document.wrappedValue = next
    }
  }

  /// Fixed at creation. See the initializer documentation.
  private let cropInsideOverlay: ((CropInteraction?) -> AnyView)?

  /// Fixed at creation. See the initializer documentation.
  private let cropOutsideOverlay: ((CropInteraction?) -> AnyView)?

  private let document: Binding<ImageEditorDocument>

  /// The loader a built-in editor shares with its other views; nil when the
  /// view prepares the document's source image itself.
  private let previewSourceLoader: PreviewSourceLoader?

  /// A feature a built-in editor shows in place of `document.feature`, such
  /// as a slider value not yet written; nil shows the document.
  private let displayedFeature: ImageEditorFeature?

  private var straightenAngleInput = StraightenAngleInput(angle: nil, isEditing: false)
  private var lockedAspectRatioInput: AspectRatio?

  private var onCropGuideChange: (@MainActor (CropGuide) -> Void)?
  private var isCropGuideDisabled = false
  private let areAnimationsEnabled: Bool
  private var clipsToGuide: Bool = false
  /// Fixed at creation. See the initializer documentation.
  private let contentInsets: EdgeInsets?
  private var editingTarget: ImageEditorCanvas.Target? = .crop
  private var brush: Brush = .init(diameter: .viewportPoints(30))

  /// Creates a crop canvas that edits `document`, with custom overlays.
  ///
  /// The view prepares the document's source image for display and shows a
  /// progress indicator until it is ready, or a failure message when the
  /// image's pixels cannot be decoded (the document is left untouched). Changes made on the canvas (the
  /// pending crop, applied through `ImageEditorCanvasProxy.applyPendingCrop()`
  /// or when leaving crop editing, and brush strokes) are applied to the
  /// binding's latest document's `feature`; the
  /// view never commits them to the history, so call `commit()` when a change
  /// should become an undo step. A document set from outside (for example an
  /// undo) is displayed, and its crop reloads the crop guide. A document of
  /// another image rebuilds the canvas.
  ///
  /// A host that sets `document.localBlur` with its own blur before the first
  /// stroke pays for that blur at export until a stroke lands. The canvas
  /// previews a blur mask only when its tree is rooted at a brush, which is
  /// the shape the view authors; another root renders at export only.
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInsets: **Fixed at creation.** The canvas reads the insets,
  ///     and the layout direction that resolves their leading and trailing
  ///     edges, once when it is mounted; later values are ignored. A host
  ///     that derives the insets from safe area or size class must give this
  ///     view a new identity (for example with `.id`) for new insets to take
  ///     effect.
  ///   - cropInsideOverlay: **Fixed at creation.** The builder is invoked by
  ///     the mounted canvas, but the closure itself is installed only once, so
  ///     values it captures are frozen at that point.
  ///   - cropOutsideOverlay: **Fixed at creation.** Same contract as
  ///     `cropInsideOverlay`.
  public init<InsideOverlay: View, OutsideOverlay: View>(
    document: Binding<ImageEditorDocument>,
    areAnimationsEnabled: Bool = true,
    contentInsets: EdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (CropInteraction?) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (CropInteraction?) -> OutsideOverlay
  ) {
    self.document = document
    self.previewSourceLoader = nil
    self.displayedFeature = nil
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInsets = contentInsets
    self.cropInsideOverlay = { AnyView(cropInsideOverlay($0)) }
    self.cropOutsideOverlay = { AnyView(cropOutsideOverlay($0)) }
  }

  /// Creates a crop canvas that edits `document`, with the built-in
  /// overlays.
  ///
  /// See `init(document:areAnimationsEnabled:contentInsets:cropInsideOverlay:cropOutsideOverlay:)`
  /// for how the document is written back and displayed.
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - areAnimationsEnabled: Applied on every update.
  ///   - contentInsets: **Fixed at creation.** The canvas reads the insets,
  ///     and the layout direction that resolves their leading and trailing
  ///     edges, once when it is mounted; later values are ignored. A host
  ///     that derives the insets from safe area or size class must give this
  ///     view a new identity (for example with `.id`) for new insets to take
  ///     effect.
  public init(
    document: Binding<ImageEditorDocument>,
    areAnimationsEnabled: Bool = true,
    contentInsets: EdgeInsets? = nil
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.previewSourceLoader = nil
    self.displayedFeature = nil
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInsets = contentInsets
  }

  /// Creates a crop canvas with the built-in overlays over a loader a
  /// built-in editor already shares for `document`'s source image.
  ///
  /// - Parameter displayedFeature: Shown in place of `document.feature` while
  ///   non-nil. It must differ from the document only in what the editor has
  ///   not written yet (slider values); canvas changes still apply to the
  ///   document.
  init(
    document: Binding<ImageEditorDocument>,
    displayedFeature: ImageEditorFeature?,
    previewSourceLoader: PreviewSourceLoader
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.displayedFeature = displayedFeature
    self.previewSourceLoader = previewSourceLoader
    self.areAnimationsEnabled = true
    self.contentInsets = nil
  }

  public var body: some View {
    let source = document.wrappedValue.source
    if let previewSourceLoader, previewSourceLoader.source == source {
      canvas(previewSourceLoader: previewSourceLoader)
    } else {
      // A new identity per source image: the owned loader, and the canvas bound
      // to it, are rebuilt when the host switches to a document of another image.
      PreviewSourceReader(source: source) { loader in
        canvas(previewSourceLoader: loader)
      }
      .id(source)
    }
  }

  private func canvas(previewSourceLoader: PreviewSourceLoader) -> some View {
    ZStack {
      switch previewSourceLoader.phase {
      case .loaded(let previewSource):
        EditingCanvasRepresentable(
          source: EditingCanvasSource(previewSource),
          feature: displayedFeature ?? document.wrappedValue.feature,
          onFeatureChange: { [document] change in
            Self.apply(change, preparedFor: previewSource.source, to: document)
          },
          cropInsideOverlay: cropInsideOverlay,
          cropOutsideOverlay: cropOutsideOverlay,
          straightenAngleInput: straightenAngleInput,
          lockedAspectRatioInput: lockedAspectRatioInput,
          onCropGuideChange: onCropGuideChange,
          isCropGuideDisabled: isCropGuideDisabled,
          areAnimationsEnabled: areAnimationsEnabled,
          clipsToGuide: clipsToGuide,
          contentInsets: contentInsets,
          editingTarget: editingTarget,
          brush: brush
        )
        // `EditingCanvasView` binds its source once, at creation. Tying the
        // representable's identity to the image makes an image swap rebuild
        // the canvas instead of leaving it bound to the old image.
        .id(previewSource.source)
        .transition(.opacity.animation(.smooth))
      case .failed:
        // Nothing to edit; the host's own controls stay the way out.
        ContentUnavailableView(
          "The image could not be loaded",
          systemImage: "exclamationmark.triangle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.animation(.smooth))
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity.animation(.smooth))
      }
    }
    .task {
      await previewSourceLoader.load()
    }
  }

  /// Calls `action` with the crop guide each time it changes: when the user
  /// moves or resizes it, when the canvas loads or reloads the document's
  /// crop (for example after an undo), and when an input or a command
  /// changes it.
  ///
  /// A change made outside a SwiftUI view update (a gesture or a command) is
  /// reported at once, so the guide is current when the command returns. A
  /// change made while SwiftUI updates the canvas (mounting it, displaying a
  /// new document, or applying an input) is reported on the next main-actor
  /// turn, so `action` can write to state; only the latest guide is
  /// reported. A guide equal to the last one reported is not reported
  /// again. The latest `action` is used; it is re-bound on every update.
  public consuming func onCropGuideChange(
    _ action: @escaping @MainActor (CropGuide) -> Void
  ) -> Self {
    self.onCropGuideChange = action
    return self
  }

  /// Sets whether the crop guide ignores touches. The image can still be
  /// moved and zoomed under the guide to change the crop. The guide is
  /// interactive by default; the value is applied on every update.
  public consuming func cropGuideDisabled(_ disabled: Bool = true) -> Self {
    self.isCropGuideDisabled = disabled
    return self
  }

  /// Sets whether the image canvas is clipped to the crop guide.
  ///
  /// Clipping is disabled by default. Changes are applied to the mounted
  /// canvas on each update.
  public consuming func clipsToGuide(_ clipsToGuide: Bool) -> Self {
    self.clipsToGuide = clipsToGuide
    return self
  }

  /// Sets the straighten angle: the free rotation applied before cropping.
  /// nil leaves the canvas's angle as it is.
  ///
  /// Like the other value inputs, the angle takes effect only when `angle`
  /// or `isEditing` differs from the values of the previous update, so an
  /// angle the host keeps passing does not undo a reset or an undo on the
  /// canvas. A newly mounted canvas, including one rebuilt for another
  /// image, applies the current value. Follow the canvas's angle through
  /// `onCropGuideChange(_:)` (`pendingCrop.straightenRadians`) to show it.
  ///
  /// - Parameters:
  ///   - angle: The angle; a positive angle turns the image clockwise on
  ///     screen, as `CropFeature.straightenRadians` does.
  ///   - isEditing: Pass true while the user is still changing the angle,
  ///     for example while a slider is dragged. The canvas then shows each
  ///     angle without recording the crop. When `isEditing` becomes false,
  ///     the canvas records the crop at `angle`: it fits the guide's
  ///     selection to the straightened image and reports it. An angle that
  ///     changes while `isEditing` is false is recorded at once.
  public consuming func straightenAngle(_ angle: Angle?, isEditing: Bool = false) -> Self {
    self.straightenAngleInput = StraightenAngleInput(angle: angle, isEditing: isEditing)
    return self
  }

  /// Locks the crop guide to an aspect ratio in the output orientation; nil
  /// unlocks it.
  ///
  /// The ratio takes effect only when it differs from the value of the
  /// previous update; a newly mounted canvas applies the current value. The
  /// canvas changes the lock itself: a reset unlocks
  /// it, and turning the output sideways turns the ratio. Passing the same
  /// value again does not restore it; follow the lock through
  /// `onCropGuideChange(_:)` (`lockedAspectRatio`) instead.
  public consuming func lockedAspectRatio(_ ratio: AspectRatio?) -> Self {
    self.lockedAspectRatioInput = ratio
    return self
  }

  /// Sets which part of the feature the canvas's gestures edit (the
  /// adjustment point); nil views the output only. The default is `.crop`.
  ///
  /// Leaving `.crop` commits the visible crop to the document.
  public consuming func editingTarget(_ target: Target?) -> Self {
    self.editingTarget = target
    return self
  }

  /// Sets the brush that paints `localBlur`, including how its strokes are
  /// smoothed. The diameter may be authored in viewport points or image
  /// pixels; the canvas resolves it against its own geometry.
  public consuming func brush(_ brush: Brush) -> Self {
    self.brush = brush
    return self
  }
}

/// Hosts an `EditingCanvasView` once the image and the document are available.
///
/// Internal (not private) so tests can drive its coordinator.
struct EditingCanvasRepresentable: UIViewRepresentable {

  let source: EditingCanvasSource
  let feature: ImageEditorFeature
  let onFeatureChange: @MainActor (_ change: EditingCanvasView.FeatureChange) -> Void
  let cropInsideOverlay: ((CropInteraction?) -> AnyView)?
  let cropOutsideOverlay: ((CropInteraction?) -> AnyView)?
  let straightenAngleInput: ImageEditorCanvas.StraightenAngleInput
  let lockedAspectRatioInput: AspectRatio?
  let onCropGuideChange: (@MainActor (ImageEditorCanvas.CropGuide) -> Void)?
  let isCropGuideDisabled: Bool
  let areAnimationsEnabled: Bool
  let clipsToGuide: Bool
  let contentInsets: EdgeInsets?
  let editingTarget: ImageEditorCanvas.Target?
  let brush: ImageEditorCanvas.Brush

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> EditingCanvasView {
    let view: EditingCanvasView
    if let contentInsets {
      let isRightToLeft = context.environment.layoutDirection == .rightToLeft
      view = .init(
        source: source,
        feature: feature,
        contentInset: UIEdgeInsets(
          top: contentInsets.top,
          left: isRightToLeft ? contentInsets.trailing : contentInsets.leading,
          bottom: contentInsets.bottom,
          right: isRightToLeft ? contentInsets.leading : contentInsets.trailing
        )
      )
    } else {
      view = .init(source: source, feature: feature)
    }

    view.isGuideInteractionEnabled = isCropGuideDisabled == false
    view.areAnimationsEnabled = areAnimationsEnabled
    view.clipsToGuide = clipsToGuide
    view.setBrush(brush)
    // The target is set before loading, so loading never runs the "leave
    // crop editing" commit against an unloaded view.
    view.setEditingTarget(editingTarget)
    bindCropGuideHandler(to: view, coordinator: context.coordinator)
    bindFeatureChangeHandler(to: view, coordinator: context.coordinator)

    // `contentInsets` above and the two overlays below are creation-only inputs,
    // as documented on ImageEditorCanvas's initializers. `updateUIView`
    // deliberately does not re-apply them: `contentInset` is a `let` on
    // EditingCanvasView, and re-installing `AnyView` overlay closures on every update
    // would rebuild the hosted overlays for no gain. Wiring live overlays would
    // need an explicit change token, not an unconditional re-set.
    if let cropInsideOverlay {
      view.setCropInsideOverlay(EditingCanvasView.SwiftUICropInsideOverlay(content: cropInsideOverlay))
    }

    if let cropOutsideOverlay {
      view.setCropOutsideOverlay(EditingCanvasView.SwiftUICropOutsideOverlay(content: cropOutsideOverlay))
    }

    context.coordinator.register(view, in: context.environment.imageEditorCanvasRegistry)
    context.coordinator.applySwiftUIInputs {
      view.loadFeature()
    }

    return view
  }

  func updateUIView(_ canvasView: EditingCanvasView, context: Context) {
    bindCropGuideHandler(to: canvasView, coordinator: context.coordinator)
    bindFeatureChangeHandler(to: canvasView, coordinator: context.coordinator)

    if canvasView.isGuideInteractionEnabled == isCropGuideDisabled {
      canvasView.isGuideInteractionEnabled = isCropGuideDisabled == false
    }

    if canvasView.areAnimationsEnabled != areAnimationsEnabled {
      canvasView.areAnimationsEnabled = areAnimationsEnabled
    }

    // Everything that pushes SwiftUI inputs into EditingCanvasView runs inside the
    // guard. `setFeature` and `setEditingTarget` can report a crop guide
    // or a feature change synchronously, and an unguarded one writes the
    // host's state from inside `updateUIView` — a state mutation during
    // view update. The coordinator defers both. `setBrush` cannot emit
    // today; it is inside for a uniform contract, so a future emitting setter
    // is safe by default.
    //
    // The value inputs take effect only when they change (see
    // `Coordinator.applyStraightenAngle(_:to:)`), so a stale host value never
    // pushes the canvas back.
    //
    // Order matters:
    // - The value inputs run before `setFeature`. When a changed input and a
    //   new document (an undo) arrive together, the document's crop is
    //   loaded last and wins, and it is fitted to the new aspect-ratio lock.
    // - `setFeature` runs before `setEditingTarget`. When an undo and a
    //   switch away from `.crop` arrive together, the crop reloads first, and
    //   leaving `.crop` then commits nothing over the host's undo.
    // - While feature changes are queued, the owner still holds the
    //   feature from before them, so they are applied to it for display.
    context.coordinator.applySwiftUIInputs {
      if canvasView.clipsToGuide != clipsToGuide {
        canvasView.clipsToGuide = clipsToGuide
      }

      context.coordinator.applyStraightenAngle(straightenAngleInput, to: canvasView)
      context.coordinator.applyLockedAspectRatio(lockedAspectRatioInput, to: canvasView)

      canvasView.setBrush(brush)

      // Also refreshes the display for the inputs above.
      canvasView.setFeature(context.coordinator.applyingPendingFeatureChanges(to: feature))
      canvasView.setEditingTarget(editingTarget)
    }

    // The canvas can move under another reader.
    context.coordinator.register(canvasView, in: context.environment.imageEditorCanvasRegistry)
  }

  static func dismantleUIView(_ canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.register(canvasView, in: nil)
  }

  @MainActor
  private func bindCropGuideHandler(to canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.bindCropGuideHandler(
      to: canvasView,
      onCropGuideChange: onCropGuideChange ?? { _ in }
    )
  }

  @MainActor
  private func bindFeatureChangeHandler(to canvasView: EditingCanvasView, coordinator: Coordinator) {
    coordinator.bindFeatureChangeHandler(
      to: canvasView,
      onFeatureChange: onFeatureChange
    )
  }

  @MainActor
  final class Coordinator {

    private var isApplyingSwiftUIInputs = false

    /// The reader's registry the canvas is registered in, so it receives
    /// `ImageEditorCanvasProxy` commands.
    private weak var registry: ImageEditorCanvasRegistry?

    /// Registers `canvasView` in `registry` for proxy commands, leaving the
    /// registry it was in before; nil only leaves it. Registering again in
    /// the same registry keeps its mount order.
    func register(_ canvasView: EditingCanvasView, in registry: ImageEditorCanvasRegistry?) {
      if self.registry !== registry {
        self.registry?.unregister(canvasView)
        self.registry = registry
      }
      registry?.register(canvasView)
    }

    /// The value of each value input when it was last applied; nil before
    /// the first update. An input takes effect only when the host's value
    /// differs, so a value the host keeps passing does not undo what the
    /// canvas did since (a reset, a turn, an undo).
    private var appliedStraightenAngle: ImageEditorCanvas.StraightenAngleInput?
    private var appliedLockedAspectRatio: AspectRatio??

    private var onCropGuideChange: @MainActor (ImageEditorCanvas.CropGuide) -> Void = { _ in }

    /// The crop guide reported while SwiftUI inputs were being applied, not
    /// yet delivered; only the latest is kept.
    private var pendingCropGuide: ImageEditorCanvas.CropGuide?

    /// The last crop guide delivered to `onCropGuideChange`, so an equal one
    /// is not delivered again.
    private var lastDeliveredCropGuide: ImageEditorCanvas.CropGuide?

    /// Feature changes emitted while SwiftUI inputs were being applied, not
    /// yet applied by the owner, in emission order.
    ///
    /// Until they are delivered, the owner still holds the feature from
    /// before them; `updateUIView` displays them applied to it so EditingCanvasView
    /// does not reload the stale crop.
    private var pendingFeatureChanges: [EditingCanvasView.FeatureChange] = []

    private var onFeatureChange: @MainActor (_ change: EditingCanvasView.FeatureChange) -> Void = { _ in }

    /// Routes EditingCanvasView's feature changes to `onFeatureChange`, re-bound on
    /// every update because the host's destination can change.
    func bindFeatureChangeHandler(
      to canvasView: EditingCanvasView,
      onFeatureChange: @escaping @MainActor (_ change: EditingCanvasView.FeatureChange) -> Void
    ) {
      self.onFeatureChange = onFeatureChange
      canvasView.setFeatureChangeHandler { [weak self] change in
        self?.deliverFeatureChange(change)
      }
    }

    /// Applies a change to the owner's feature: now, or on the next
    /// main-actor turn when it was emitted while SwiftUI inputs were being
    /// applied. Changes are delivered in emission order.
    func deliverFeatureChange(_ change: @escaping EditingCanvasView.FeatureChange) {
      if isApplyingSwiftUIInputs {
        if pendingFeatureChanges.isEmpty {
          schedulePendingFeatureDelivery()
        }
        pendingFeatureChanges.append(change)
      } else {
        deliverPendingFeatureChanges()
        onFeatureChange(change)
      }
    }

    /// `feature` with the undelivered changes applied.
    func applyingPendingFeatureChanges(to feature: ImageEditorFeature) -> ImageEditorFeature {
      var feature = feature
      for change in pendingFeatureChanges {
        change(&feature)
      }
      return feature
    }

    private func deliverPendingFeatureChanges() {
      let changes = pendingFeatureChanges
      pendingFeatureChanges = []
      for change in changes {
        onFeatureChange(change)
      }
    }

    private func schedulePendingFeatureDelivery() {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.schedulePendingFeatureDelivery()
          return
        }

        self.deliverPendingFeatureChanges()
      }
    }

    /// Routes EditingCanvasView's crop guides to `onCropGuideChange`,
    /// re-bound on every update because the host's destination can change.
    func bindCropGuideHandler(
      to canvasView: EditingCanvasView,
      onCropGuideChange: @escaping @MainActor (ImageEditorCanvas.CropGuide) -> Void
    ) {
      self.onCropGuideChange = onCropGuideChange
      canvasView.setCropGuideHandler { [weak self] guide in
        self?.deliverCropGuide(guide)
      }
    }

    /// Applies the straighten-angle input when it differs from the last
    /// applied one.
    ///
    /// While the host edits, the angle is shown without recording the crop.
    /// When the edit ends the crop is recorded at the final angle, even
    /// when that angle was already shown; otherwise a changed angle is
    /// recorded at once.
    func applyStraightenAngle(
      _ input: ImageEditorCanvas.StraightenAngleInput,
      to canvasView: EditingCanvasView
    ) {
      let previous = appliedStraightenAngle
      guard input != previous else {
        return
      }
      appliedStraightenAngle = input

      guard let angle = input.angle else {
        return
      }
      if input.isEditing {
        canvasView.setStraightenAngle(angle, recordsCropExtent: false)
      } else if previous?.isEditing == true {
        canvasView.endStraightening(at: angle)
      } else {
        canvasView.setStraightenAngle(angle)
      }
    }

    /// Applies the aspect-ratio lock when it differs from the last applied
    /// one; nil unlocks the guide.
    func applyLockedAspectRatio(
      _ ratio: AspectRatio?,
      to canvasView: EditingCanvasView
    ) {
      guard appliedLockedAspectRatio != .some(ratio) else {
        return
      }
      appliedLockedAspectRatio = .some(ratio)
      canvasView.setLockedAspectRatio(ratio)
    }

    func applySwiftUIInputs(_ body: () -> Void) {
      isApplyingSwiftUIInputs = true
      defer {
        isApplyingSwiftUIInputs = false
      }

      body()
    }

    /// Delivers a crop guide to `onCropGuideChange`: now, or on the next
    /// main-actor turn when it was reported while SwiftUI inputs were being
    /// applied, keeping only the latest. A guide equal to the last one
    /// delivered is dropped.
    func deliverCropGuide(_ guide: ImageEditorCanvas.CropGuide) {
      if isApplyingSwiftUIInputs {
        if pendingCropGuide == nil {
          schedulePendingCropGuideDelivery()
        }
        pendingCropGuide = guide
      } else {
        // A newer guide supersedes the pending one.
        pendingCropGuide = nil
        deliverCropGuideIfChanged(guide)
      }
    }

    private func deliverCropGuideIfChanged(_ guide: ImageEditorCanvas.CropGuide) {
      guard guide != lastDeliveredCropGuide else {
        return
      }
      lastDeliveredCropGuide = guide
      onCropGuideChange(guide)
    }

    private func schedulePendingCropGuideDelivery() {
      Task { @MainActor [weak self] in
        guard let self else { return }

        if self.isApplyingSwiftUIInputs {
          self.schedulePendingCropGuideDelivery()
          return
        }

        guard let guide = self.pendingCropGuide else {
          return
        }

        self.pendingCropGuide = nil
        self.deliverCropGuideIfChanged(guide)
      }
    }
  }

}
