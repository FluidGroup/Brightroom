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

import SwiftUI
import BrightroomEngine
import BrightroomParametric

/// A canvas that shows an `ImageEditorDocument`'s output and edits it through
/// a binding.
///
/// On iOS the canvas edits the part of the feature `editingTarget(_:)`
/// picks: the crop, with a crop guide and the scroll surface, or the local
/// blur, with a brush.
///
/// On macOS the canvas views only, for now: it shows the document's output
/// (effects, local blur, crop and vignette) for every editing target, and the
/// trackpad or the mouse zooms and pans it. It writes nothing to the
/// document. Pass `.editingTarget(nil)` to ask for a viewer: that is
/// portable, and it keeps meaning a viewer when crop editing comes to macOS.
/// The crop and brush modifiers, the overlay initializer and
/// `ImageEditorCanvasReader` are unavailable on macOS. At the fit, where it
/// has nothing to scroll, it passes scroll events on to the views around it.
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
    _ change: (inout ImageEditorFeature) -> Void,
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
  private let cropInsideOverlay: ((CropInteraction) -> AnyView)?

  /// Fixed at creation. See the initializer documentation.
  private let cropOutsideOverlay: ((CropInteraction) -> AnyView)?

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
  /// undo) is displayed, and its crop reloads the crop guide. A crop below
  /// ImageEditor's minimum crop size (128 pixels on its shorter output side,
  /// see `ImageEditor`) is shown exactly, with the crop zoom raised for it,
  /// and is not rewritten when it loads; the first crop gesture records it
  /// grown about its center to the minimum, keeping a locked ratio. A
  /// document of another image rebuilds the canvas.
  ///
  /// A host that sets `document.localBlur` with its own blur before the first
  /// stroke pays for that blur at export until a stroke lands. The canvas
  /// previews and paints a blur mask only when it is a plain `.brush`, the
  /// shape the view authors (`ImageEditorFeature.isLocalBlurPaintable`).
  /// Another mask renders at export only, and the `.localBlur` target then
  /// views the output without painting.
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
  ///   - cropInsideOverlay: Draws over the image inside the crop guide. It
  ///     receives every crop interaction in progress, as
  ///     `CropGuide.interaction` does: empty when idle, and the union when the
  ///     user moves the image and resizes the guide at the same time.
  ///     **Fixed at creation.** The builder is invoked by the mounted canvas,
  ///     but the closure itself is installed only once, so values it
  ///     captures are frozen at that point.
  ///   - cropOutsideOverlay: Draws over the image outside the crop guide,
  ///     with the same interaction as `cropInsideOverlay`. **Fixed at
  ///     creation.** Same contract as `cropInsideOverlay`.
  @available(macOS, unavailable, message: "The macOS canvas has no crop guide yet.")
  public init<InsideOverlay: View, OutsideOverlay: View>(
    document: Binding<ImageEditorDocument>,
    areAnimationsEnabled: Bool = true,
    contentInsets: EdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (CropInteraction) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (CropInteraction) -> OutsideOverlay
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
  /// On macOS the canvas shows the document's output and writes nothing (see
  /// `ImageEditorCanvas`).
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - areAnimationsEnabled: Applied on every update. On macOS it decides
  ///     whether the zoom and pan motions that start animate. When it is
  ///     false, or when the system's Reduce Motion setting is on, the way
  ///     back from a rubber band and a zoom toggle complete at once, and
  ///     momentum stops at an edge instead of bouncing.
  ///   - contentInsets: **Fixed at creation.** The canvas reads the insets,
  ///     and the layout direction that resolves their leading and trailing
  ///     edges, once when it is mounted; later values are ignored. A host
  ///     that derives the insets from safe area or size class must give this
  ///     view a new identity (for example with `.id`) for new insets to take
  ///     effect. They inset the crop guide only: with a `.localBlur` or nil
  ///     editing target the image fits the full bounds. On macOS the value
  ///     is accepted and not used; the image fits the full bounds.
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
        #if os(iOS)
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
        #elseif os(macOS)
        EditingCanvasRepresentable(
          source: EditingCanvasSource(previewSource),
          feature: displayedFeature ?? document.wrappedValue.feature,
          areAnimationsEnabled: areAnimationsEnabled,
          editingTarget: editingTarget
        )
        // `EditingCanvasView` binds its source once, at creation, as on iOS.
        .id(previewSource.source)
        .transition(.opacity.animation(.smooth))
        #endif
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
  @available(macOS, unavailable, message: "The macOS canvas has no crop guide yet.")
  public consuming func onCropGuideChange(
    _ action: @escaping @MainActor (CropGuide) -> Void
  ) -> Self {
    self.onCropGuideChange = action
    return self
  }

  /// Sets whether the crop guide ignores touches. The image can still be
  /// moved and zoomed under the guide to change the crop. The guide is
  /// interactive by default; the value is applied on every update.
  @available(macOS, unavailable, message: "The macOS canvas has no crop guide yet.")
  public consuming func cropGuideDisabled(_ disabled: Bool = true) -> Self {
    self.isCropGuideDisabled = disabled
    return self
  }

  /// Sets whether the image canvas is clipped to the crop guide.
  ///
  /// Clipping is disabled by default. Changes are applied to the mounted
  /// canvas on each update.
  @available(macOS, unavailable, message: "The macOS canvas has no crop guide yet.")
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
  ///     the canvas records the crop at `angle` (at the angle it shows when
  ///     `angle` is nil): it fits the guide's selection to the
  ///     straightened image and reports it. An angle that changes while
  ///     `isEditing` is false is recorded at once. The canvas receives the
  ///     end of the edit on its next update, so
  ///     `ImageEditorCanvasProxy.applyPendingCrop()` records an edit still
  ///     in progress at the angle on screen before writing; ending the edit
  ///     and applying in the same action writes the recorded crop.
  @available(macOS, unavailable, message: "The macOS canvas does not edit the crop yet.")
  public consuming func straightenAngle(_ angle: Angle?, isEditing: Bool = false) -> Self {
    self.straightenAngleInput = StraightenAngleInput(angle: angle, isEditing: isEditing)
    return self
  }

  /// Locks the crop guide to an aspect ratio in the output orientation; nil
  /// unlocks it.
  ///
  /// The ratio takes effect only when it differs from the value of the
  /// previous update; a newly mounted canvas applies the current value. A
  /// crop that already has the ratio keeps its place (within the pixel
  /// rounding of a stored crop); any other crop becomes the largest crop of
  /// the ratio centered in the image. The value a canvas mounts with keeps
  /// such a crop on its pixels, so opening writes nothing; a later value
  /// (a ratio the user picks) aligns it to exactly the ratio, as a recorded
  /// crop is aligned. A crop the document reloads under the
  /// lock (an undo) keeps its place when it has the ratio, and otherwise
  /// becomes the largest crop of the ratio inside it. Crops the guide
  /// records or fits under the lock have exactly the ratio in whole pixels
  /// when its lowest terms are both at most 32 (see `CropGuide.pendingCrop`).
  /// The canvas changes the lock itself: a reset unlocks it, and turning the
  /// output sideways turns the ratio. Passing the same
  /// value again does not restore it; follow the lock through
  /// `onCropGuideChange(_:)` (`lockedAspectRatio`) instead.
  @available(macOS, unavailable, message: "The macOS canvas does not edit the crop yet.")
  public consuming func lockedAspectRatio(_ ratio: AspectRatio?) -> Self {
    self.lockedAspectRatioInput = ratio
    return self
  }

  /// Sets which part of the feature the canvas's gestures edit (the
  /// adjustment point); nil views the output only. The default is `.crop`.
  ///
  /// Leaving `.crop` commits the visible crop to the document.
  ///
  /// On macOS the canvas edits nothing yet: it shows the output for every
  /// target, and writes nothing. In debug builds of BrightroomUI it logs once
  /// per mounted canvas when a non-nil target (the default `.crop` included)
  /// reaches it. `.editingTarget(nil)` is the portable way to ask for a
  /// viewer, and keeps that meaning when crop editing comes to macOS.
  public consuming func editingTarget(_ target: Target?) -> Self {
    self.editingTarget = target
    return self
  }

  /// Sets the brush that paints `localBlur`, including how its strokes are
  /// smoothed. The diameter may be authored in viewport points or image
  /// pixels; the canvas resolves it against its own geometry.
  @available(macOS, unavailable, message: "The macOS canvas does not paint yet.")
  public consuming func brush(_ brush: Brush) -> Self {
    self.brush = brush
    return self
  }
}
