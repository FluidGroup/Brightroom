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
import UIKit
import Verge

import SwiftUI

@available(iOS 13, *)
extension EditingStack: ObservableObject {}

/**
 A stateful object that manages current editing status from original image.
 And supports rendering a result image.

 - Attension: Source text
 Please make sure of EditingStack is started state before editing in UI with calling `start()`.

 */
open class EditingStack: Equatable, StoreComponentType {
  public static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }

  public struct State: Equatable {
    public struct Loading: Equatable {}

    public struct Previewing: Equatable {
      fileprivate(set) var previewImageProvider: ImageSource?
      public let metadata: ImageProvider.State.ImageMetadata
      /**
       An image for placeholder, not editable.
       Uses in waiting for loading an editable image.
       */
      public fileprivate(set) var placeholderImage: CIImage?
    }

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
        editingCroppedImage: CIImage,
        editingCroppedPreviewImage: CIImage,
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
        self.editingCroppedImage = editingCroppedImage
        self.editingCroppedPreviewImage = editingCroppedPreviewImage
        self.previewColorCubeFilters = previewColorCubeFilters
      }

      fileprivate let editableImageProvider: ImageSource
      public let metadata: ImageProvider.State.ImageMetadata
      private let initialEditing: Edit
      public fileprivate(set) var currentEdit: Edit

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

      /**
       An image that cropped but not effected.
       */
      public fileprivate(set) var editingCroppedImage: CIImage

      /**
       An image that applied editing and optimized for previewing.
       */
      public fileprivate(set) var editingCroppedPreviewImage: CIImage

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

        guard history.last == currentEdit else {
          return true
        }

        return false
      }
    }

    public fileprivate(set) var hasStartedEditing = false
    /**
     A Boolean value that indicates whether the image is currently loading for editing.
     */
    public var isLoading: Bool {
      loadedState == nil
    }

    fileprivate(set) var loadingState: Loading = .init()
    fileprivate(set) var previewingState: Previewing?
    fileprivate(set) var loadedState: Loaded?

    init() {
//      initialEditing = initialEdit
//      currentEdit = initialEdit
    }

