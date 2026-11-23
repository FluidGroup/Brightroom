//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

/**
 An image editor: on iOS, crop and straighten, filters, adjustments and a
 painted local blur; on macOS, filters, adjustments, a histogram and a
 before/after comparison.

 The view edits an `ImageEditorDocument` the host owns.

 - Each completed operation (a filter tap, a slider drag, a brush stroke, a
   crop applied, a section switched off or on) is written to the binding
   once; values in progress, such as a slider being dragged or a crop being
   adjusted, are not. Every write changes the feature, so a host that
   registers one undo step per write gets one step per visible change.
 - On iOS the work of one tool visit is one step of the document's history;
   on macOS, where the adjustments stay beside the image, each completed
   operation is a step of its own, so the history reaches its `limit`
   sooner. The commit rides on the next write, so after Done the last step
   may still be uncommitted (`hasUncommittedChanges`); `undo()` treats it
   as a step. Commit a copy before saving the history. Undo and redo are
   operations on the document value, so the host can drive them from its
   own buttons.
 - Reset (iOS) and Revert to Original (macOS) restore every parameter at
   once: no filter, adjustments, or painted blur, and the crop the
   aspect-ratio policy starts with (the whole image, level and unturned, or
   under `.fixed`, the largest centered crop of the ratio, still locked; on
   macOS, see "Not yet" below). Reset shows in every mode, and Revert to
   Original is enabled, whenever anything differs from the initial values.
   Either is one write and a history step of its own (in Crop mode on iOS,
   a crop pending on the crop guide is applied first, as leaving Crop
   applies it), so `undo()` brings the edit back; the editor asks for no
   confirmation. Effects the host put in `effects.custom` are kept: the
   editor never edits them, so they alone are nothing to reset.
 - The editor's controls edit the feature's filter, adjustments, blur, crop,
   and vignette, never `effects.custom`: selecting a filter leaves it, and
   the filter swatches preview the presets without it.
 - The view never registers anything with an `UndoManager`, and never
   changes the document's source image.
 - On iOS, a crop is at least 128 pixels on its shorter output side (the
   image's shorter side, on a smaller image), so the blur tool keeps room
   to paint: crop zoom stops there (straightened or not), a guide drag
   stops there too (under a locked ratio, at the smallest crop of that
   ratio in whole multiples of its terms, such as 240 × 135 for 16:9), and
   `InitialCrop` enlarges a smaller crop it decides. Under a locked ratio
   whose multiples reaching that size do not fit the image, the crop is the
   largest multiple that does, a few pixels shorter (224 × 126 for 16:9 of
   a 130-pixel-high image). A smaller crop the
   host puts in the document is shown exactly as it is and is not
   rewritten when it loads; the first crop gesture (a pan, a zoom, a guide
   drag, or straightening) records it grown about its center to the
   minimum, keeping a locked ratio. `CropFeature` itself accepts any size.
 - Cancel writes back the document the editor opened with, history
   included, and discards everything written since, the host's own writes
   to the binding (an undo, a redo, a change of its own) included.
 - The editor's state follows the document's source image: a document of
   another image restarts it, Cancel point included. To switch the editor
   to another document of the same image (a duplicate or a variant) with a
   Cancel point of its own, give it a new identity with `.id`; otherwise
   its tool and crop guide state, and on macOS its section switches (a
   section switched off keeps the values it had, shown dimmed, until it is
   switched on or edited), carry over, and Cancel still restores the
   document it opened with.

 Render the document with `EditingDocument.render(options:)`.

 You might use `ImageEditorCanvas` to create a fully customized user interface.

 On macOS the editor shows the image with a filter strip under it, a
 histogram over it, and its adjustments in an inspector beside it.

 - **Toolbar.** It adds its controls to the window's toolbar. Leading:
   Cancel (when `onCancel` is not nil, a back chevron that replaces a
   navigation stack's back button; it has no key), Show Original, Revert to
   Original, and zoom. Then the window's title and subtitle, which the host
   sets with `navigationTitle(_:)` and `navigationSubtitle(_:)`. Trailing:
   Adjust, More and Done.
 - **Hosting.** Show it as a window's content, a `NavigationStack`
   destination or a split view's detail. In a stack or a detail the toolbar
   spans the window and the inspector sits under it. As a window's root
   view the inspector is full height, with its own part of the toolbar.
   Sheets are not supported: a sheet has no window toolbar, so most of the
   editor's controls would not show. To edit in a window of its own, open
   one (`openWindow`) with the editor as its content. To put the editor's
   commands in the menu bar, add `ImageEditorCommands`, with the editor's
   `localizedStrings`, and `InspectorCommands` to the scene's commands; the
   editor's keys work without them.
 - **Keys.** Return is Done. Command-plus (or Command-equals),
   Command-minus and Command-0 zoom. Control-Command-I shows or hides the
   adjustments, also after the inspector was collapsed by dragging. While
   the window is key, these take precedence over the host's menu
   equivalents. Zoomed in, the image takes the keyboard from a click (with
   Full Keyboard Access, from Tab too), and the arrow keys pan it by a
   tenth of its size, or nine tenths with Option; with Full Keyboard
   Access on, it shows the focus ring while it has the keyboard. Escape
   ends the gray point while it is on, and reaches the host otherwise.
   Holding M shows the original, unless text is being edited: once the
   image has loaded, the editor takes plain M while its window is key, so
   a host's own unmodified M shortcut in that window does not run.
 - **Operations.** These are each one write: a drag or a click that moves
   a slider or a color grading wheel, a key press or held key on a focused
   slider or wheel (a wheel takes the keyboard with Full Keyboard Access),
   and each VoiceOver step. Double-clicking a slider's knob or a wheel
   resets it in one write; on a slider's track, the click is written first.
 - **Undo.** Edit > Undo is the host's. A FileDocument host gets a step per
   write. A host that keeps the document in its own state registers each
   write with the environment's `undoManager` in its binding (see
   ParametricMacDemo).
 - **Revert and Reset.** Revert to Original does what Reset does on iOS.
   Reset, under the adjustments, returns the adjustments the inspector
   shows to neutral. It keeps the filter, the crop, the painted blur,
   `sharpen`, `unsharpMask`, `fade` and `effects.custom`: one write, a step
   of its own.
 - **Section switches.** A section's switch removes its adjustments, and
   puts them back, in one write each. The editor keeps a switched-off
   section's values only while it is open, and until the document shows
   them again.
 - **Show Original and the histogram.** Show Original shows what Revert to
   Original restores, in the current crop, and writes nothing; editing ends
   it. The histogram and the R, G, B readouts describe what the canvas
   shows, as 8-bit Display P3 values. They are measured on a copy whose
   long side is about 1024 pixels, and never finer than the preview the
   canvas shows.
 - **Not yet.** It does not crop or paint yet. It shows the document's crop
   and painted blur as they are; More > Remove Painted Blur removes the
   blur. Revert to Original keeps a crop that is the whole image or the one
   the aspect-ratio policy starts with, and returns any other crop to the
   policy's.
 - **Appearance.** It draws the image on a dark surround and leaves the
   window's appearance to the host.
 */
