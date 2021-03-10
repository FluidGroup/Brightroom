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
        
    /**
     A Boolean value that indicates whether the image is currently loading for editing.
     */
    public fileprivate(set) var isLoading = true
        
    public var imageSize: PixelSize {
      initialEditing.imageSize
    }
            
    private let initialEditing: Edit
        
    public fileprivate(set) var hasStartedEditing = false
    
    public fileprivate(set) var history: [Edit] = []
    
    public fileprivate(set) var currentEdit: Edit
    
    fileprivate(set) var previewImageProvider: CGDataProvider?
    fileprivate(set) var editableImageProvider: CGDataProvider?
    
    public fileprivate(set) var previewImage: CIImage?
    
    /**
     An original image
     Can be used in cropping
     */
    public fileprivate(set) var targetOriginalSizeImage: CIImage?
        
    /**
     An image that cropped but not effected.
     */
    public fileprivate(set) var previewCroppedOriginalImage: CIImage?
    
    /**
     An image that applied editing and optimized for previewing.
     */
    public fileprivate(set) var previewCroppedAndEffectedImage: CIImage?
    
    public fileprivate(set) var cubeFilterPreviewSourceImage: CIImage?
    
    public fileprivate(set) var previewColorCubeFilters: [PreviewFilterColorCube] = []
    
    public var canUndo: Bool {
      return history.count > 0
    }
        
    public var isDirty: Bool {
      return currentEdit != initialEditing
    }
    
    init(initialEdit: Edit) {
      self.initialEditing = initialEdit
      self.currentEdit = initialEdit
    }
        
    static func makeVersion(ref: InoutRef<Self>) {
      ref.history.append(ref.currentEdit)
    }
    
    static func revertCurrentEditing(ref: InoutRef<Self>) {
      ref.currentEdit = ref.history.last ?? ref.initialEditing
    }
        
    static func undoEditing(ref: InoutRef<Self>) {
      ref.currentEdit = ref.history.popLast() ?? ref.initialEditing
    }
    
  }

  // MARK: - Stored Properties
  
  public let store: DefaultStore

  public let imageSource: ImageProvider

  public let preferredPreviewSize: PixelSize
  
  private let colorCubeFilters: [FilterColorCube]
          
  private let queue = DispatchQueue(
    label: "me.muukii.PixelEngine",
    qos: .default,
    attributes: []
  )
  
  private var subscriptions = Set<VergeAnyCancellable>()
  private var imageProviderSubscription: VergeAnyCancellable?
  
  private let modifyCrop: (CIImage?, inout EditingCrop) -> Void

  // MARK: - Initializers

  public init(
    source: ImageProvider,
    previewSize: PixelSize,
    colorCubeStorage: ColorCubeStorage = .default,
    modifyCrop: @escaping (CIImage?, inout EditingCrop) -> Void = { _, _ in }
    ) {
        
    self.modifyCrop = modifyCrop
    self.store = .init(
      initialState: .init(
        initialEdit: Edit(imageSize: source.state.imageSize)
      )
    )
    
    self.colorCubeFilters = colorCubeStorage.filters
    self.imageSource = source
    self.preferredPreviewSize = previewSize
        
    applyIfChanged { (s) in

    }
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
          
    store.add(middleware: .unifiedMutation({ (ref) in
      // TODO:
    }))
    
    sinkState(queue: .asyncSerialBackground) { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.targetOriginalSizeImage) { image in
        
        guard let image = image else { return }
        
//        ImageTool.makeResizedCIImage(provider: CGDataProvider(data: image., targetPixelSize: <#T##PixelSize#>)
                        
        let smallSizeImage = ImageTool.makeNewResizedCIImage(
          to: Geometry.sizeThatAspectFit(
            aspectRatio: image.extent.size,
            boundingSize: CGSize(
              width: 120,
              height: 120
            )
          ),
          from: image
        )!
          
        self.commit {
          $0.cubeFilterPreviewSourceImage = smallSizeImage
          
          $0.previewColorCubeFilters = self.colorCubeFilters.concurrentMap {
            let r = PreviewFilterColorCube(sourceImage: smallSizeImage, filter: $0)
            return r
          }
        }
        
      }
      
      state.ifChanged(\.currentEdit, \.previewCroppedOriginalImage) { currentEdit, croppedTargetImage in
        if let croppedTargetImage = croppedTargetImage {
          self.updatePreviewImage(from: currentEdit, image: croppedTargetImage)
        }
      }
      
      state.ifChanged(\.currentEdit.crop, \.targetOriginalSizeImage) { _cropRect, targetImage in
        
        if let targetImage = targetImage {
                   
          let croppedImage = targetImage
            .cropped(to: _cropRect)
          
          let result = ImageTool.makeNewResizedCIImage(
            to: Geometry.sizeThatAspectFit(
              aspectRatio: croppedImage.extent.size,
              boundingSize: self.preferredPreviewSize.cgSize
            ),
            from: croppedImage
          )
          
          self.commit {
            $0.previewCroppedOriginalImage = result
          }
        }
        
      }
      
    }
    .store(in: &subscriptions)
    
    
    /**
     Start downloading image
     */
    imageSource.start()
    imageProviderSubscription = imageSource.sinkState(queue: .asyncSerialBackground) { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.loadedImage) { image in
         
        guard let image = image else {
          // FIXME:
//          self.applyIfChanged {
//            self.modifyCrop(nil, &$0.crop)
//          }
//          self.takeSnapshot()
          return
        }
        self.commit { s in
          
          switch image {
          case .preview(let image):
            s.isLoading = true
            s.previewImageProvider = image
          case .editable(let image):
            s.isLoading = false
            s.editableImageProvider = image
//            self.modifyCrop(image, &s.currentEdit.crop)
//            s.withType { (type, ref) -> Void in
//              type.makeVersion(ref: ref)
//            }
            
            // FIXME:
            
            self.imageProviderSubscription?.cancel()
          }
                                       
        }
      }
      
    }

          
  }
  
  // MARK: - Functions
  
  func hoge() {
    
    
    
  }

  /**
   Adds a new snapshot as a history.
   */
  public func takeSnapshot() {
        
    commit {
      $0.withType { (type, ref) -> Void in
        type.makeVersion(ref: ref)
      }
    }
  }

  /**
   Reverts the current editing.
   */
  public func revertEdit() {
    
    _pixelengine_ensureMainThread()
    
    commit {
      $0.withType { (type, ref) -> Void in
        type.revertCurrentEditing(ref: ref)
      }
    }
    
  }

  /**
   Undo editing, pulling the latest history back into the current edit.
   */
  public func undoEdit() {
    
    _pixelengine_ensureMainThread()
        
    commit {
      $0.withType { (type, ref) -> Void in
        type.undoEditing(ref: ref)
      }
    }
    
  }

  /**
   Purges the all of the history
   */
  public func removeAllEditsHistory() {
    
    _pixelengine_ensureMainThread()
    
    commit {
      $0.history = []
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

  public func set(blurringMaskPaths: [DrawnPathInRect]) {
    
    _pixelengine_ensureMainThread()

    applyIfChanged {
      $0.drawings.blurredMaskPaths = blurringMaskPaths
    }
  }

  public func makeRenderer() -> ImageRenderer {
    
    _pixelengine_ensureMainThread()
    
    guard let targetImage = state.targetOriginalSizeImage else {
      preconditionFailure("Image not loaded. You want to catch this error, please file an issue in GitHub.")
    }
        
    let renderer = ImageRenderer(source: targetImage)

    // TODO: Clean up ImageRenderer.Edit
    
    let edit = state.currentEdit

    renderer.edit.croppingRect = edit.crop
    renderer.edit.drawer = [
      BlurredMask(paths: edit.drawings.blurredMaskPaths)
    ]

    renderer.edit.modifiers = edit.makeFilters()

    return renderer
  }

  private func applyIfChanged(_ perform: (inout InoutRef<Edit>) -> Void) {
    
    commit {
      $0.map(keyPath: \.currentEdit, perform: perform)
    }
  
  }

  private func updatePreviewImage(from edit: Edit, image: CIImage) {
    
    let filters = edit
      .makeFilters()
    
    let result = filters.reduce(image) { (image, filter) -> CIImage in
      filter.apply(to: image, sourceImage: image)
    }
    
    commit {
      $0.previewCroppedAndEffectedImage = result
    }

    // TODO: Ignore vignette and blur (convolutions)
//    adjustmentImage = filters.reduce(source.image) { (image, filter) -> CIImage in
//      filter.apply(to: image, sourceImage: source.image).insertingIntermediateIfCanUse()
//    }

  }

}

extension EditingStack {

  // TODO: Consider more effective shape
  public struct Edit : Equatable {
    
    func makeFilters() -> [Filtering] {
      return filters.makeFilters()
    }
  
    public var imageSize: PixelSize {
      crop.imageSize
    }
        
    public var crop: EditingCrop
    public var filters: Filters = .init()
    public var drawings: Drawings = .init()
          
    init(imageSize: PixelSize) {
      self.crop = .init(imageSize: imageSize, cropRect: .init(origin: .zero, size: imageSize))
    }
    
    public struct Drawings: Equatable {
      // TODO: Remove Rect from DrawnPath
      public var blurredMaskPaths: [DrawnPathInRect] = []
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
            
    public struct Filters : Equatable {
      
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
        ] as [Optional<Filtering>])
        .compactMap { $0 }
      }
    }
    
  }

}

extension CIImage {
  
  func cropped(to _cropRect: EditingCrop) -> CIImage {
        
    let targetImage = self
    var cropRect = _cropRect.cropExtent.cgRect
    
    assert(_cropRect.imageSize == .init(image: targetImage))
    
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
