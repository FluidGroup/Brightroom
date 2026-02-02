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
import MetalKit
import SwiftUI
import UIKit
import Combine
import StateGraph

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

    public var usesMTLTextureForEditingImage: Bool = true

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
        editingPreviewImage = currentEdit.filters.apply(to: editingSourceImage)
      }
    }

    /// Won't change from initial state
    public var imageSize: CGSize {
      initialEditing.imageSize
    }

    /**
     A stack of editing history
     */
    public fileprivate(set) var history: [Edit] = []

    public fileprivate(set) var thumbnailImage: CIImage

    public let editingSourceCGImage: CGImage
    /**
     An original image
     Can be used in cropping
     */
    public let editingSourceImage: CIImage

    public fileprivate(set) var editingPreviewImage: CIImage

    public fileprivate(set) var imageForCrop: CGImage

    public fileprivate(set) var previewFilterPresets: [PreviewFilterPreset] = []

    public var canUndo: Bool {
      return history.count > 0
    }

    /**
     A boolean value that indicates if EditingStack has updates against the original image.
     */
    public var isDirty: Bool {
      return currentEdit != initialEditing
    }

    public var hasUncommitedChanges: Bool {
      guard currentEdit == initialEditing else {
        return true
      }

      guard let latestHistory = history.last else {
        return false
      }

      guard latestHistory == currentEdit else {
        return true
      }

      return false
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
      editingPreviewCIImage: CIImage,
      imageForCrop: CGImage,
      previewFilterPresets: [PreviewFilterPreset] = []
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
      self.previewFilterPresets = previewFilterPresets
      self.imageForCrop = imageForCrop
    }

    // MARK: - Functions

    mutating func makeVersion() {
      history.append(currentEdit)
    }

    mutating func revertCurrentEditing() {
      currentEdit = history.last ?? initialEditing
    }

    mutating func revert(to revision: Revision) {
      history.removeSubrange(revision..<history.count)
      currentEdit = history.last ?? initialEditing
    }

    mutating func undoEditing() {
      currentEdit = history.popLast() ?? initialEditing
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

  private let mtlDevice = MTLCreateSystemDefaultDevice()

  public let imageProvider: ImageProvider

  private let filterPresets: [FilterPreset]

  private var subscriptions: Set<AnyCancellable> = .init()
  private var imageProviderSubscription: Any?

  public var cropModifier: CropModifier

  private let editingImageMaxPixelSize: CGFloat = 2560

  private let debounceForCreatingCGImage = _BrightroomDebounce(
    interval: 0.1,
    queue: DispatchQueue.init(label: "Brightroom.cgImage")
  )

  // MARK: - Change Tracking

  private var _previousThumbnailImage: CIImage?
  private var _previousFilters: Edit.Filters?

  // MARK: - Initializers

  /// Creates an instance
  /// - Parameters:
  ///   - source:
  ///   - previewSize:
  ///   - colorCubeStorage:
  ///   - modifyCrop: A chance to modify cropping. It runs in background-thread. CIImage is not original image.
  public init(
    imageProvider: ImageProvider,
    colorCubeStorage: ColorCubeStorage = .default,
    presetStorage: PresetStorage = .default,
    options: Options = .init(),
    cropModifier: CropModifier = .init(modify: { _, c, completion in completion(c) })
  ) {

    self.options = options
    self.cropModifier = cropModifier

    filterPresets =
      colorCubeStorage.filters.map {
        FilterPreset(
          name: $0.name,
          identifier: $0.identifier,
          filters: [$0.asAny()],
          userInfo: [:]
        )
      } + presetStorage.presets

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
    if hasStartedEditing {
      DispatchQueue.main.async {
        onPreparationCompleted()
      }
      return
    }
    hasStartedEditing = true

    // Set up state observation on background queue
    withGraphTracking { [weak self] in
      withGraphTrackingGroup {
        guard let self = self else { return }
        self.backgroundQueue.async {
          self.receiveInBackground()
        }
      }
    }
    .store(in: &subscriptions)

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
        orientation: metadata.orientation,
        device: self.mtlDevice,
        usesMTLTexture: self.options.usesMTLTextureForEditingImage
      )

      let _thumbnailImage: CIImage = thumbnailCGImage._makeCIImage(
        orientation: metadata.orientation,
        device: self.mtlDevice,
        usesMTLTexture: self.options.usesMTLTextureForEditingImage
      )

      let cgImageForCrop: CGImage = {
        do {
          return try Self.renderCGImageForCrop(
            filters: [],
            source: .init(cgImage: editingSourceCGImage),
            orientation: metadata.orientation
          )
        } catch {
          EngineSanitizer.global.onDidFindRuntimeError(
            .failedToRenderCGImageForCrop(sourceImage: editingSourceCGImage)
          )
          assertionFailure()
          return editingSourceCGImage
        }
      }()

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

          self.loadedState = .init(
            imageSource: imageSource,
            metadata: metadata,
            initialEditing: initialEdit,
            currentEdit: initialEdit,
            thumbnailCIImage: _thumbnailImage,
            editingSourceCGImage: editingSourceCGImage,
            editingSourceCIImage: _editingSourceCIImage,
            editingPreviewCIImage: initialEdit.filters.apply(to: _editingSourceCIImage),
            imageForCrop: cgImageForCrop
          )

          self.imageProviderSubscription = nil

          DispatchQueue.main.async {
            onPreparationCompleted()
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

      return try sourceImage
      // TODO: better to combine these operations - oriented and cropping
        .oriented(orientation)
        .croppedWithColorspace(
          to: scaledCrop.cropExtent, adjustmentAngleRadians: scaledCrop.aggregatedRotation.radians
        )
        ._makeCIImage(
          orientation: .up,
          device: mtlDevice,
          usesMTLTexture: options.usesMTLTextureForEditingImage
        )
    } catch {
      return .init(color: .gray)
    }
  }

  deinit {
    EngineLog.debug("[EditingStack] deinit")
  }

  private func receiveInBackground() {

    assert(Thread.isMainThread == false)

    guard let loadedState = self.loadedState else { return }

    // Check if thumbnailImage changed
    if _previousThumbnailImage != loadedState.thumbnailImage {
      _previousThumbnailImage = loadedState.thumbnailImage

      let image = loadedState.thumbnailImage
      let presets = self.filterPresets.map {
        PreviewFilterPreset(sourceImage: image, filter: $0)
      }
      self.loadedState?.previewFilterPresets = presets
    }

    // Check if filters changed
    if _previousFilters != loadedState.currentEdit.filters {
      _previousFilters = loadedState.currentEdit.filters

      let currentFilters = loadedState.currentEdit.filters

      self.debounceForCreatingCGImage.on { [weak self] in

        guard let self = self, let loadedState = self.loadedState else { return }

        let cgImageForCrop: CGImage = {
          do {
            return try Self.renderCGImageForCrop(
              filters: currentFilters.makeFilters(),
              source: .init(cgImage: loadedState.editingSourceCGImage),
              orientation: loadedState.metadata.orientation
            )
          } catch {
            assertionFailure()
            return loadedState.editingSourceCGImage
          }
        }()

        self.loadedState?.imageForCrop = cgImageForCrop
      }
    }
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
   */
  public func undoEdit() {
    _pixelengine_ensureMainThread()
    loadedState?.undoEditing()
  }

  /**
   Purges the all of the history
   */
  public func removeAllEditsHistory() {
    _pixelengine_ensureMainThread()
    loadedState?.history = []
  }

  public func set(filters: (inout Edit.Filters) -> Void) {
    _pixelengine_ensureMainThread()
    applyIfChanged {
      filters(&$0.filters)
    }
  }

  public func crop(_ value: EditingCrop) {
    applyIfChanged {
      $0.crop = value
    }
  }

  public func set(blurringMaskPaths: [DrawnPath]) {
    _pixelengine_ensureMainThread()
    applyIfChanged {
      $0.drawings.blurredMaskPaths = blurringMaskPaths
    }
  }

  public func append<C: Collection>(blurringMaskPaths: C) where C.Element == DrawnPath {
    _pixelengine_ensureMainThread()
    applyIfChanged {
      $0.drawings.blurredMaskPaths += blurringMaskPaths
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

    // TODO: Clean up ImageRenderer.Edit

    let edit = loaded.currentEdit

    renderer.edit.croppingRect = edit.crop

    if edit.drawings.blurredMaskPaths.isEmpty == false {
      renderer.edit.drawer = [
        BlurredMask(paths: edit.drawings.blurredMaskPaths)
      ]
    }

    renderer.edit.modifiers = edit.makeFilters()

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
        y: image.extent.height < imageSize.width ? imageSize.height / image.extent.height : 1
      )
    )

    let translated = scaled.transformed(
      by: .init(
        translationX: scaled.extent.origin.x,
        y: scaled.extent.origin.y
      )
    )

    let actualSizeFromDownsampledImage = translated

    cropModifier.run(actualSizeFromDownsampledImage, editingCrop: crop, completion: completion)
  }

  private static func renderCGImageForCrop(
    filters: [AnyFilter],
    source: ImageSource,
    orientation: CGImagePropertyOrientation
  ) throws -> CGImage {

    let renderer = BrightRoomImageRenderer(source: source, orientation: orientation)
    renderer.edit.modifiers = filters

    let result = try renderer.render().cgImage

    return result
  }

}
