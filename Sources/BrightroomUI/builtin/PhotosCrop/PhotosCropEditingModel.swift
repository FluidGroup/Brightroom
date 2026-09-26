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


import Combine
import CoreGraphics
import CoreImage
import StateGraph

import BrightroomEngine
import BrightroomParametric

/// The document and undo history of a PhotosCrop editing session.
///
/// `EditingStack` loads the image; this model owns what is edited over it: a
/// `PhotosCropDocument` and its history. Once the image has loaded, the model
/// installs the initial document (a new one adjusted by a `CropModifier`, or
/// the document the host resumes), and PhotosCrop views change it through the
/// model's operations.
///
/// History is commit style: changes update `document` only, and the editor
/// decides when the current document becomes an undo checkpoint (when leaving
/// a tool, and on Done).
///
/// After editing, read `document` and render it with
/// `editingStack.makeRenderer(document:)`.
@MainActor
public final class PhotosCropEditingModel {

  /// Where the initial document comes from.
  private enum InitialDocument {
    /// A new document whose crop the modifier adjusts.
    case new(CropModifier)
    /// A document the host resumes.
    case resume(PhotosCropDocument)
  }

  /// The stack that loads the image the document is authored over.
  public let editingStack: EditingStack

  /// The document history; nil until the initial document is installed.
  @GraphStored private var history: EditingHistory<PhotosCropDocument>? = nil

  /// What installs the initial document; nil once the history exists.
  private var pendingInitialDocument: InitialDocument?

  /// The crop modifier run that prepares a new document, while in flight.
  private var initialDocumentTask: Task<Void, Never>?

  /// Observes the stack's load until the initial document is installed.
  private var loadedStateSubscription: AnyCancellable?

  /// Creates a model that starts a new document over `editingStack`.
  ///
  /// The model holds the edit and its history, so keep it for as long as the
  /// editing session lasts (for example in `@State`); a recreated model starts
  /// from a new document.
  ///
  /// - Parameters:
  ///   - editingStack: Loads the image; kept for the model's lifetime.
  ///   - cropModifier: The initial-crop policy for the new document. The
  ///     document stays nil while it runs.
  public convenience init(
    editingStack: EditingStack,
    cropModifier: CropModifier = .identity
  ) {
    self.init(editingStack: editingStack, initialDocument: .new(cropModifier))
  }

  /// Creates a model that resumes `document` over `editingStack`.
  ///
  /// - Parameters:
  ///   - editingStack: Loads the image; kept for the model's lifetime.
  ///   - document: The document to resume, the initial document of the
  ///     history. It must be authored for this image (its domain is
  ///     `editingStack.loadedState.imageSize`).
  public convenience init(
    editingStack: EditingStack,
    resuming document: PhotosCropDocument
  ) {
    self.init(editingStack: editingStack, initialDocument: .resume(document))
  }

  private init(editingStack: EditingStack, initialDocument: InitialDocument) {
    self.editingStack = editingStack
    self.pendingInitialDocument = initialDocument

    prepareInitialDocumentIfNeeded()

    guard history == nil else {
      return
    }

    // Prepare the document whoever starts the stack. The stack publishes
    // `loadedState` on its own queue, so the handler only schedules the work
    // on the main actor and reads the state again there.
    loadedStateSubscription = withGraphTracking {
      withGraphTrackingMap(
        from: editingStack,
        map: { @Sendable stack in stack.loadedState != nil },
        onChange: { @Sendable [weak self] isLoaded in
          guard isLoaded else {
            return
          }
          Task { @MainActor [weak self] in
            self?.prepareInitialDocumentIfNeeded()
          }
        }
      )
    }
  }

  isolated deinit {
    initialDocumentTask?.cancel()
  }

  // MARK: - Public

  /// The document being edited; nil until the image is loaded and the initial
  /// document is prepared.
  public var document: PhotosCropDocument? {
    history?.current
  }

  /// Whether `undo()` changes the document.
  public var canUndo: Bool {
    history?.canUndo ?? false
  }

  /// Whether `redo()` changes the document.
  public var canRedo: Bool {
    history?.canRedo ?? false
  }

  /// Whether the document differs from the initial one.
  public var isDirty: Bool {
    history?.isDirty ?? false
  }

  /// Moves to the previous checkpoint. One call always changes the document
  /// when undo is possible.
  public func undo() {
    guard canUndo else {
      return
    }
    history?.undo()
  }

  /// Reapplies the most recently undone checkpoint.
  public func redo() {
    guard canRedo else {
      return
    }
    history?.redo()
  }

  /// Discards the changes made since the latest checkpoint, or since the
  /// initial document when there is none.
  ///
  /// The document can still differ from the initial one afterwards
  /// (`isDirty`), because committed checkpoints are kept.
  public func discardUncommittedChanges() {
    guard hasUncommittedChanges else {
      return
    }
    history?.discardUncommittedChanges()
  }

  // MARK: - Editor surface

  /// Whether the editor has a document ready for controls and canvas display.
  var isLoaded: Bool {
    history != nil
  }

