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
 - The view never registers anything with an `UndoManager`, and never
   changes the document's source image.
 - The editor's state follows the document's source image. To switch the editor
   to another document of the same image (a duplicate or a variant), give
   it a new identity with `.id`; the editor restarts its Cancel point
   itself when it sees a document it did not write, but its tool and crop
   guide state carry over otherwise.

 Render the document with `EditingDocument.render(options:)`.

 You might use `ImageEditorCanvas` to create a fully customized user interface.
 */
public struct ImageEditor: View {

  public struct LocalizedStrings {
    public var done: String = "Done"
    public var cancel: String = "Cancel"
    public var reset: String = "Reset"
    public var originalAspectRatio: String = "ORIGINAL"
    public var freeformAspectRatio: String = "FREEFORM"
    public var squareAspectRatio: String = "SQUARE"
    public var originalFilter: String = "ORIGINAL"

    public init() {}
  }

  public struct Options: Equatable {

    /// How the crop's aspect ratio is chosen.
    public enum AspectRatioPolicy: Equatable {
      /// The user picks a ratio in crop mode, starting from freeform.
      case selectable
      /// The crop is locked to `ratio`, and no picker is shown.
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
  ///     the document as it was when the editor opened (history included).
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
