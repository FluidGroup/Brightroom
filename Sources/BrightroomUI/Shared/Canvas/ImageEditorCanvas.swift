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
/// The canvas prepares the document's source image for display itself, or
/// shows the preview of a `PreviewSourceLoader` that the host shares with
/// its other views (see `PreviewSourceReader`), so the image is decoded once.
/// `displayedFeature(_:)` draws a feature the host has not written yet in
/// place of the document's.
///
/// On iOS the canvas edits the part of the feature `editingTarget(_:)`
/// picks: the crop, with a crop guide and the scroll surface, or the local
/// blur, with a brush.
///
/// On macOS the canvas views only, for now: it shows the document's output
/// (effects, local blur, crop and vignette) for every editing target, and the
/// trackpad or the mouse zooms and pans it; dragging with the mouse pans once
/// zoomed in. Zoomed in, a click gives it the keyboard (with Full Keyboard
/// Access, so does Tab), and the arrow keys pan it by a tenth of its size, or
/// nine tenths with Option. With Full Keyboard Access on, it shows the system
/// focus ring inside its edges while it has the keyboard and is zoomed in.
/// VoiceOver reads its zoom, such as "36%", as its value. It writes nothing
/// to the document. Pass `.editingTarget(nil)` to ask for a viewer: that is
/// portable, and it keeps meaning a viewer when crop editing comes to macOS.
/// At the fit, where it has nothing to scroll, it passes scroll events on to
/// the views around it.
///
/// Only on macOS, the canvas reports its zoom (`onZoomChange(_:)`) and the
/// pixel under the pointer (`onPointerChange(_:)`), samples points
/// (`pointSampling(_:)`), keeps a margin at the fit (`fitMargin(_:)`), takes
/// a name for VoiceOver (`canvasAccessibilityLabel(_:)`), and takes zoom
/// commands from an `ImageEditorCanvasReader`'s proxy. The crop and brush
/// modifiers, the overlay initializer and the proxy's crop commands are
/// unavailable on macOS.
public struct ImageEditorCanvas: View {

  @Environment(\.adjustmentRendering) private var adjustmentRendering

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

  /// The loader the host shares with its other views. The view uses it when
  /// it is the loader of the document's source image, and otherwise prepares
  /// the image itself.
  private let previewSourceLoader: PreviewSourceLoader?

  /// Drawn in place of `document.feature` while non-nil, with the member the
  /// editing target edits taken from the document (`drawnFeature`).
  private var displayedFeature: ImageEditorFeature?

  /// The message a built-in editor shows when the image's pixels cannot be
  /// decoded; nil shows the canvas's own.
  private var failureMessage: String?

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
  #if os(macOS)
  private var onZoomChange: (@MainActor (Zoom) -> Void)?
  private var onPointerChange: (@MainActor (CGPoint?) -> Void)?
  private var pointSampling: (@MainActor (CGPoint) -> Void)?
  private var fitMargin: CGFloat = 0
  private var canvasAccessibilityLabel: String?
  #endif

