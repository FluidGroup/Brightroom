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

import CoreImage
import QuartzCore

import BrightroomParametric

/// An edit of one image: the image, the feature authored over it, and the
/// undo history of that feature.
///
/// The image is fixed for the document's lifetime, so an edit never travels
/// without the image its coordinates belong to. `feature` is authored in the
/// image's oriented pixel coordinates (`image.pixelSize`).
///
/// History is commit style. Changing `feature` records nothing; `commit()`
/// records the current feature as an undo step when it changed. The editing
/// UI decides when to commit, for example when leaving a tool.
///
/// Documents are values: copies are independent, and two documents are equal
/// when they have the same image (the same load), feature, and history.
public struct EditingDocument<Content: Feature & Equatable>: Equatable, Sendable {

  /// The image `feature` is authored over.
  public let image: SourceImage

  /// The current feature: what renders and what editors show.
  public var feature: Content

  /// The committed undo and redo steps.
  ///
  /// Replace it to restore a saved history, or remove its steps to drop it.
  /// The document itself does not depend on it: a document with an empty
  /// history renders the same.
  public var history: History

  /// The feature as of the latest commit.
  private var committedFeature: Content

  /// Creates a document with `feature` as its committed state.
  ///
  /// - Parameters:
  ///   - image: The image `feature` is authored over.
  ///   - feature: The feature, in `image`'s oriented pixel coordinates.
  ///   - history: The undo and redo steps, for example restored by the host.
  ///     Empty by default.
  public init(image: SourceImage, feature: Content, history: History = History()) {
    self.image = image
    self.feature = feature
    self.history = history
    self.committedFeature = feature
  }

  /// Whether `feature` changed since the latest commit.
  public var hasUncommittedChanges: Bool {
    feature != committedFeature
  }

  /// Whether `undo()` changes the feature.
  public var canUndo: Bool {
    hasUncommittedChanges || history.undoStack.isEmpty == false
  }

  /// Whether `redo()` changes the feature.
  ///
  /// Uncommitted changes start a new branch, so redo is unavailable until
  /// they are committed away or discarded.
  public var canRedo: Bool {
    hasUncommittedChanges == false && history.redoStack.isEmpty == false
  }

  /// Records the current feature as an undo step when it changed since the
  /// latest commit, and clears the redo steps.
  public mutating func commit() {
    guard hasUncommittedChanges else {
      return
    }
    history.push(committedFeature)
    committedFeature = feature
  }

  /// Returns to the previous committed feature.
  ///
  /// Uncommitted changes are committed first, so `redo()` brings them back.
  public mutating func undo() {
    commit()
    guard let previous = history.undoStack.popLast() else {
      return
    }
    history.redoStack.append(committedFeature)
    committedFeature = previous
    feature = previous
  }

  /// Reapplies the most recently undone feature.
  public mutating func redo() {
    guard canRedo, let next = history.redoStack.popLast() else {
      return
    }
    history.undoStack.append(committedFeature)
    history.trimToLimit()
    committedFeature = next
    feature = next
  }

  /// Returns `feature` to the latest commit.
  public mutating func discardUncommittedChanges() {
    feature = committedFeature
  }
}

extension EditingDocument {

  /// The committed steps of a document's feature.
  public struct History: Equatable, Sendable {

    /// The maximum number of undo steps kept; nil keeps every step.
    ///
    /// Lowering it drops the oldest steps.
    public var limit: Int? {
      didSet {
        trimToLimit()
      }
    }

    /// Committed features before the latest commit, oldest first.
    public internal(set) var undoStack: [Content]

    /// Undone features, the next redo last.
    public internal(set) var redoStack: [Content]

    /// Creates an empty history.
    ///
    /// - Parameter limit: The maximum number of undo steps kept; nil keeps
    ///   every step. Must not be negative.
    public init(limit: Int? = 100) {
      self.init(undoStack: [], redoStack: [], limit: limit)
    }

    /// Restores a saved history.
    ///
    /// - Parameters:
    ///   - undoStack: Committed features before the document's feature,
    ///     oldest first. Steps beyond `limit` are dropped from the start.
    ///   - redoStack: Undone features, the next redo last.
    ///   - limit: The maximum number of undo steps kept; nil keeps every
    ///     step. Must not be negative.
    public init(undoStack: [Content], redoStack: [Content], limit: Int? = 100) {
      precondition(limit.map { $0 >= 0 } ?? true, "A history limit must not be negative.")
      self.undoStack = undoStack
      self.redoStack = redoStack
      self.limit = limit
      trimToLimit()
    }

    /// Removes every undo and redo step. The limit is kept.
    public mutating func removeAll() {
      undoStack.removeAll()
      redoStack.removeAll()
    }

    mutating func push(_ committed: Content) {
      undoStack.append(committed)
      redoStack.removeAll()
      trimToLimit()
    }

    mutating func trimToLimit() {
      guard let limit, undoStack.count > limit else {
        return
      }
      undoStack.removeFirst(undoStack.count - limit)
    }
  }
}

// MARK: - Rendering

extension EditingDocument {

  /// Renders the feature over the full-resolution image.
  ///
  /// The Core Image work runs off the calling actor. See
  /// `ParametricExportRenderer.render(source:feature:options:device:)` for the
  /// output options.
  @concurrent
  public func render(
    options: ParametricExportRenderer.Options = .init()
  ) async throws -> ParametricExportRenderer.Rendered {
    try render(options: options, device: .automatic)
  }

  /// The synchronous render core, internal so tests can compare devices and
  /// benchmarks can skip the executor hop.
  func render(
    options: ParametricExportRenderer.Options,
    device: ParametricExportRenderer.RenderingDevice
  ) throws -> ParametricExportRenderer.Rendered {
    let startTime = CACurrentMediaTime()
    let rendered = try ParametricExportRenderer().render(
      source: image.makeCIImage(),
      feature: feature,
      options: options,
      device: device
    )
    EngineLog.debug(.renderer, "Rendering has completed - took \((CACurrentMediaTime() - startTime) * 1000)ms")
    return rendered
  }
}
