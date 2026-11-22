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

#if os(iOS)
import BrightroomParametric
import SwiftUI
import UIKit

/// Hosts an `EditingCanvasView` once the image and the document are available.
///
/// Internal (not private) so tests can drive its coordinator.
struct EditingCanvasRepresentable: UIViewRepresentable {

  let source: EditingCanvasSource
  let feature: ImageEditorFeature
  var adjustmentRendering: AdjustmentRendering = .standard
  let onFeatureChange: @MainActor (_ change: EditingCanvasView.FeatureChange) -> Void
  let cropInsideOverlay: ((CropInteraction) -> AnyView)?
  let cropOutsideOverlay: ((CropInteraction) -> AnyView)?
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
    view.setAdjustmentRendering(adjustmentRendering)
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
      canvasView.setAdjustmentRendering(adjustmentRendering)
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
      canvasView.setCropGuideHandler { [weak self, weak canvasView] guide in
        self?.deliverCropGuide(
          guide,
          defers: canvasView?.isReportingCropGuideFromLayout == true
        )
      }
    }

    /// Applies the straighten-angle input when it differs from the last
    /// applied one.
    ///
    /// While the host edits, the angle is shown without recording the crop.
    /// When the edit ends the crop is recorded at the final angle, even
    /// when that angle was already shown, or at the angle on screen when the
    /// final angle is nil; otherwise a changed angle is recorded at once.
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
        // An edit that ends without an angle ends at the angle on screen.
        if input.isEditing == false, previous?.isEditing == true {
          canvasView.finishStreamedStraightening()
        }
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
      // The first value is the lock the canvas starts with.
      let isInitial = appliedLockedAspectRatio == nil
      appliedLockedAspectRatio = .some(ratio)
      canvasView.setLockedAspectRatio(ratio, isInitial: isInitial)
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
    /// applied or when `defers` is true (a guide reported from layout),
    /// keeping only the latest. A guide equal to the last one delivered is
    /// dropped.
    func deliverCropGuide(_ guide: ImageEditorCanvas.CropGuide, defers: Bool = false) {
      if isApplyingSwiftUIInputs || defers {
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

#endif