public struct ImageEditor: View {

  public struct LocalizedStrings {
    public var done: String = "Done"
    /// The Cancel button; on macOS, the label and tooltip of the toolbar's
    /// back chevron.
    public var cancel: String = "Cancel"
    /// iOS: the button that restores every parameter to its initial value,
    /// as one undoable step and without a confirmation.
    public var reset: String = "Reset"
    public var originalAspectRatio: String = "ORIGINAL"
    public var freeformAspectRatio: String = "FREEFORM"
    public var squareAspectRatio: String = "SQUARE"
    /// iOS: the Original chip's caption.
    public var originalFilter: String = "ORIGINAL"

    // The macOS toolbar. A tooltip that names a shortcut appends it to the
    // label, as in "Show Original (hold M)" and "Zoom In (⌘+)".
    public var revertToOriginal: String = "Revert to Original"
    public var showOriginal: String = "Show Original"
    public var adjust: String = "Adjust"
    public var zoom: String = "Zoom"
    public var zoomIn: String = "Zoom In"
    public var zoomOut: String = "Zoom Out"
    public var more: String = "More"

    // The macOS More menu.
    public var showHistogram: String = "Show Histogram"
    public var showFilters: String = "Show Filters"
    public var removeFilter: String = "Remove Filter"
    public var removePaintedBlur: String = "Remove Painted Blur"

