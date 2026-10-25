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
 An image editor: crop and straighten, filters, adjustments, and a painted
 local blur.

 The view edits an `ImageEditorDocument` the host owns.

 - Each completed operation (a filter tap, a slider drag, a brush stroke, a
   crop applied) is written to the binding once; values in progress, such
   as a slider being dragged or a crop being adjusted, are not. Every write
   changes the feature, so a host that registers one undo step per write
   gets one step per visible change.
 - The work of one tool visit is one step of the document's history. The
   commit rides on the next visit's first write, so after Done the last
   visit's work may still be uncommitted (`hasUncommittedChanges`);
   `undo()` treats it as a step. Commit a copy before saving the history.
   Undo and redo are operations on the document value, so the host can
   drive them from its own buttons.
 - Reset, shown in every mode whenever anything differs from the initial
   values, restores every parameter at once: no filter, adjustments, or
   painted blur, and the crop the aspect-ratio policy starts with (the whole
   image, level and unturned, or under `.fixed`, the largest centered crop
   of the ratio, still locked). It is one write and a history step of its
   own (in Crop mode, a crop pending on the crop guide is applied first, as
   leaving Crop applies it), so `undo()` brings the edit back; the editor
   asks for no confirmation.
 - The view never registers anything with an `UndoManager`, and never
   changes the document's source image.
 - A crop is at least 128 pixels on its shorter output side (the image's
   shorter side, on a smaller image), so the blur tool keeps room to paint:
   crop zoom stops there (straightened or not), a guide drag stops there
   too (under a locked ratio, at the smallest crop of that ratio in whole
   multiples of its terms, such as 240 × 135 for 16:9), and `InitialCrop`
   enlarges a smaller crop it decides. Under a locked ratio whose
   multiples reaching that size do not fit the image, the crop is the
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
   its tool and crop guide state carry over, and Cancel still restores the
   document it opened with.

 Render the document with `EditingDocument.render(options:)`.

 You might use `ImageEditorCanvas` to create a fully customized user interface.
 */
public struct ImageEditor: View {

  public struct LocalizedStrings {
    public var done: String = "Done"
    public var cancel: String = "Cancel"
    /// The button that restores every parameter to its initial value, as
    /// one undoable step and without a confirmation.
    public var reset: String = "Reset"
    public var originalAspectRatio: String = "ORIGINAL"
    public var freeformAspectRatio: String = "FREEFORM"
    public var squareAspectRatio: String = "SQUARE"
    public var originalFilter: String = "ORIGINAL"

    public init() {}
  }

  public struct Options: Equatable {

    /// How the crop's aspect ratio is chosen.
    ///
    /// While a ratio is locked, a crop the user frames has exactly that
    /// ratio in whole pixels when the ratio's lowest terms are both at most
    /// 32 (see `ImageEditorCanvas.CropGuide.pendingCrop`).
    public enum AspectRatioPolicy: Equatable {
      /// The user picks a ratio in crop mode, starting from freeform.
      case selectable
      /// The crop starts locked to `ratio`, and no picker is shown. Reset
      /// returns the crop to the largest centered crop of `ratio` (as
      /// `InitialCrop.aspectRatio(_:)` decides it) and keeps the lock.
      case fixed(AspectRatio)
      /// The crop is freeform, and no picker is shown.
      case freeform
    }

    public var aspectRatioPolicy: AspectRatioPolicy = .selectable

    /// The host-provided presets offered by the Filters mode.
    ///
    /// Defaults to an empty array; only Original is offered until presets are
    /// supplied. A selected preset is written to the feature's
    /// `effects.preset`.
    public var filters: [FilterFeature] = []

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
  ///   - localizedStrings: The button titles.
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
