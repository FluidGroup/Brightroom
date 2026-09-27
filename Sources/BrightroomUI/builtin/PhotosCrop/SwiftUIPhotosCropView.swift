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
 Apple's Photos app like crop view.

 The view edits an `EditingDocument<PhotosCropFeature>` the host owns.

 - Each completed operation (a filter tap, a slider drag, a brush stroke, a
   crop applied) is written to the binding once; values in progress, such
   as a slider being dragged or a crop being adjusted, are not.
 - The view commits to the document's history when the user leaves a tool
   and on Done. Undo and redo are operations on the document value, so the
   host can drive them from its own buttons.
 - The view never registers anything with an `UndoManager`, and never
   changes the document's image.

 Render the document with `EditingDocument.render(options:)`.

 You might use `SwiftUICropView` to create a fully customized user interface.
 */
@available(iOS 14, *)
public struct SwiftUIPhotosCropView: View {

  public struct LocalizedStrings {
    public var button_done_title: String = "Done"
    public var button_cancel_title: String = "Cancel"
    public var button_reset_title: String = "Reset"
    public var button_aspectratio_original: String = "ORIGINAL"
    public var button_aspectratio_freeform: String = "FREEFORM"
    public var button_aspectratio_square: String = "SQUARE"
    public var button_filter_original: String = "ORIGINAL"

    public init() {}
  }

  public struct Options: Equatable {

    public enum AspectRatioOptions: Equatable {
      case selectable
      case fixed(PixelAspectRatio?)
    }

    public var aspectRatioOptions: AspectRatioOptions = .selectable

    /// The host-provided presets offered by the Filters mode.
    ///
    /// Defaults to an empty array; only Original is offered until presets are
    /// supplied. A selected preset is written to the feature's
    /// `effects.preset`.
    public var filterPresets: [PresetFeature] = []

    public init() {

    }
  }

  @Binding private var document: EditingDocument<PhotosCropFeature>
  private let options: Options
  private let localizedStrings: LocalizedStrings
  private let onDone: @MainActor () -> Void
  private let onCancel: (@MainActor () -> Void)?

  /// Creates the editor.
  ///
  /// - Parameters:
  ///   - document: The edited document. Create it before showing the editor,
  ///     with `EditingDocument(image:)` or, for a policy-decided initial crop,
  ///     `EditingDocument(image:cropModifier:)`. A document of another image
  ///     restarts the editor.
  ///   - options: The editor options.
  ///   - localizedStrings: The button titles.
  ///   - onDone: Called after the binding received the committed document.
  ///   - onCancel: Called when the user cancels, after the binding received
  ///     the document as it was when the editor opened (history included).
  ///     nil hides the Cancel button, for example in a document window where
  ///     every change is kept.
  public init(
    document: Binding<EditingDocument<PhotosCropFeature>>,
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
    // One stack per image, shared by the canvas and the filter swatches.
    OwnedEditingStack(image: document.image) { editingStack in
      PhotosCropContentView(
        document: $document,
        editingStack: editingStack,
        options: options,
        localizedStrings: localizedStrings,
        onDone: onDone,
        onCancel: onCancel
      )
    }
    .id(document.image)
  }
}

#Preview {
  Text("h")
}
