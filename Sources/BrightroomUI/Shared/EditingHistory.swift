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


/// A value-type undo/redo journal for document snapshots.
///
/// The owner of a document keeps this next to it. The editing UI decides when
/// the current document becomes a checkpoint (commit style): changes update
/// `current` only, and `commitCurrentIfNeeded()` records it.
struct EditingHistory<State: Equatable>: Equatable {

  /// The document the history started from.
  let initial: State

  /// The document currently being previewed and rendered.
  var current: State

  /// Committed undo checkpoints.
  private var checkpoints: [State]

  /// Checkpoints undone from `checkpoints`, available until the next commit.
  private var redoStack: [State]

  /// Creates an empty history whose current document is `initial`.
  init(initial: State) {
    self.initial = initial
    self.current = initial
    self.checkpoints = []
    self.redoStack = []
  }

  /// The current revision index, matching the number of committed checkpoints.
  var revision: Int {
    checkpoints.count
  }

  /// Whether undo can move the current document to another state.
  var canUndo: Bool {
    if checkpoints.last == current {
      return checkpoints.count > 1 || current != initial
    }
    return checkpoints.isEmpty == false || current != initial
  }

  /// Whether redo can move the current document to another state.
  var canRedo: Bool {
    redoStack.isEmpty == false
  }

  /// Whether the current document differs from the initial one.
  var isDirty: Bool {
    current != initial
  }

  /// Whether the current document differs from the latest committed checkpoint.
  var hasUncommittedChanges: Bool {
    guard let latestCheckpoint = checkpoints.last else {
      return current != initial
    }
    return latestCheckpoint != current
  }

  /// Commits the current document when it differs from the latest checkpoint.
  mutating func commitCurrentIfNeeded() {
    guard hasUncommittedChanges else {
      return
    }
    commitCurrent()
  }

  /// Commits the current document as a checkpoint and clears redo.
  mutating func commitCurrent() {
    checkpoints.append(current)
    redoStack = []
  }

  /// Discards the changes since the latest checkpoint: the current document
  /// returns to it, or to the initial one when there is none.
  mutating func discardUncommittedChanges() {
    current = checkpoints.last ?? initial
  }

  /// Moves the current document to the previous checkpoint.
  mutating func undo() {
    // Commit-style checkpoints may leave `checkpoints.last == current`.
    // Drop that duplicate first so one undo action changes visible state.
    if checkpoints.last == current {
      checkpoints.removeLast()
    }
    if let previous = checkpoints.popLast() {
      redoStack.append(current)
      current = previous
    } else if current != initial {
      redoStack.append(current)
      current = initial
    }
  }

  /// Reapplies the most recently undone checkpoint.
  mutating func redo() {
    guard let next = redoStack.popLast() else {
      return
    }
    checkpoints.append(current)
    current = next
  }
}

extension EditingHistory: Sendable where State: Sendable {}