    // The macOS menu bar (`ImageEditorCommands`). Its other items take the
    // titles of the toolbar's and the More menu's controls.
    /// The menu of Revert to Original, Reset Adjustments, Remove Filter and
    /// Remove Painted Blur.
    public var imageMenu: String = "Image"
    /// The View menu's item that zooms the image to fit the canvas.
    public var zoomToFit: String = "Zoom to Fit"
    /// The Image menu's item that returns the adjustments to neutral, as the
    /// inspector's Reset (`resetAdjustments`) does.
    public var resetAdjustmentsMenuItem: String = "Reset Adjustments"

    // The macOS inspector.
    /// The inspector's resets: the footer button (every section), a card's
    /// context menu and the Color Grading card's reset button (that
    /// section), a grading wheel's context menu (that wheel's range), and
    /// the header of the footer menu's list of sections.
    public var resetAdjustments: String = "Reset"
    /// The tooltip and VoiceOver label of the menu beside the footer's Reset
    /// button, which resets one section.
    public var resetSection: String = "Reset Section"
    /// A card header's VoiceOver value while the card is expanded.
    public var expanded: String = "expanded"
    /// A card header's VoiceOver value while the card is collapsed.
    public var collapsed: String = "collapsed"
    /// The Color Grading card's layout with a wheel for each of shadows,
    /// midtones and highlights.
    public var colorGradingThreeWay: String = "3-Way"
    /// The Color Grading card's layout with one wheel for the whole image.
    public var colorGradingGlobal: String = "Global"

    // The macOS image column.
    /// The image's VoiceOver label; VoiceOver reads its zoom, such as "36%",
    /// as its value.
    public var photo: String = "Photo"
    /// The histogram's VoiceOver label.
    public var histogram: String = "Histogram"
    /// The histogram's VoiceOver value: %1$@ and %2$@ are the shadow and
    /// highlight clipping, as percentages.
    public var histogramClipping: String = "Shadows clipped %1$@, highlights clipped %2$@"
    /// The readout under the histogram: %1$@, %2$@ and %3$@ are the red,
    /// green and blue values (0–255), or "---".
    public var pointerColor: String = "R: %1$@   G: %2$@   B: %3$@"
    /// The filter strip's VoiceOver label.
    public var filters: String = "Filters"
    /// The macOS filter strip's first tile, which removes the filter: its
    /// tooltip and VoiceOver label. iOS shows `originalFilter`.
    public var noFilter: String = "Original"
    /// The badge while Show Original is on, and its announcement.
    public var showingOriginal: String = "Original"
    /// Shown by both editors' canvas when the image's pixels cannot be
    /// decoded.
    public var imageLoadFailed: String = "The image could not be loaded"

    // The macOS gray point, which sets the white balance from a click on the
    // image.
    /// The badge while the gray point waits for a click, its announcement,
    /// and the tooltip of White Balance's eyedropper.
    public var grayPointHint: String = "Click a neutral gray area in the photo"
    /// The badge for a moment after a click the gray point cannot use (too
    /// dark, clipped, or off the image), and its announcement.
    public var grayPointRejected: String = "Choose a gray area that is neither black nor white"

    public init() {}
  }

  public struct Options: Equatable {

