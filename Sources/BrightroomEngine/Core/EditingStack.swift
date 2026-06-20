//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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
import SwiftUI
import UIKit
import Combine
import StateGraph

import BrightroomParametric

public enum EditingStackError: Error, Sendable {
  case unableToCreateRendererInLoading
}

/// A value-type undo/redo journal for document snapshots.
///
/// `EditingStack` owns this because history is a property of the editable
/// document, while feature-specific UIs decide when the current edit should
/// become a checkpoint.
private struct EditingHistory<State: Equatable>: Equatable {

  /// The edit the stack loaded with.
  let initial: State

  /// The edit currently being previewed and rendered.
  var current: State

  /// Committed undo checkpoints.
  private var checkpoints: [State]

  /// Checkpoints undone from `checkpoints`, available until the next commit.
  private var redoStack: [State]

  /// Creates a history journal around the loaded edit.
  init(
    initial: State,
    current: State,
    checkpoints: [State] = [],
    redoStack: [State] = []
  ) {
    self.initial = initial
    self.current = current
    self.checkpoints = checkpoints
    self.redoStack = redoStack
  }

  /// The current revision index, matching the number of committed checkpoints.
  var revision: Int {
    checkpoints.count
  }

  /// Whether undo can move the current edit to another state.
  var canUndo: Bool {
    if checkpoints.last == current {
      return checkpoints.count > 1 || current != initial
    }
    return checkpoints.isEmpty == false || current != initial
  }

  /// Whether redo can move the current edit to another state.
  var canRedo: Bool {
    redoStack.isEmpty == false
  }

  /// Whether the current edit differs from the loaded edit.
  var isDirty: Bool {
    current != initial
  }

  /// Whether the current edit differs from the latest committed checkpoint.
  var hasUncommittedChanges: Bool {
    guard let latestCheckpoint = checkpoints.last else {
      return current != initial
    }
    return latestCheckpoint != current
  }

  /// Commits the current edit when it differs from the latest checkpoint.
  mutating func commitCurrentIfNeeded() {
    guard hasUncommittedChanges else {
      return
    }
    commitCurrent()
  }

  /// Commits the current edit as a checkpoint and clears redo.
  mutating func commitCurrent() {
    checkpoints.append(current)
    redoStack = []
  }

  /// Reverts the current edit to the latest checkpoint, or the initial edit.
  mutating func revertCurrent() {
    current = checkpoints.last ?? initial
  }

  /// Reverts to the checkpoint at `revision`, clamping stale revision values.
  mutating func revert(to revision: Int) {
    let clamped = min(max(revision, 0), checkpoints.count)
    checkpoints.removeSubrange(clamped..<checkpoints.count)
    redoStack = []
    current = checkpoints.last ?? initial
  }

  /// Moves the current edit to the previous checkpoint.
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

  /// Removes all committed and redo checkpoints without changing `current`.
  mutating func removeAllCheckpoints() {
    checkpoints = []
    redoStack = []
  }
}

/// A stateful object that manages current editing status from original image.
/// And supports rendering a result image.
///
/// - Attension: Source text
/// Please make sure of EditingStack is started state before editing in UI with calling `start()`.
open class EditingStack: Hashable {

  private static let centralQueue = DispatchQueue.init(
    label: "app.muukii.Brightroom.EditingStack.central",
    qos: .default,
    attributes: .concurrent
  )

  private let backgroundQueue = DispatchQueue.init(
    label: "app.muukii.Brightroom.EditingStack",
    qos: .default,
    target: centralQueue
  )

  public struct Options {

    public init() {}
  }

