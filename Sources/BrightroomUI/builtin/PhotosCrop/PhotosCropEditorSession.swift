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


import BrightroomEngine
import BrightroomParametric

/// The document logic of one PhotosCrop editing session, kept apart from the
/// views so it can be tested without a window.
///
/// A session starts when the editor shows a document's image and ends when
/// the editor goes away or the document's image changes. It decides what the
/// editor writes to the host's binding:
///
/// - A completed operation produces one write, with the change and the
///   optional commit folded into one value (`document(after:committing:change:)`).
/// - A slider drag is shown through `liveFeature` and written once when the
///   drag ends, so hosts that register an undo step per write (FileDocument,
///   `UndoManager` in `onChange`) get one step per drag, not one per tick.
/// - Cancel restores the document as it was when the session started,
///   history included (`documentForCancel(replacing:)`).
struct PhotosCropEditorSession {

  /// The document when the session started; Cancel restores it.
  let documentAtStart: EditingDocument<PhotosCropFeature>

  /// The feature a control shows while it is being dragged, not yet written
  /// to the document. nil when nothing is in progress.
  private(set) var liveFeature: PhotosCropFeature?

  init(documentAtStart: EditingDocument<PhotosCropFeature>) {
    self.documentAtStart = documentAtStart
  }

  /// The feature the canvas and the controls show.
  func displayedFeature(of document: EditingDocument<PhotosCropFeature>) -> PhotosCropFeature {
    liveFeature ?? document.feature
  }

  /// Shows an adjustment slider value without writing it.
  mutating func previewAdjustmentValue(
    _ sliderValue: Double,
    parameter: PhotosCropAdjustmentParameter,
    over document: EditingDocument<PhotosCropFeature>
  ) {
    var feature = displayedFeature(of: document)
    parameter.apply(sliderValue: sliderValue, to: &feature.effects)
    liveFeature = feature == document.feature ? nil : feature
  }

  /// Drops the value shown by a control in progress, for example because
  /// the document changed from outside (an undo) while dragging.
  mutating func discardLiveFeature() {
    liveFeature = nil
  }

  /// The document to write after a completed operation, or nil when it
  /// equals `document`: an equal write would still invalidate the host and,
  /// with FileDocument, register an empty undo step.
  ///
  /// The value shown by a control in progress is applied first, then
  /// `change`, then a commit when `committing` is true. The live value is
  /// consumed.
  mutating func document(
    after document: EditingDocument<PhotosCropFeature>,
    committing: Bool = false,
    change: (inout EditingDocument<PhotosCropFeature>) -> Void = { _ in }
  ) -> EditingDocument<PhotosCropFeature>? {
    var next = document
    if let liveFeature {
      next.feature = liveFeature
      self.liveFeature = nil
    }
    change(&next)
    if committing {
      next.commit()
    }
    return next == document ? nil : next
  }

  /// The document Cancel writes, or nil when `document` already equals the
  /// document at the start of the session.
  ///
  /// A document of another image is never replaced: the session belongs to
  /// the image it started with.
  func documentForCancel(
    replacing document: EditingDocument<PhotosCropFeature>
  ) -> EditingDocument<PhotosCropFeature>? {
    guard document.image == documentAtStart.image, document != documentAtStart else {
      return nil
    }
    return documentAtStart
  }
}