  /// Whether the document differs from the latest checkpoint.
  var hasUncommittedChanges: Bool {
    history?.hasUncommittedChanges ?? false
  }

  /// The original oriented source aspect ratio used by the crop controls.
  var originalAspectRatio: PixelAspectRatio? {
    editingStack.loadedState.map { PixelAspectRatio($0.imageSize) }
  }

  /// The thumbnail base image used by filter swatches.
  var filterPreviewBaseImage: CIImage? {
    editingStack.loadedState?.thumbnailImage
  }

  /// Starts image preparation.
  func start() {
    editingStack.start()
  }

  /// Changes the current document. It never makes a checkpoint, and a change
  /// that leaves the document equal changes nothing.
  func updateDocument(_ change: (inout PhotosCropDocument) -> Void) {
    guard var next = document else {
      return
    }
    change(&next)
    guard next != document else {
      return
    }
    history?.current = next
  }

  /// Commits the current document as an undo checkpoint when it changed.
  func commitIfNeeded() {
    guard hasUncommittedChanges else {
      return
    }
    history?.commitCurrentIfNeeded()
  }

  /// Selects a filter preset, or clears it with nil.
  ///
  /// Selecting the preset that is already selected changes nothing, so the
  /// document keeps the selected preset's value.
  func selectFilterPreset(_ preset: PresetFeature?) {
    updateDocument { document in
      guard document.effects.preset?.identifier != preset?.identifier else {
        return
      }
      document.effects.preset = preset
    }
  }

  /// Writes an adjustment slider value into the global effects.
  func setAdjustmentValue(
    _ sliderValue: Double,
    parameter: PhotosCropAdjustmentParameter
  ) {
    updateDocument { document in
      parameter.apply(sliderValue: sliderValue, to: &document.effects)
    }
  }

  /// Removes the blur mask; the effects and the crop are unchanged.
  func clearBlurMask() {
    updateDocument { document in
      document.blurMask = nil
    }
  }

  /// Whether the final crop differs from PhotosCrop's Reset target.
  ///
  /// Reset only restores the crop geometry, so this intentionally ignores
  /// effects and the blur mask.
  func hasCropChanges(tolerance: CGFloat = 1) -> Bool {
    guard
      let document,
      let imageSize = editingStack.loadedState?.imageSize
    else {
      return false
    }

    let crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
    let initial = crop.makeInitial()
    return crop.rotation != initial.rotation
      || abs(crop.adjustmentAngle.radians - initial.adjustmentAngle.radians) > 0.0001
      || abs(crop.cropExtent.minX - initial.cropExtent.minX) > tolerance
      || abs(crop.cropExtent.minY - initial.cropExtent.minY) > tolerance
      || abs(crop.cropExtent.width - initial.cropExtent.width) > tolerance
      || abs(crop.cropExtent.height - initial.cropExtent.height) > tolerance
  }

  // MARK: - Private

  /// Installs the initial document once the image has loaded.
  ///
  /// It runs at most once: it does nothing once the document is installed
  /// or while the crop modifier runs. For a stack that loads while `init`
  /// runs, both `init` and the load observation call this, so the guard is
  /// what keeps the modifier from running twice.
  private func prepareInitialDocumentIfNeeded() {
    guard
      let pendingInitialDocument,
      initialDocumentTask == nil,
      let loaded = editingStack.loadedState
    else {
      return
    }

    switch pendingInitialDocument {
    case .resume(let document):
      installInitialDocument(document.normalized())

    case .new(let cropModifier) where cropModifier.isIdentity:
      installInitialDocument(PhotosCropDocument(orientedImageSize: loaded.imageSize))

    case .new(let cropModifier):
      initialDocumentTask = Task { [weak self] in
        let document = await PhotosCropDocument.makeInitial(
          for: loaded,
          cropModifier: cropModifier
        )
        self?.installInitialDocument(document)
      }
    }
  }

  /// Starts the history and releases the one-shot preparation state.
  private func installInitialDocument(_ document: PhotosCropDocument) {
    guard history == nil else {
      return
    }
    history = EditingHistory(initial: document)
    pendingInitialDocument = nil
    initialDocumentTask = nil
    loadedStateSubscription = nil
  }
}

extension SwiftUICropView {

  /// Creates the reusable crop canvas over PhotosCrop's editing model.
  ///
  /// The model owns the document and prepares the initial one, so the canvas
  /// only reads it and applies its changes through the model. This keeps the
  /// shared canvas unaware of PhotosCrop; the model is the narrow boundary
  /// that maps PhotosCrop policy onto it.
  init(
    editingModel: PhotosCropEditingModel,
    isGuideInteractionEnabled: Bool
  ) {
    self.init(
      editingStack: editingModel.editingStack,
      documentSource: .init(
        document: { editingModel.document },
        update: { change in editingModel.updateDocument(change) },
        createInitialDocument: nil
      ),
      isGuideInteractionEnabled: isGuideInteractionEnabled
    )
  }
}
