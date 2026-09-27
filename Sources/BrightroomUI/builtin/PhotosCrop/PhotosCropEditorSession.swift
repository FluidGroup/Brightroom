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
/// It decides what the editor writes to the host's binding:
///
/// - Every write changes the feature. A completed operation produces one
///   write, and a write that would only change the history is never made,
///   so hosts that register an undo step per write (FileDocument,
///   `UndoManager` in `onChange`) get one step per visible change.
/// - The work of one tool visit is one history step, committed lazily: the
///   first write of a tool visit commits the document before applying its
///   change. Leaving a tool or tapping Done writes nothing by itself, so the
///   last visit's work stays uncommitted until the next edit. `undo()`
///   treats uncommitted changes as a step, so the steps are the same.
/// - A slider drag is shown through `liveFeature` and written once when the
///   drag ends.
/// - Cancel restores the document as it was when the session started,
///   history included (`documentForCancel(replacing:)`).
///
/// A session starts with the document the editor opens with. It restarts
/// when the binding shows a document the session neither started with nor
/// wrote (`noteDocument(_:)`), such as another document of the same image:
/// Cancel then restores that document, never the previous one. An undo by
/// the host's `UndoManager` brings back a value the session knows, so it
/// keeps the session.
struct PhotosCropEditorSession {

  /// The document when the session started; Cancel restores it.
  private(set) var documentAtStart: EditingDocument<PhotosCropFeature>

  /// The feature a control shows while it is being dragged, not yet written
  /// to the document. nil when nothing is in progress.
  private(set) var liveFeature: PhotosCropFeature?

  /// Every document this session wrote, oldest first.
  private var writes: [EditingDocument<PhotosCropFeature>] = []

  /// The index in `writes` of the current tool visit's first write.
  private var toolVisitStart = 0

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

  /// The document to write after a completed operation, or nil when the
  /// operation leaves the feature unchanged: an equal write would still
  /// invalidate the host, and a write that changes only the history would
  /// register an undo step that changes nothing visible.
  ///
  /// The value shown by a control in progress is applied, then `change`,
  /// which changes the feature only. The live value is consumed.
  mutating func document(
    after document: EditingDocument<PhotosCropFeature>,
    change: (inout EditingDocument<PhotosCropFeature>) -> Void = { _ in }
  ) -> EditingDocument<PhotosCropFeature>? {
    let liveFeature = self.liveFeature
    self.liveFeature = nil
    return write(over: document) { next in
      if let liveFeature {
        next.feature = liveFeature
      }
      change(&next)
    }
  }

  /// The document to write for a change the canvas made, or nil when the
  /// feature is unchanged.
  ///
  /// - Parameter changed: The binding's document with the canvas change
  ///   applied; only its feature is taken. A value in progress on a control
  ///   is kept for the control.
  mutating func document(
    afterCanvasChange changed: EditingDocument<PhotosCropFeature>,
    over document: EditingDocument<PhotosCropFeature>
  ) -> EditingDocument<PhotosCropFeature>? {
    write(over: document) { $0.feature = changed.feature }
  }

  /// Ends the current tool visit: the next write starts a new history step.
  ///
  /// Returns the document to write when a control still shows a value in
  /// progress, which is part of the visit that ends.
  mutating func endToolVisit(
    of document: EditingDocument<PhotosCropFeature>
  ) -> EditingDocument<PhotosCropFeature>? {
    let written = self.document(after: document)
    toolVisitStart = writes.count
    return written
  }

  /// Keeps the session for a document it knows, and restarts it for any
  /// other, which the editor now edits from its current state.
  ///
  /// Call it whenever the binding's document changes.
  mutating func noteDocument(_ document: EditingDocument<PhotosCropFeature>) {
    guard document != documentAtStart, writes.contains(document) == false else {
      return
    }
    self = PhotosCropEditorSession(documentAtStart: document)
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

  /// Applies `change` over `document`, committing first when `document` is
  /// not one the current tool visit wrote: then its uncommitted changes, if
  /// any, belong to an earlier visit (or to the host) and become their own
  /// step. After an undo by the host back into the visit, the visit goes on
  /// without a commit.
  private mutating func write(
    over document: EditingDocument<PhotosCropFeature>,
    change: (inout EditingDocument<PhotosCropFeature>) -> Void
  ) -> EditingDocument<PhotosCropFeature>? {
    // A rebinding can reach a write before `onChange` reports it.
    noteDocument(document)
    var next = document
    if writes[toolVisitStart...].contains(document) == false {
      next.commit()
    }
    change(&next)
    guard next.feature != document.feature else {
      return nil
    }
    writes.append(next)
    return next
  }
}
