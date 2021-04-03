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
import Verge

@available(iOS 13, *)
extension EditingStack: ObservableObject {}

public enum EditingStackError: Error {
  case unableToCreateRendererInLoading
}

/// A stateful object that manages current editing status from original image.
/// And supports rendering a result image.
///
/// - Attension: Source text
/// Please make sure of EditingStack is started state before editing in UI with calling `start()`.

open class EditingStack: Equatable, StoreComponentType {

  public struct Options {

    public var usesMTLTextureForEditingImage: Bool {
      return true
    }

    public init() {}
  }

  public static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }

  public struct State: Equatable {
    public struct Loading: Equatable {}

    public struct Loaded: Equatable {
      init(
        imageSource: ImageSource,
        metadata: ImageProvider.State.ImageMetadata,
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

      fileprivate let imageSource: ImageSource
      public let metadata: ImageProvider.State.ImageMetadata
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

      mutating func makeVersion() {
        history.append(currentEdit)
      }

      mutating func revertCurrentEditing() {
        currentEdit = history.last ?? initialEditing
      }

      mutating func undoEditing() {
        currentEdit = history.popLast() ?? initialEditing
      }

      public func makeCroppedImage() -> CIImage {
        editingSourceImage.cropped(
          to: currentEdit.crop.scaledWithPixelPerfect(
            maxPixelSize: max(editingSourceImage.extent.width, editingSourceImage.extent.height)
          )
        )
      }

    }

    public fileprivate(set) var hasStartedEditing = false
    /**
     A Boolean value that indicates whether the image is currently loading for editing.
     */
    public var isLoading: Bool {
      loadedState == nil
    }

    public fileprivate(set) var loadingState: Loading = .init()
    public fileprivate(set) var loadedState: Loaded?

    init() {}
  }

  // MARK: - Stored Properties

  public let store: DefaultStore

  public let options: Options

  public let imageProvider: ImageProvider

  private let filterPresets: [FilterPreset]

  private var subscriptions = Set<VergeAnyCancellable>()
  private var imageProviderSubscription: VergeAnyCancellable?

  public var cropModifier: CropModifier

  private let editingImageMaxPixelSize: CGFloat = 2560

  private let debounceForCreatingCGImage = _BrightroomDebounce(interval: 0.1, queue: DispatchQueue.init(label: "Brightroom.cgImage"))

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
    options: Options = .init(),
    cropModifier: CropModifier = .init(modify: { _, c, completion in completion(c) })
  ) {

    self.options = options
    self.cropModifier = cropModifier
    store = .init(
      initialState: .init()
    )

    filterPresets = colorCubeStorage.filters.map {
      FilterPreset(name: $0.name, identifier: $0.identifier, filters: [$0.asAny()])
    }

    self.imageProvider = imageProvider
  }

  /**
   EditingStack awakes from cold state.

   - Calling from background-thread supported.
   */
  public func start(onPreparationCompleted: @escaping () -> Void = {}) {

    let previousHasCompleted = commit { s -> Bool in
      /**
       Mutual exclusion
       */
      if s.hasStartedEditing {
        return true
      } else {
        s.hasStartedEditing = true
        return false
      }
    }

    guard previousHasCompleted == false else {
      DispatchQueue.main.async {
        onPreparationCompleted()
      }
      return
    }

    store.sinkState(queue: .asyncSerialBackground) { [weak self] (state: Changes<State>) in
      guard let self = self else { return }
      self.receiveInBackground(newState: state)
    }
    .store(in: &subscriptions)

    /**
     Start downloading image
     */
    imageProvider.start()
    imageProviderSubscription =
      imageProvider
      .sinkState(queue: .asyncSerialBackground) {
        [weak self] (state: Changes<ImageProvider.State>) in

        /*
         In Background thread
         */

        guard let self = self else { return }

        state.ifChanged(\.loadedImage) { image in

          guard let image = image else {
            return
          }

          switch image {
          case let .editable(image, metadata):

            let thumbnailCGImage = image.loadThumbnailCGImage(maxPixelSize: 180)

            /**
             An image resised from original image
             */
            let editingSourceCGImage = image.loadThumbnailCGImage(
              maxPixelSize: self.editingImageMaxPixelSize
            )

            assert(editingSourceCGImage.colorSpace != nil)

            let device = MTLCreateSystemDefaultDevice()

            /// resized
            let _editingSourceCIImage: CIImage = _makeCIImage(
              source: editingSourceCGImage,
              orientation: metadata.orientation,
              device: device,
              usesMTLTexture: self.options.usesMTLTextureForEditingImage
            )

            let _thumbnailImage: CIImage = _makeCIImage(
              source: thumbnailCGImage,
              orientation: metadata.orientation,
              device: device,
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
                assertionFailure()
                return editingSourceCGImage
              }
            }()

            self.adjustCropExtent(
              image: _editingSourceCIImage,
              imageSize: metadata.imageSize,
              completion: { [weak self] crop in

                guard let self = self else { return }

                self.commit { (s: inout InoutRef<State>) in
                  assert(
                    (_editingSourceCIImage.extent.width > _editingSourceCIImage.extent.height)
                      == (metadata.imageSize.width > metadata.imageSize.height)
                  )

                  let initialEdit = Edit(crop: crop)

                  s.loadedState = .init(
                    imageSource: image,
                    metadata: metadata,
                    initialEditing: initialEdit,
                    currentEdit: initialEdit,
                    thumbnailCIImage: _thumbnailImage,
                    editingSourceCGImage: editingSourceCGImage,
                    editingSourceCIImage: _editingSourceCIImage,
                    editingPreviewCIImage: initialEdit.filters.apply(to: _editingSourceCIImage),
                    imageForCrop: cgImageForCrop
                  )

                  self.imageProviderSubscription?.cancel()

                  DispatchQueue.main.async {
                    onPreparationCompleted()
                  }
                }
              }
            )

          }
        }
      }
  }

  deinit {
    EngineLog.debug("[EditingStack] deinit")
  }

  private func receiveInBackground(newState state: Changes<State>) {

    assert(Thread.isMainThread == false)

    commit { (modifyingState: inout InoutRef<State>) in

      if let loadedState = state._beta_map(\.loadedState) {
        modifyingState.map(keyPath: \.loadedState!) { (nextState) -> Void in

          loadedState.ifChanged(\.thumbnailImage) { image in

            nextState.previewFilterPresets = self.filterPresets.map {
              PreviewFilterPreset(sourceImage: image, filter: $0)
            }
          }

          loadedState.ifChanged(\.currentEdit.filters) { currentEdit in

            self.debounceForCreatingCGImage.on { [weak self] in

              guard let self = self else { return }

              let cgImageForCrop: CGImage = {
                do {
                  return try Self.renderCGImageForCrop(
                    filters: currentEdit.makeFilters(),
                    source: .init(cgImage: loadedState.editingSourceCGImage),
                    orientation: loadedState.metadata.orientation
                  )
                } catch {
                  assertionFailure()
                  return loadedState.editingSourceCGImage
                }
              }()

              self.commit {
                $0.loadedState?.imageForCrop = cgImageForCrop
              }

            }

          }

        }

      }

    }
  }

  // MARK: - Functions

  /**
   Adds a new snapshot as a history.
   */
  public func takeSnapshot() {
    commit {
      $0.loadedState?.makeVersion()
    }
  }

  /**
   Reverts the current editing.
   */
  public func revertEdit() {
    _pixelengine_ensureMainThread()

    commit {
      $0.loadedState?.revertCurrentEditing()
    }
  }

  /**
   Undo editing, pulling the latest history back into the current edit.
   */
  public func undoEdit() {
    _pixelengine_ensureMainThread()

    commit {
      $0.loadedState?.undoEditing()
    }
  }

  /**
   Purges the all of the history
   */
  public func removeAllEditsHistory() {
    _pixelengine_ensureMainThread()

    commit {
      $0.loadedState?.history = []
    }
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

  public func makeRenderer() throws -> ImageRenderer {
    let stateSnapshot = state

    guard let loaded = stateSnapshot.loadedState else {
      throw EditingStackError.unableToCreateRendererInLoading
    }

    let imageSource = loaded.imageSource

    let renderer = ImageRenderer(source: imageSource, orientation: loaded.metadata.orientation)

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

  private func applyIfChanged(_ perform: (inout InoutRef<Edit>) -> Void) {
    commit {
      guard $0.loadedState != nil else {
        return
      }
      $0.map(keyPath: \.loadedState!.currentEdit, perform: perform)
    }
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

    let renderer = ImageRenderer(source: source, orientation: orientation)
    renderer.edit.modifiers = filters

    let result = try renderer.render().cgImage

    return result
  }

}

/// TODO: As possible, creates CIImage from MTLTexture
/// 16bits image can't be MTLTexture with MTKTextureLoader.
/// https://stackoverflow.com/questions/54710592/cant-load-large-jpeg-into-a-mtltexture-with-mtktextureloader
private func makeMTLTexture(from cgImage: CGImage, device: MTLDevice) throws -> MTLTexture {

  #if true
    let loader = MTKTextureLoader(device: device)
    let texture = try loader.newTexture(cgImage: cgImage, options: [:])
    return texture
  #else

    // Here does not work well.

    let textureDescriptor = MTLTextureDescriptor()

    textureDescriptor.pixelFormat = .rgba16Uint
    textureDescriptor.width = cgImage.width
    textureDescriptor.height = cgImage.height

    let texture = try device.makeTexture(descriptor: textureDescriptor).unwrap(
      orThrow: "Failed to create MTLTexture"
    )

    let context = try CGContext.makeContext(for: cgImage)
      .perform { context in
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(cgImage.height))
        context.concatenate(flip)
        context.draw(
          cgImage,
          in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
      }

    let data = try context.data.unwrap()

    texture.replace(
      region: MTLRegionMake2D(0, 0, cgImage.width, cgImage.height),
      mipmapLevel: 0,
      withBytes: data,
      bytesPerRow: 8 * cgImage.width
    )

    return texture
  #endif

}

private func _makeCIImage(
  source cgImage: CGImage,
  orientation: CGImagePropertyOrientation,
  device: MTLDevice?,
  usesMTLTexture: Bool
) -> CIImage {

  let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()

  func createFromCGImage() -> CIImage {
    return CIImage(
      cgImage: cgImage
    )
    .oriented(orientation)
  }

  func createFromMTLTexture(device: MTLDevice) throws -> CIImage {
    let thumbnailTexture = try makeMTLTexture(
      from: cgImage,
      device: device
    )

    let ciImage = try CIImage(
      mtlTexture: thumbnailTexture,
      options: [.colorSpace: colorSpace]
    )
    .map {
      $0.transformed(by: .init(scaleX: 1, y: -1))
    }.map {
      $0.transformed(by: .init(translationX: 0, y: $0.extent.height))
    }
    .map {
      $0.oriented(orientation)
    }
    .unwrap()

    EngineLog.debug(.stack, "Load MTLTexture")

    return ciImage
  }

  if usesMTLTexture {
    assert(device != nil)
  }

  if usesMTLTexture, let device = device {

    do {
      // TODO: As possible, creates CIImage from MTLTexture
      // 16bits image can't be MTLTexture with MTKTextureLoader.
      // https://stackoverflow.com/questions/54710592/cant-load-large-jpeg-into-a-mtltexture-with-mtktextureloader
      return try createFromMTLTexture(device: device)
    } catch {
      EngineLog.debug(
        .stack,
        "Unable to create MTLTexutre, fallback to CIImage from CGImage.\n\(cgImage)"
      )

      return createFromCGImage()
    }
  } else {

    if usesMTLTexture, device == nil {
      EngineLog.error(
        .stack,
        "MTLDevice not found, fallback to using CGImage to create CIImage."
      )
    }

    return createFromCGImage()
  }

}