  public static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }

  // MARK: - Nested Types

  public struct Loaded: Equatable {

    // MARK: - Properties

    fileprivate let imageSource: ImageSource

    public let metadata: ImageProvider.ImageMetadata

    private var editHistory: EditingHistory<Edit>

    /// The edit currently being previewed and rendered.
    public var currentEdit: Edit {
      get {
        editHistory.current
      }
      set {
        editHistory.current = newValue
      }
    }

    /// Won't change from initial state
    public var imageSize: CGSize {
      editHistory.initial.imageSize
    }

    public fileprivate(set) var thumbnailImage: CIImage

    public let editingSourceCGImage: CGImage
    /**
     An original image
     Can be used in cropping
     */
    public let editingSourceImage: CIImage

    public var canUndo: Bool {
      editHistory.canUndo
    }

    public var canRedo: Bool {
      editHistory.canRedo
    }

    /**
     A boolean value that indicates if EditingStack has updates against the original image.
     */
    public var isDirty: Bool {
      editHistory.isDirty
    }

    /// Whether the current edit differs from the latest committed checkpoint.
    public var hasUncommittedChanges: Bool {
      editHistory.hasUncommittedChanges
    }

    // MARK: - Initializers

    init(
      imageSource: ImageSource,
      metadata: ImageProvider.ImageMetadata,
      initialEditing: EditingStack.Edit,
      currentEdit: EditingStack.Edit,
      checkpoints: [EditingStack.Edit] = [],
      thumbnailCIImage: CIImage,
      editingSourceCGImage: CGImage,
      editingSourceCIImage: CIImage
    ) {
      self.imageSource = imageSource
      self.metadata = metadata
      self.editHistory = EditingHistory(
        initial: initialEditing,
        current: currentEdit,
        checkpoints: checkpoints
      )
      self.thumbnailImage = thumbnailCIImage
      self.editingSourceCGImage = editingSourceCGImage
      self.editingSourceImage = editingSourceCIImage
    }

    // MARK: - Functions

    public func makeOriginalCIImage() -> CIImage {
      imageSource
        .makeOriginalCIImage()
        .oriented(metadata.orientation)
        .removingExtentOffset()
    }

    var currentRevision: Revision {
      editHistory.revision
    }

    mutating func commitCurrentEditIfNeeded() {
      editHistory.commitCurrentIfNeeded()
    }

    mutating func commitCurrentEdit() {
      editHistory.commitCurrent()
    }

    mutating func revertCurrentEdit() {
      editHistory.revertCurrent()
    }

    mutating func revert(to revision: Revision) {
      editHistory.revert(to: revision)
    }

    mutating func undo() {
      editHistory.undo()
    }

    mutating func redo() {
      editHistory.redo()
    }

    mutating func removeAllHistory() {
      editHistory.removeAllCheckpoints()
    }

  }

  // MARK: - State Properties

  @GraphStored public var hasStartedEditing: Bool = false

  /**
   A Boolean value that indicates whether the image is currently loading for editing.
   */
  public var isLoading: Bool {
    loadedState == nil
  }

  @GraphStored public var loadedState: Loaded? = nil

  // MARK: - Stored Properties

  public let options: Options

  public let imageProvider: ImageProvider

  private var subscriptions: Set<AnyCancellable> = .init()
  private var imageProviderSubscription: AnyCancellable?

  private let startLock = NSLock()

  public var cropModifier: CropModifier

  // The editing source is downsampled to this longest-side resolution; it is the
  // upper bound on detail anywhere downstream. Keep in sync with the canvas
  // preview bake cap `EditingCanvasImageProcessing.contentBakeMaxPixelSize`
  // (BrightroomUI): that bake is "visually lossless" only while the two match.
  private let editingImageMaxPixelSize: CGFloat = 2560

  // MARK: - Initializers

  /// Creates an instance
  /// - Parameters:
  ///   - source:
  ///   - previewSize:
  ///   - modifyCrop: A chance to modify cropping. It runs in background-thread. CIImage is not original image.
  public init(
    imageProvider: ImageProvider,
    options: Options = .init(),
    cropModifier: CropModifier = .init(modify: { _, c, _, completion in completion(c) })
  ) {

    self.options = options
    self.cropModifier = cropModifier

    self.imageProvider = imageProvider
  }

  /**
   EditingStack awakes from cold state.

   - Calling from background-thread supported.
   */
  public func start(onPreparationCompleted: @escaping @MainActor () -> Void = {}) {

    /**
     Mutual exclusion
     */
    guard markStartedIfNeeded() else {
      DispatchQueue.main.async {
        onPreparationCompleted()
      }
      return
    }

    /**
     Start downloading image
     */

    backgroundQueue.async {
      self.imageProvider.start()
    }

    // Observe image provider's loaded image
    let imageProviderSub = withGraphTracking {
      withGraphTrackingMap(from: self, map: { $0.imageProvider.loadedImage }, onChange: { [weak self] image in
        guard let self, let image else { return }
        self.backgroundQueue.async {
          self.handleImageLoaded(image: image, onPreparationCompleted: onPreparationCompleted)
        }
      })
    }
    imageProviderSubscription = imageProviderSub
  }

  private func markStartedIfNeeded() -> Bool {
    startLock.lock()
    defer {
      startLock.unlock()
    }

    guard hasStartedEditing == false else {
      return false
    }

    hasStartedEditing = true
    return true
  }

  private func handleImageLoaded(
    image: ImageProvider.LoadedImage,
    onPreparationCompleted: @escaping @MainActor () -> Void
  ) {
    switch image {
    case let .editable(imageSource, metadata):

      let thumbnailCGImage = imageSource.loadThumbnailCGImage(maxPixelSize: 180)

      /**
       An image resised from original image
       */
      let editingSourceCGImage = imageSource.loadThumbnailCGImage(
        maxPixelSize: self.editingImageMaxPixelSize
      )

      assert(editingSourceCGImage.colorSpace != nil)

      /// resized
      let _editingSourceCIImage: CIImage = editingSourceCGImage._makeCIImage(
        orientation: metadata.orientation
      )

      let _thumbnailImage: CIImage = thumbnailCGImage._makeCIImage(
        orientation: metadata.orientation
      )

      self.adjustCropExtent(
        image: _editingSourceCIImage,
        imageSize: metadata.imageSize,
        completion: { [weak self] crop in

          guard let self = self else { return }

          assert(
            (_editingSourceCIImage.extent.width > _editingSourceCIImage.extent.height)
              == (metadata.imageSize.width > metadata.imageSize.height)
          )

          let initialEdit = EditingFeatureTree.canonicalEdit(
            finalCrop: crop,
            orientedImageSize: metadata.imageSize
          )

          /**
           Upload the editing source into a persistent GPU texture off the main
           thread *before* publishing `loadedState` (which reveals the editing
           canvas). The canvas re-renders the source into its own viewport texture
           every frame, and zoom / pan / rotation invalidate that cache every
           frame; a `CIImage(cgImage:)` source would re-blit its bitmap CPU->GPU
           on each of those frames. A texture-backed source keeps it GPU-resident,
           eliminating that per-frame upload. Building the texture also warms Core
           Image's pipeline, so the first `draw(in:)` no longer pays the upload +
           one-time pipeline compilation on the main thread.
           */
          self.backgroundQueue.async { [weak self] in
            guard let self else { return }

            // Fall back to the CPU-backed source if no Metal device is available
            // (e.g. unsupported environment); display still works, just without
            // the GPU-residency win.
            let editingSource = EditingSourcePreparation.makeGPUResidentSource(
              cgImage: editingSourceCGImage,
              orientation: metadata.orientation
            ) ?? _editingSourceCIImage

            let loaded = Loaded(
              imageSource: imageSource,
              metadata: metadata,
              initialEditing: initialEdit,
              currentEdit: initialEdit,
              thumbnailCIImage: _thumbnailImage,
              editingSourceCGImage: editingSourceCGImage,
              editingSourceCIImage: editingSource
            )

            self.loadedState = loaded
            self.imageProviderSubscription = nil

            DispatchQueue.main.async {
              onPreparationCompleted()
            }
          }
        }
      )
    }
  }

  deinit {
    EngineLog.debug("[EditingStack] deinit")
  }

  // MARK: - Functions

  /// Commits the current edit as an undo checkpoint when it changed.
  public func commitCurrentEditIfNeeded() {
    _pixelengine_ensureMainThread()
    loadedState?.commitCurrentEditIfNeeded()
  }

  public typealias Revision = Int

  public var currentRevision: Revision? {
    loadedState?.currentRevision
  }

  public func revert(to revision: Revision) {
    _pixelengine_ensureMainThread()
    loadedState?.revert(to: revision)
  }

  /// Reverts the current edit to the latest checkpoint, or the initial edit.
  public func revertCurrentEdit() {
    _pixelengine_ensureMainThread()
    loadedState?.revertCurrentEdit()
  }

  /// Moves the current edit to the previous checkpoint.
  public func undo() {
    _pixelengine_ensureMainThread()
    loadedState?.undo()
  }

  /// Reapplies the most recently undone checkpoint.
  public func redo() {
    _pixelengine_ensureMainThread()
    loadedState?.redo()
  }

  /// Removes all undo and redo checkpoints without changing the current edit.
  public func removeAllHistory() {
    _pixelengine_ensureMainThread()
    loadedState?.removeAllHistory()
  }

  // `sending`: the renderer is freshly created here and not retained by the
  // stack, so it forms a disconnected region the caller can hand to the
  // off-actor `render()` without a data-race risk.
  public func makeRenderer() throws -> sending BrightRoomImageRenderer {

    guard let loaded = loadedState else {
      throw EditingStackError.unableToCreateRendererInLoading
    }

    let imageSource = loaded.imageSource

    let renderer = BrightRoomImageRenderer(
      source: imageSource,
      orientation: loaded.metadata.orientation
    )

    let edit = loaded.currentEdit

    // Lower the editing document into the parametric document the renderer
    // evaluates. The renderer applies orientation to the source CIImage; the
    // document is authored in that oriented space, whose size is
    // `edit.orientedImageSize`.
    renderer.edit = .init(
      document: edit.makeEditingDocument(orientedImageSize: edit.orientedImageSize)
    )

    return renderer
  }

  private func adjustCropExtent(
    image: CIImage,
    imageSize: CGSize,
    completion: @escaping (CropFeature) -> Void
  ) {
    let crop = CropFeature(
      id: EditingFeatureTree.finalCropNodeID,
      displayCropRect: CGRect(origin: .zero, size: imageSize),
      imageSize: imageSize
    )

    let scaled = image.transformed(
      by: .init(
        scaleX: image.extent.width < imageSize.width ? imageSize.width / image.extent.width : 1,
        y: image.extent.height < imageSize.height ? imageSize.height / image.extent.height : 1
      )
    )

    let translated = scaled.transformed(
      by: .init(
        translationX: -scaled.extent.origin.x,
        y: -scaled.extent.origin.y
      )
    )

    let actualSizeFromDownsampledImage = translated

    cropModifier.run(
      actualSizeFromDownsampledImage,
      crop: crop,
      imageSize: imageSize,
      completion: completion
    )
  }

}
