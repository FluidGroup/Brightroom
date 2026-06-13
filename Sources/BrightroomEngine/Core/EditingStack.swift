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

    private let initialEditing: Edit

    /**

     - TODO: Should be marked as `fileprivate(set)`, but compile fails in CocoaPods installed.
     */
    public var currentEdit: Edit {
      didSet {
        // Keyed on every effects feature, not just the first projection;
        // a document may carry more than one.
        if currentEdit.effectsSequence != oldValue.effectsSequence {
          editingPreviewImage = currentEdit.makePreviewImage(
            from: editingSourceImage,
            purpose: .editingBase
          )
        }
      }
    }

    /// Won't change from initial state
    public var imageSize: CGSize {
      initialEditing.imageSize
    }

    /**
     A stack of editing history: snapshots of the feature-list document.
     */
    public fileprivate(set) var history: [Edit] = []

    /**
     Versions undone from `history`, available for redo until the next
     mutationsnapshot.
     */
    public fileprivate(set) var redoHistory: [Edit] = []

    public fileprivate(set) var thumbnailImage: CIImage

    public let editingSourceCGImage: CGImage
    /**
     An original image
     Can be used in cropping
     */
    public let editingSourceImage: CIImage

    /**
     A lightweight editing preview used by legacy interactive views.
     Local adjustments are intentionally excluded from automatic refresh because
     their mask rasterization can be expensive and should be owned by the render
     path that knows its target resolution.
     */
    public fileprivate(set) var editingPreviewImage: CIImage

    public var canUndo: Bool {
      // Mirror undoEditing: a history top equal to the current edit is
      // skipped, and an empty history can still undo back to the initial
      // editing when there are uncommitted changes.
      if history.last == currentEdit {
        return history.count > 1 || currentEdit != initialEditing
      }
      return history.count > 0 || currentEdit != initialEditing
    }

    public var canRedo: Bool {
      return redoHistory.count > 0
    }

    /**
     A boolean value that indicates if EditingStack has updates against the original image.
     */
    public var isDirty: Bool {
      return currentEdit.isRenderingEquivalent(to: initialEditing) == false
    }

    public var hasUncommitedChanges: Bool {
      guard let latestHistory = history.last else {
        return currentEdit.isRenderingEquivalent(to: initialEditing) == false
      }

      return latestHistory.isRenderingEquivalent(to: currentEdit) == false
    }

    // MARK: - Initializers

    init(
      imageSource: ImageSource,
      metadata: ImageProvider.ImageMetadata,
      initialEditing: EditingStack.Edit,
      currentEdit: EditingStack.Edit,
      history: [EditingStack.Edit] = [],
      thumbnailCIImage: CIImage,
      editingSourceCGImage: CGImage,
      editingSourceCIImage: CIImage,
      editingPreviewCIImage: CIImage
    ) {
      self.imageSource = imageSource
      self.metadata = metadata
      self.initialEditing = initialEditing
      self.currentEdit = currentEdit
      self.history = history
      self.thumbnailImage = thumbnailCIImage
      self.editingSourceCGImage = editingSourceCGImage
      self.editingSourceImage = editingSourceCIImage
      self.editingPreviewImage = editingPreviewCIImage
    }

    // MARK: - Functions

    public func makeOriginalCIImage() -> CIImage {
      imageSource
        .makeOriginalCIImage()
        .oriented(metadata.orientation)
        .removingExtentOffset()
    }

    mutating func makeVersion() {
      history.append(currentEdit)
      redoHistory = []
    }

    mutating func revertCurrentEditing() {
      currentEdit = history.last ?? initialEditing
    }

    mutating func revert(to revision: Revision) {
      // A captured revision can go stale when undo or history purges shrink
      // the stack; clamp instead of trapping on the invalid range.
      let clamped = min(max(revision, 0), history.count)
      history.removeSubrange(clamped..<history.count)
      redoHistory = []
      currentEdit = history.last ?? initialEditing
    }

    mutating func undoEditing() {
      // Commit-style snapshots (PhotosCrop snapshots when leaving a tool)
      // leave history.last equal to currentEdit at settled states; drop it so
      // one undo press always changes visible state and redoHistory gets no
      // duplicates.
      if history.last == currentEdit {
        history.removeLast()
      }
      if let last = history.popLast() {
        redoHistory.append(currentEdit)
        currentEdit = last
      } else if currentEdit != initialEditing {
        redoHistory.append(currentEdit)
        currentEdit = initialEditing
      }
    }

    mutating func redoEditing() {
      guard let next = redoHistory.popLast() else {
        return
      }
      history.append(currentEdit)
      currentEdit = next
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
    cropModifier: CropModifier = .init(modify: { _, c, completion in completion(c) })
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

          let initialEdit = Edit(crop: crop)

          let loaded = Loaded(
            imageSource: imageSource,
            metadata: metadata,
            initialEditing: initialEdit,
            currentEdit: initialEdit,
            thumbnailCIImage: _thumbnailImage,
            editingSourceCGImage: editingSourceCGImage,
            editingSourceCIImage: _editingSourceCIImage,
            editingPreviewCIImage: initialEdit.makePreviewImage(
              from: _editingSourceCIImage,
              purpose: .editingBase
            )
          )

          /**
           Warm Core Image's GPU pipeline off the main thread *before* publishing
           `loadedState` (which reveals the editing canvas). The source is no longer
           pre-uploaded as an MTLTexture at load time, so without this the first
           `draw(in:)` would pay the GPU upload + one-time pipeline compilation on
           the main thread and visibly stall.
           */
          self.backgroundQueue.async { [weak self] in
            guard let self else { return }

            EditingImageWarmUp.warmUp(loaded.editingSourceImage)

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

  /**
   Returns a CIImage applied cropping in current editing.

   For previewing image
   */
  public func makeCroppedCIImage(
    sourceImage: CGImage,
    crop: EditingCrop,
    orientation: CGImagePropertyOrientation
  ) -> CIImage {

    do {

      // orientation-respected
      let imageSize = sourceImage.size
        .applying(cgOrientation: orientation)

      let scaledCrop = crop.scaledWithPixelPerfect(
        maxPixelSize: max(imageSize.width, imageSize.height)
      )

      let orientedImage = try sourceImage
        // TODO: better to combine these operations - oriented and cropping
        .oriented(orientation)
      let renderCrop = RenderCrop(scaledCrop, imageSize: orientedImage.size)

      return try orientedImage
        .croppedWithColorspace(to: renderCrop)
        ._makeCIImage(
          orientation: .up
        )
    } catch {
      return .init(color: .gray)
    }
  }

  deinit {
    EngineLog.debug("[EditingStack] deinit")
  }

  // MARK: - Functions

  /**
   Adds a new snapshot as a history.
   */
  public func takeSnapshot() {
    loadedState?.makeVersion()
  }

  public typealias Revision = Int

  public var currentRevision: Revision? {
    loadedState?.history.count
  }

  public func revert(to revision: Revision) {
    loadedState?.revert(to: revision)
  }

  /**
   Reverts the current editing.
   */
  public func revertEdit() {
    _pixelengine_ensureMainThread()
    loadedState?.revertCurrentEditing()
  }

  /**
   Undo editing, pulling the latest history back into the current edit.
   The undone version stays available for `redoEdit`.
   */
  public func undoEdit() {
    _pixelengine_ensureMainThread()
    loadedState?.undoEditing()
  }

  /**
   Redo the most recently undone version. No-op when there is nothing to redo.
   Any new snapshot clears the redo stack.
   */
  public func redoEdit() {
    _pixelengine_ensureMainThread()
    loadedState?.redoEditing()
  }

  /**
   Purges the all of the history
   */
  public func removeAllEditsHistory() {
    _pixelengine_ensureMainThread()
    loadedState?.history = []
    loadedState?.redoHistory = []
  }

  public func set(effects: (inout EffectPipeline) -> Void) {
    _pixelengine_ensureMainThread()
    applyIfChanged {
      effects(&$0.effects)
    }
  }

  public func crop(_ value: EditingCrop) {
    _pixelengine_ensureMainThread()
    applyIfChanged {
      $0.crop = value
    }
  }

  public func set(localAdjustments: [LocalAdjustmentFeature]) {
    _pixelengine_ensureMainThread()
    applyIfChanged {
      $0.localAdjustments = localAdjustments
    }
  }

  public func append(localAdjustment: LocalAdjustmentFeature) {
    _pixelengine_ensureMainThread()
    applyIfChanged {
      $0.localAdjustments.append(localAdjustment)
    }
  }

  public func makeRenderer() throws -> BrightRoomImageRenderer {

    guard let loaded = loadedState else {
      throw EditingStackError.unableToCreateRendererInLoading
    }

    let imageSource = loaded.imageSource

    let renderer = BrightRoomImageRenderer(
      source: imageSource,
      orientation: loaded.metadata.orientation
    )

    let edit = loaded.currentEdit

    renderer.edit.croppingRect = edit.crop
    // Compile the document in feature order. The crop feature is the domain
    // feature handled via croppingRect; pixel operations keep their list
    // positions so an effects feature after an adjustment stays after it.
    renderer.edit.operations = edit.features.compactMap { feature in
      switch feature.payload {
      case .effects(let pipeline):
        return pipeline.hasEnabledEffects ? .effects(pipeline) : nil
      case .localAdjustment(let adjustment):
        return .localAdjustment(adjustment)
      case .crop:
        return nil
      }
    }

    return renderer
  }

  private func applyIfChanged(_ perform: (inout Edit) -> Void) {
    guard loadedState != nil else {
      return
    }
    perform(&loadedState!.currentEdit)
  }

  private func adjustCropExtent(
    image: CIImage,
    imageSize: CGSize,
    completion: @escaping (EditingCrop) -> Void
  ) {
    let crop = EditingCrop(imageSize: imageSize)

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

    cropModifier.run(actualSizeFromDownsampledImage, editingCrop: crop, completion: completion)
  }

}
