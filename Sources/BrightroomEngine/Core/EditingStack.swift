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
  public static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }

  public struct State: Equatable {
    public struct Loading: Equatable {}

    public struct Loaded: Equatable {
      init(
        editableImageProvider: ImageSource,
        metadata: ImageProvider.State.ImageMetadata,
        initialEditing: EditingStack.Edit,
        currentEdit: EditingStack.Edit,
        history: [EditingStack.Edit] = [],
        thumbnailImage: CIImage,
        editingSourceImage: CIImage,
        editingPreviewImage: CIImage,
        previewColorCubeFilters: [PreviewFilterColorCube] = []
      ) {
        self.editableImageProvider = editableImageProvider
        self.metadata = metadata
        self.initialEditing = initialEditing
        self.currentEdit = currentEdit
        self.history = history
        self.thumbnailImage = thumbnailImage
        self.editingSourceImage = editingSourceImage
        self.editingPreviewImage = editingPreviewImage
        self.previewColorCubeFilters = previewColorCubeFilters
      }

      fileprivate let editableImageProvider: ImageSource
      public let metadata: ImageProvider.State.ImageMetadata
      private let initialEditing: Edit

      public fileprivate(set) var currentEdit: Edit {
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

      /**
       An original image
       Can be used in cropping
       */
      public fileprivate(set) var editingSourceImage: CIImage

      public fileprivate(set) var editingPreviewImage: CIImage

      public fileprivate(set) var previewColorCubeFilters: [PreviewFilterColorCube] = []

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

  public let imageProvider: ImageProvider

  private let colorCubeFilters: [FilterColorCube]

  private let queue = DispatchQueue(
    label: "me.muukii.PixelEngine",
    qos: .default,
    attributes: []
  )

  private var subscriptions = Set<VergeAnyCancellable>()
  private var imageProviderSubscription: VergeAnyCancellable?

  public var cropModifier: CropModifier

  private let editingImageMaxPixelSize: CGFloat = 2560

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
    cropModifier: CropModifier = .init(modify: { _, c, completion in completion(c) })
  ) {
    self.cropModifier = cropModifier
    store = .init(
      initialState: .init()
    )

    colorCubeFilters = colorCubeStorage.filters
    self.imageProvider = imageProvider

    #if DEBUG
      sinkState(queue: .asyncSerialBackground) { state in
        //      print(state.primitive)
      }
      .store(in: &subscriptions)
    #endif
  }

  /**
   EditingStack awakes from cold state.
   */
  public func start() {
    _pixelengine_ensureMainThread()

    guard state.hasStartedEditing == false else {
      return
    }

    commit {
      $0.hasStartedEditing = true
    }

    store.sinkState(queue: .asyncSerialBackground) { [weak self] (state: Changes<State>) in
      guard let self = self else { return }
      self.receive(newState: state)
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

        guard let self = self else { return }

        state.ifChanged(\.loadedImage) { image in

          guard let image = image else {
            return
          }

          switch image {
          case let .editable(image, metadata):

            let device = MTLCreateSystemDefaultDevice()!

            let thumbnailCGImage = image.loadThumbnailCGImage(maxPixelSize: 180)

            let editingSourceCGImage = image.loadThumbnailCGImage(
              maxPixelSize: self.editingImageMaxPixelSize
            )

            let colorSpace = editingSourceCGImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()

            assert(editingSourceCGImage.colorSpace != nil)

            /// resized
            let _editingSourceImage: CIImage = {

              // TODO: As possible, creates CIImage from MTLTexture
              // 16bits image can't be MTLTexture with MTKTextureLoader.
              // https://stackoverflow.com/questions/54710592/cant-load-large-jpeg-into-a-mtltexture-with-mtktextureloader

              do {

                let editingSourceTexture = try makeMTLTexture(
                  from: editingSourceCGImage,
                  device: device
                )

                let ciImage = try CIImage(
                  mtlTexture: editingSourceTexture,
                  options: [.colorSpace: colorSpace]
                )
                .map {
                  $0.transformed(by: .init(scaleX: 1, y: -1))
                }.map {
                  $0.transformed(by: .init(translationX: 0, y: $0.extent.height))
                }
                .map {
                  $0.oriented(metadata.orientation)
                }
                .unwrap()

                EngineLog.debug(.stack, "Load MTLTexture for editing-source")

                return ciImage

              } catch {

                EngineLog.debug(.stack, "Unable to create MTLTexutre, fallback to CIImage from CGImage.\n\(editingSourceCGImage)")

                return CIImage(
                  cgImage: editingSourceCGImage
                )
                .oriented(metadata.orientation)

              }

            }()

            let _thumbnailImage: CIImage = {

              // TODO: As possible, creates CIImage from MTLTexture
              // 16bits image can't be MTLTexture with MTKTextureLoader.
              // https://stackoverflow.com/questions/54710592/cant-load-large-jpeg-into-a-mtltexture-with-mtktextureloader

              do {

                let thumbnailTexture = try makeMTLTexture(
                  from: thumbnailCGImage,
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
                  $0.oriented(metadata.orientation)
                }
                .unwrap()

                EngineLog.debug(.stack, "Load MTLTexture for thumbnail")

                return ciImage

              } catch {

                EngineLog.debug(.stack, "Unable to create MTLTexutre, fallback to CIImage from CGImage.\n\(thumbnailCGImage)")

                return CIImage(
                  cgImage: thumbnailCGImage
                )
                .oriented(metadata.orientation)

              }
            }()

            self.adjustCropExtent(
              image: _editingSourceImage,
              imageSize: metadata.imageSize,
              completion: { [weak self] crop in

                guard let self = self else { return }

                self.commit { (s: inout InoutRef<State>) in
                  assert(
                    (_editingSourceImage.extent.width > _editingSourceImage.extent.height)
                      == (metadata.imageSize.width > metadata.imageSize.height)
                  )

                  let initialEdit = Edit(crop: crop)

                  s.loadedState = .init(
                    editableImageProvider: image,
                    metadata: metadata,
                    initialEditing: initialEdit,
                    currentEdit: initialEdit,
                    thumbnailImage: _thumbnailImage,
                    editingSourceImage: _editingSourceImage,
                    editingPreviewImage: initialEdit.filters.apply(to: _editingSourceImage)
                  )

                  self.imageProviderSubscription?.cancel()
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

  private func receive(newState state: Changes<State>) {
    commit { (modifyingState: inout InoutRef<State>) in

      if let loadedState = state._beta_map(\.loadedState) {
        modifyingState.map(keyPath: \.loadedState!) { (nextState) -> Void in

          loadedState.ifChanged(\.thumbnailImage) { image in

            nextState.previewColorCubeFilters = self.colorCubeFilters.concurrentMap {
              let r = PreviewFilterColorCube(sourceImage: image, filter: $0)
              return r
            }
          }

        }
      }
    }
  }

  // MARK: - Functions

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

    let imageSource = loaded.editableImageProvider

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
}

/**
 TODO: As possible, creates CIImage from MTLTexture
 16bits image can't be MTLTexture with MTKTextureLoader.
 https://stackoverflow.com/questions/54710592/cant-load-large-jpeg-into-a-mtltexture-with-mtktextureloader
 */
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