//    static func makeVersion(ref: InoutRef<Self>) {
//      ref.history.append(ref.currentEdit)
//    }
//
//    static func revertCurrentEditing(ref: InoutRef<Self>) {
//      ref.currentEdit = ref.history.last ?? ref.initialEditing
//    }
//
//    static func undoEditing(ref: InoutRef<Self>) {
//      ref.currentEdit = ref.history.popLast() ?? ref.initialEditing
//    }
  }

  // MARK: - Stored Properties

  public let store: DefaultStore

  public let imageProvider: ImageProvider

  public let previewMaxPixelSize: CGFloat

  private let colorCubeFilters: [FilterColorCube]

  private let queue = DispatchQueue(
    label: "me.muukii.PixelEngine",
    qos: .default,
    attributes: []
  )

  private var subscriptions = Set<VergeAnyCancellable>()
  private var imageProviderSubscription: VergeAnyCancellable?

  private let cropModifier: CropModifier

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
    previewMaxPixelSize: CGFloat = 1000,
    colorCubeStorage: ColorCubeStorage = .default,
    cropModifier: CropModifier = .init(modify: { _, _ in })
  ) {
    self.cropModifier = cropModifier
    store = .init(
      initialState: .init(
      )
    )

    colorCubeFilters = colorCubeStorage.filters
    self.imageProvider = imageProvider
    self.previewMaxPixelSize = previewMaxPixelSize

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

    /*
     store.sinkState(queue: .asyncSerialBackground) { [weak self] (state: Changes<State>) in

       guard let self = self else { return }

       self.commit { (modifyingState: inout InoutRef<State>) in

         state.ifChanged(\.thumbnailImage) { image in

           guard let image = image else { return }

           modifyingState.previewColorCubeFilters = self.colorCubeFilters.concurrentMap {
             let r = PreviewFilterColorCube(sourceImage: image, filter: $0)
             return r
           }

         }

         state.ifChanged(\.currentEdit.crop, \.editingSourceImage) { crop, editingSourceImage in

           guard let editingSourceImage = editingSourceImage else { return }

           let result = Self._createPreviewImage(
             targetImage: editingSourceImage,
             crop: crop,
             editingImageMaxPixelSize: self.editingImageMaxPixelSize,
             previewMaxPixelSize: self.previewMaxPixelSize
           )

           modifyingState.editingCroppedImage = result
         }

         state.ifChanged(\.currentEdit, \.editingCroppedImage, \.editingSourceImage) { currentEdit, editingCroppedImage, editingSourceImage in

           let filters = currentEdit
             .makeFilters()

           if let croppedTargetImage = editingCroppedImage {

             let result = filters.reduce(croppedTargetImage) { (image, filter) -> CIImage in
               filter.apply(to: image, sourceImage: image)
             }

             modifyingState.editingCroppedPreviewImage = result
           }

           if let image = editingSourceImage {

             let result = filters.reduce(image) { (image, filter) -> CIImage in
               filter.apply(to: image, sourceImage: image)
             }

             modifyingState.editingPreviewImage = result
           }

         }

       }

     }
     .store(in: &subscriptions)
      */

    /**
     Start downloading image
     */
    imageProvider.start()
    imageProviderSubscription = imageProvider
      .sinkState(queue: .asyncSerialBackground) { [weak self] (state: Changes<ImageProvider.State>) in

        guard let self = self else { return }

        state.ifChanged(\.loadedImage) { image in

          guard let image = image else {
//            self.commit {
//              self._commit_adjustCropExtent(image: nil, ref: $0)
//            }
            return
          }
          self.commit { (s: inout InoutRef<State>) in

            switch image {
            case let .preview(image, metadata):

              s.previewingState = .init(
                previewImageProvider: image,
                metadata: metadata,
                placeholderImage: CIImage(cgImage: image.loadThumbnailCGImage(maxPixelSize: 1280)).oriented(metadata.orientation)
              )

            case let .editable(image, metadata):
              
              let editingSourceImage = CIImage(cgImage: image.loadThumbnailCGImage(maxPixelSize: self.editingImageMaxPixelSize))
              
              let initialCrop = EditingCrop(
                imageSize: metadata.imageSize
              )
              
              let initialEdit = Edit(crop: initialCrop)
              
              let editingCroppedImage = Self._createPreviewImage(
                targetImage: editingSourceImage,
                crop: initialEdit.crop,
                editingImageMaxPixelSize: self.editingImageMaxPixelSize,
                previewMaxPixelSize: self.previewMaxPixelSize
              )

              s.loadedState = .init(
                editableImageProvider: image,
                metadata: metadata,
                initialEditing: initialEdit,
                currentEdit: initialEdit,
                thumbnailImage: CIImage(cgImage: image.loadThumbnailCGImage(maxPixelSize: 180)).oriented(metadata.orientation),
                editingSourceImage: editingSourceImage,
                editingPreviewImage: initialEdit.filters.apply(to: editingSourceImage),
                editingCroppedImage: editingCroppedImage,
                editingCroppedPreviewImage: initialEdit.filters.apply(to: editingCroppedImage)
              )

              self.imageProviderSubscription?.cancel()
            }
          }
        }
      }
  }

  // MARK: - Functions

  /// Make an image that cropped and resized for previewing
  private static func _createPreviewImage(
    targetImage: CIImage,
    crop: EditingCrop,
    editingImageMaxPixelSize: CGFloat,
    previewMaxPixelSize: CGFloat
  ) -> CIImage {
    /**
     Crop image
     */

    let croppedImage = targetImage
      .cropped(to: crop.scaled(maxPixelSize: editingImageMaxPixelSize))

    /**
     Remove the offset from cropping
     */

    let fixedOriginImage = croppedImage.transformed(by: .init(
      translationX: -croppedImage.extent.origin.x,
      y: -croppedImage.extent.origin.y
    ))

    assert(fixedOriginImage.extent.origin == .zero)

    /**
     Make the image small
     */

    let targetSize = fixedOriginImage.extent.size.scaled(maxPixelSize: previewMaxPixelSize)

    // FIXME: depending the scale, the scaled image includes alpha pixel in the edges.

    let scale = max(
      targetSize.width / croppedImage.extent.width,
      targetSize.height / croppedImage.extent.height
    )

    let zoomedImage = croppedImage
      .transformed(
        by: .init(
          scaleX: scale,
          y: scale
        ),
        highQualityDownsample: true
      )

    /**
     Remove the offset from transforming
     Plus insert intermediate
     */

    let translated = zoomedImage
      .transformed(by: .init(
        translationX: zoomedImage.extent.origin.x,
        y: zoomedImage.extent.origin.y
      ))
      .insertingIntermediate(cache: true)

    EngineLog.debug("[Preview-Crop] \(crop.cropExtent) -> \(translated.extent)")

    return translated
  }

  /*
     func _commit_adjustCropExtent(image: CIImage?, ref: InoutRef<State>) {

       let imageSize = ref.imageSize
       var crop = EditingCrop(imageSize: ref.imageSize)

       let actualSizeFromDownsampledImage = image.map { image -> CIImage in
         let scaled = image.transformed(
           by: .init(
             scaleX: image.extent.width < imageSize.width ? imageSize.width / image.extent.width : 1,
             y: image.extent.height < imageSize.width ? imageSize.height / image.extent.height : 1
           )
         )

         let translated = scaled.transformed(by: .init(
           translationX: scaled.extent.origin.x,
           y: scaled.extent.origin.y
         ))

         return translated
       }

       cropModifier.run(actualSizeFromDownsampledImage, editingCrop: &crop)

       ref.loaded?.currentEdit.crop = crop

       // FIXME:
   //    ref.withType { (type, ref) -> Void in
   //      type.makeVersion(ref: ref)
   //    }
     }
      */

  /**
   Adds a new snapshot as a history.
   */
  public func takeSnapshot() {
    commit { _ in
      // FIXME:
//      $0.withType { (type, ref) -> Void in
//        type.makeVersion(ref: ref)
//      }
    }
  }

  /**
   Reverts the current editing.
   */
  public func revertEdit() {
    _pixelengine_ensureMainThread()

    commit { _ in
      // FIXME:
//      $0.withType { (type, ref) -> Void in
//        type.revertCurrentEditing(ref: ref)
//      }
    }
  }

  /**
   Undo editing, pulling the latest history back into the current edit.
   */
  public func undoEdit() {
    _pixelengine_ensureMainThread()

    commit { _ in
      // FIXME:
//      $0.withType { (type, ref) -> Void in
//        type.undoEditing(ref: ref)
//      }
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

  public func makeRenderer() -> ImageRenderer? {
    let stateSnapshot = state

    guard let loaded = stateSnapshot.loadedState else {
      return nil
    }

    let imageSource = loaded.editableImageProvider

    let renderer = ImageRenderer(source: imageSource)

    // TODO: Clean up ImageRenderer.Edit

    let edit = loaded.currentEdit

    renderer.edit.croppingRect = edit.crop
    renderer.edit.drawer = [
      BlurredMask(paths: edit.drawings.blurredMaskPaths),
    ]

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

extension EditingStack {
  // TODO: Consider more effective shape
  public struct Edit: Equatable {
    func makeFilters() -> [Filtering] {
      return filters.makeFilters()
    }

    public var imageSize: CGSize {
      crop.imageSize
    }

    public var crop: EditingCrop
    public var filters: Filters = .init()
    public var drawings: Drawings = .init()

    init(crop: EditingCrop) {
      self.crop = crop
    }

    public struct Drawings: Equatable {
      // TODO: Remove Rect from DrawnPath
      public var blurredMaskPaths: [DrawnPath] = []
    }

    //
    //    public struct Light {
    //
    //    }
    //
    //    public struct Color {
    //
    //    }
    //
    //    public struct Effects {
    //
    //    }
    //
    //    public struct Detail {
    //
    //    }

    public struct Filters: Equatable {
      public var colorCube: FilterColorCube?

      public var brightness: FilterBrightness?
      public var contrast: FilterContrast?
      public var saturation: FilterSaturation?
      public var exposure: FilterExposure?

      public var highlights: FilterHighlights?
      public var shadows: FilterShadows?

      public var temperature: FilterTemperature?

      public var sharpen: FilterSharpen?
      public var gaussianBlur: FilterGaussianBlur?
      public var unsharpMask: FilterUnsharpMask?

      public var vignette: FilterVignette?
      public var fade: FilterFade?

      func makeFilters() -> [Filtering] {
        return ([
          // Before
          exposure,
          brightness,
          temperature,
          highlights,
          shadows,
          saturation,
          contrast,
          colorCube,

          // After
          sharpen,
          unsharpMask,
          gaussianBlur,
          fade,
          vignette,
        ] as [Filtering?])
          .compactMap { $0 }
      }
      
      func apply(to ciImage: CIImage) -> CIImage {
        makeFilters().reduce(ciImage) { (image, filter) -> CIImage in
          filter.apply(to: image, sourceImage: image)
        }
      }
    }
  }
}

extension CIImage {
  func cropped(to _cropRect: EditingCrop) -> CIImage {
    let targetImage = self
    var cropRect = _cropRect.cropExtent

    cropRect.origin.y = targetImage.extent.height - cropRect.minY - cropRect.height

    let croppedImage = targetImage
      .cropped(to: cropRect)

    return croppedImage
  }
}

extension Array {
  fileprivate func concurrentMap<U>(_ transform: (Element) -> U) -> [U] {
    var buffer = [U?].init(repeating: nil, count: count)

    buffer.withUnsafeMutableBufferPointer { (targetBuffer) -> Void in

      self.withUnsafeBufferPointer { (sourceBuffer) -> Void in

        DispatchQueue.concurrentPerform(iterations: count) { i in
          let sourcePointer = sourceBuffer.baseAddress!.advanced(by: i)
          let r = transform(sourcePointer.pointee)
          let targetPointer = targetBuffer.baseAddress!.advanced(by: i)
          targetPointer.pointee = r
        }
      }
    }

    return buffer.compactMap { $0 }
  }
}

import Vision

extension EditingStack {
  public struct CropModifier {
    private let modifier: (CIImage?, inout EditingCrop) -> Void

    public init(modify: @escaping (CIImage?, inout EditingCrop) -> Void) {
      modifier = modify
    }

    func run(_ image: CIImage?, editingCrop: inout EditingCrop) {
      modifier(image, &editingCrop)
    }

    public static func faceDetection() -> Self {
      return .init { image, crop in

        // FIXME:

        guard let image = image else {
          return
        }

        let request = VNDetectFaceRectanglesRequest { request, error in
          for observation in request.results as! [VNFaceObservation] {
            print(observation)
          }
        }

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
          try handler.perform([request])
        } catch {
          print(error)
        }
      }
    }
  }
}