    /// How the crop's aspect ratio is chosen.
    ///
    /// While a ratio is locked, a crop the user frames has exactly that
    /// ratio in whole pixels when the ratio's lowest terms are both at most
    /// 32 (see `ImageEditorCanvas.CropGuide.pendingCrop`).
    ///
    /// The macOS editor does not crop yet (see `ImageEditor`, "Not yet"): it
    /// locks no ratio and shows the document's crop as it is. There the
    /// policy decides only the crop Revert to Original returns a changed crop
    /// to; a crop of the whole image, or the policy's own crop, is kept.
    public enum AspectRatioPolicy: Equatable {
      /// On iOS, the user picks a ratio in crop mode, starting from freeform.
      case selectable
      /// On iOS, the crop starts locked to `ratio`, and no picker is shown;
      /// Reset returns the crop to the largest centered crop of `ratio` (as
      /// `InitialCrop.aspectRatio(_:)` decides it) and keeps the lock. On
      /// macOS, Revert to Original returns a crop that is neither the whole
      /// image nor that crop to it.
      case fixed(AspectRatio)
      /// On iOS, the crop is freeform, and no picker is shown.
      case freeform
    }

    public var aspectRatioPolicy: AspectRatioPolicy = .selectable

    /// The presets offered without a group: iOS's Filters mode lists them,
    /// then the presets of `filterGroups`; macOS's filter strip shows them
    /// first, without a group tile. Preset ids must be unique across
    /// `filters` and every group: a selection is matched by id.
    ///
    /// A selected preset is written to the feature's `effects.preset`; the
    /// host's `effects.custom` is left as it is.
    public var filters: [FilterFeature] = []

    /// Presets in titled groups. macOS's strip starts each group with a tile
    /// in its color; iOS's Filters mode lists their presets after `filters`.
    /// A group without presets is not shown.
    public var filterGroups: [FilterGroup] = []

    public init() {

    }
  }

  @Binding private var document: ImageEditorDocument
  private let options: Options
  private let localizedStrings: LocalizedStrings
  private let onDone: @MainActor () -> Void
  private let onCancel: (@MainActor () -> Void)?

  /// Creates the editor.
  ///
  /// - Parameters:
  ///   - document: The edited document. Create it before showing the editor,
  ///     with `ImageEditorDocument(source:)` or, for a policy-decided initial
  ///     crop, `ImageEditorDocument(source:initialCrop:)`. A document of
  ///     another source image restarts the editor.
  ///   - options: The editor options.
  ///   - localizedStrings: Most of the editor's text: titles, labels,
  ///     tooltips and what VoiceOver reads. Not in it, and English on both
  ///     platforms: the names of adjustments, sections, rows, tonal ranges
  ///     and axes (and VoiceOver labels made from them), the shortcut a macOS
  ///     tooltip appends, and some of iOS's buttons (such as Reset grading)
  ///     and VoiceOver labels, values and hints (such as "selected").
  ///   - onDone: Called after the binding received the last change.
  ///   - onCancel: Called when the user cancels, after the binding received
  ///     the document as it was when the editor opened (history included),
  ///     whatever the host wrote to the binding meanwhile.
  ///     nil hides the Cancel button, for example in a document window where
  ///     every change is kept. That restoring write is a write like any
  ///     other: a host that registers an undo step per write (FileDocument,
  ///     `UndoManager`) would let the user undo the Cancel. Such a host
  ///     either hides Cancel, or binds the editor to a copy and assigns the
  ///     copy to its document on Done.
  public init(
    document: Binding<ImageEditorDocument>,
    options: Options = .init(),
    localizedStrings: LocalizedStrings = .init(),
    onDone: @escaping @MainActor () -> Void,
    onCancel: (@MainActor () -> Void)? = nil
  ) {
    self._document = document
    self.options = options
    self.localizedStrings = localizedStrings
    self.onDone = onDone
    self.onCancel = onCancel
  }

  public var body: some View {
    // One loader per source image, shared by the canvas and the filter swatches.
    PreviewSourceReader(source: document.source) { previewSourceLoader in
      ImageEditorContent(
        document: $document,
        previewSourceLoader: previewSourceLoader,
        options: options,
        localizedStrings: localizedStrings,
        onDone: onDone,
        onCancel: onCancel
      )
    }
    .id(document.source)
  }
}