  /// Creates a crop canvas that edits `document`, with custom overlays.
  ///
  /// The view prepares the document's source image for display, or uses
  /// `previewSourceLoader`, and shows a progress indicator until it is ready,
  /// or a failure message when the image's pixels cannot be decoded (the
  /// document is left untouched). Changes made on the canvas (the
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
  ///   - previewSourceLoader: The loader of the document's source image that
  ///     the host shares with its other views, so the image is decoded once
  ///     (see `PreviewSourceReader`); the canvas starts it when it appears.
  ///     Pass it from the start: a canvas that receives one later rebuilds
  ///     on it. With nil, or a loader of another image, which is ignored,
  ///     the canvas prepares the document's image itself.
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
    previewSourceLoader: PreviewSourceLoader? = nil,
    areAnimationsEnabled: Bool = true,
    contentInsets: EdgeInsets? = nil,
    @ViewBuilder cropInsideOverlay: @escaping (CropInteraction) -> InsideOverlay,
    @ViewBuilder cropOutsideOverlay: @escaping (CropInteraction) -> OutsideOverlay
  ) {
    self.document = document
    self.previewSourceLoader = previewSourceLoader
    self.displayedFeature = nil
    self.failureMessage = nil
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInsets = contentInsets
    self.cropInsideOverlay = { AnyView(cropInsideOverlay($0)) }
    self.cropOutsideOverlay = { AnyView(cropOutsideOverlay($0)) }
  }

  /// Creates a crop canvas that edits `document`, with the built-in
  /// overlays.
  ///
  /// See `init(document:previewSourceLoader:areAnimationsEnabled:contentInsets:cropInsideOverlay:cropOutsideOverlay:)`
  /// for how the document is written back and displayed.
  ///
  /// On macOS the canvas shows the document's output and writes nothing (see
  /// `ImageEditorCanvas`).
  ///
  /// - Parameters:
  ///   - document: The edited document.
  ///   - previewSourceLoader: The loader of the document's source image that
  ///     the host shares with its other views, so the image is decoded once
  ///     (see `PreviewSourceReader`); the canvas starts it when it appears.
  ///     Pass it from the start: a canvas that receives one later rebuilds
  ///     on it. With nil, or a loader of another image, which is ignored,
  ///     the canvas prepares the document's image itself.
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
    previewSourceLoader: PreviewSourceLoader? = nil,
    areAnimationsEnabled: Bool = true,
    contentInsets: EdgeInsets? = nil
  ) {
    self.cropInsideOverlay = nil
    self.cropOutsideOverlay = nil
    self.document = document
    self.previewSourceLoader = previewSourceLoader
    self.displayedFeature = nil
    self.failureMessage = nil
    self.areAnimationsEnabled = areAnimationsEnabled
    self.contentInsets = contentInsets
  }

  /// Creates a crop canvas with the built-in overlays over the loader a
  /// built-in editor shares for `document`'s source image.
  ///
  /// - Parameters:
  ///   - displayedFeature: Drawn as `displayedFeature(_:)` draws it.
  ///   - failureMessage: Shown in place of the canvas's own message when the
  ///     image's pixels cannot be decoded: the editor's localized string.
  init(
    document: Binding<ImageEditorDocument>,
    displayedFeature: ImageEditorFeature?,
    previewSourceLoader: PreviewSourceLoader,
    failureMessage: String? = nil
  ) {
    self.init(document: document, previewSourceLoader: previewSourceLoader)
    self.displayedFeature = displayedFeature
    self.failureMessage = failureMessage
  }

  /// What the canvas draws: `displayedFeature` with the member that
  /// `editingTarget` edits taken from `documentFeature`, so the crop guide
  /// and the brush work on what the document holds; `documentFeature` itself
  /// when nothing is displayed in its place.
  static func drawnFeature(
    _ displayedFeature: ImageEditorFeature?,
    over documentFeature: ImageEditorFeature,
    editingTarget: Target?
  ) -> ImageEditorFeature {
    guard var feature = displayedFeature else {
      return documentFeature
    }
    switch editingTarget {
    case .crop:
      feature.crop = documentFeature.crop
    case .localBlur:
      feature.localBlur = documentFeature.localBlur
    case nil:
      break
    }
    return feature
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
    let feature = Self.drawnFeature(
      displayedFeature,
      over: document.wrappedValue.feature,
      editingTarget: editingTarget
    )
    return ZStack {
      switch previewSourceLoader.phase {
      case .loaded(let previewSource):
        #if os(iOS)
        EditingCanvasRepresentable(
          source: EditingCanvasSource(previewSource),
          feature: feature,
          adjustmentRendering: adjustmentRendering,
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
          feature: feature,
          adjustmentRendering: adjustmentRendering,
          areAnimationsEnabled: areAnimationsEnabled,
          fitMargin: fitMargin,
          canvasAccessibilityLabel: canvasAccessibilityLabel,
          editingTarget: editingTarget,
          onZoomChange: onZoomChange,
          onPointerChange: onPointerChange,
          pointSampling: pointSampling
        )
        // `EditingCanvasView` binds its source once, at creation, as on iOS.
        .id(previewSource.source)
        .transition(.opacity.animation(.smooth))
        #endif
      case .failed:
        // Nothing to edit; the host's own controls stay the way out.
        failureView
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

  /// The built-in editor's failure message, or the canvas's own.
  @ViewBuilder
  private var failureView: some View {
    if let failureMessage {
      ContentUnavailableView(failureMessage, systemImage: "exclamationmark.triangle")
    } else {
      ContentUnavailableView(
        "The image could not be loaded",
        systemImage: "exclamationmark.triangle"
      )
    }
  }

  /// Draws `feature` in place of the document's feature while non-nil: a
  /// value the host has not written yet, such as a slider in progress, or a
  /// feature it compares with, such as the original. nil draws the
  /// document's feature, as by default. The latest value is applied on every
  /// update.
  ///
  /// It changes only how the members the canvas does not edit are drawn:
  /// while the editing target is `.crop`, the canvas draws the document's
  /// crop in place of `feature`'s, and while it is `.localBlur`, the
  /// document's local blur, so the crop guide and the brush work on what the
  /// document holds. Canvas changes apply to the document, never to
  /// `feature`. Pass a feature of the document's source image.
  public consuming func displayedFeature(_ feature: ImageEditorFeature?) -> Self {
    self.displayedFeature = feature
    return self
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
  /// The canvas draws that part from the document, also while
  /// `displayedFeature(_:)` draws another feature.
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

  /// Reports the zoom after input, a command, a motion, a resize or new
  /// content. A report made outside a SwiftUI update arrives at once (a
  /// command that zooms at once, such as a zoom to a fraction, reports before
  /// it returns; an animated zoom reports from the frames of its motion); one
  /// made while SwiftUI updates or lays out the canvas arrives on the next
  /// main-actor turn, the latest only. Equal zooms are not reported again.
  /// The latest `action` is used; it is re-bound on every update.
  @available(iOS, unavailable, message: "The iOS canvas does not report its zoom yet.")
  public consuming func onZoomChange(_ action: @escaping @MainActor (Zoom) -> Void) -> Self {
    #if os(macOS)
    self.onZoomChange = action
    #endif
    return self
  }

  /// Reports the crop-output pixel under the pointer (full resolution,
  /// top-left origin, whole pixels), or nil off the image; also when zoom or
  /// pan moves the image under a resting pointer. Delivered like
  /// `onZoomChange(_:)`.
  @available(iOS, unavailable, message: "The iOS canvas does not report a pointer yet.")
  public consuming func onPointerChange(_ action: @escaping @MainActor (CGPoint?) -> Void) -> Self {
    #if os(macOS)
    self.onPointerChange = action
    #endif
    return self
  }

  /// While non-nil, a click on the image calls `action` with the crop-output
  /// point under it (full resolution, top-left origin) instead of panning,
  /// and the cursor over the canvas is a crosshair. A click off the image
  /// samples nothing. The latest value is applied on every update.
  @available(iOS, unavailable, message: "The iOS canvas does not sample points yet.")
  public consuming func pointSampling(_ action: (@MainActor (CGPoint) -> Void)?) -> Self {
    #if os(macOS)
    self.pointSampling = action
    #endif
    return self
  }

  /// Leaves `margin` points clear around the output at the fit, on every
  /// side. Zoomed in, the output still reaches the canvas's edges. The
  /// default is 0; the value is applied on every update.
  @available(iOS, unavailable, message: "The iOS canvas has no fit margin yet.")
  public consuming func fitMargin(_ margin: CGFloat) -> Self {
    #if os(macOS)
    self.fitMargin = margin
    #endif
    return self
  }

  /// Names the canvas for VoiceOver, which reads its zoom as its value. The
  /// canvas is unnamed by default; the value is applied on every update.
  ///
  /// SwiftUI's `accessibilityLabel(_:)` does not reach the AppKit view that
  /// VoiceOver reads for the canvas, so name the canvas with this instead.
  @available(iOS, unavailable, message: "Only the macOS canvas takes a label of its own.")
  public consuming func canvasAccessibilityLabel(_ label: String) -> Self {
    #if os(macOS)
    self.canvasAccessibilityLabel = label
    #endif
    return self
  }
}
