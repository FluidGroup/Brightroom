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

import Foundation
import Verge

/**
 A stateful object that manages current editing status from original image.
 And supports rendering a result image.
 */
open class EditingStack: Equatable, StoreComponentType {
  
  public static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }
    
  public struct State: Equatable {
        
    public let imageSize: ImageSize
    
    public var aspectRatio: CGSize {
      currentEdit.cropRect?.size ?? imageSize.aspectRatio
    }
    
    public fileprivate(set) var hasStartedEditing = false
    
    public fileprivate(set) var history: [Edit] = []
    
    public fileprivate(set) var currentEdit: Edit = .init()
    
    public fileprivate(set) var isLoading = true
        
    /**
     An original image
     */
    public fileprivate(set) var targetImage: CIImage?
        
    /**
     An image that cropped but not effected.
     */
    public fileprivate(set) var croppedTargetImage: CIImage?
    
    /**
     An image that applied editing and optimized for previewing.
     */
    public fileprivate(set) var previewImage: CIImage?
    
    public fileprivate(set) var cubeFilterPreviewSourceImage: CIImage?
    
    public fileprivate(set) var previewColorCubeFilters: [PreviewFilterColorCube] = []
    
    public var canUndo: Bool {
      return history.count > 0
    }
        
    public var isDirty: Bool {
      return currentEdit != .zero
    }
        
    static func makeVersion(ref: InoutRef<Self>) {
      ref.history.append(ref.currentEdit)
    }
    
  }

  // MARK: - Stored Properties
  
  public let store: DefaultStore

  public let source: ImageProvider

  public let preferredPreviewSize: CGSize

  public let targetScreenScale: CGFloat
  
  private let colorCubeFilters: [FilterColorCube]
          
  private let queue = DispatchQueue(
    label: "me.muukii.PixelEngine",
    qos: .default,
    attributes: []
  )
  
  private var subscriptions = Set<VergeAnyCancellable>()

  // MARK: - Initializers

  public init(
    source: ImageProvider,
    previewSize: CGSize,
    colorCubeStorage: ColorCubeStorage = .default,
    screenScale: CGFloat = UIScreen.main.scale
    ) {
    
    self.store = .init(initialState: .init(imageSize: source.state.imageSize))
    self.colorCubeFilters = colorCubeStorage.filters
    self.source = source

    self.targetScreenScale = screenScale
    self.preferredPreviewSize = previewSize
        
    initialCrop()
    takeSnapshot()
    removeAllEditsHistory()
    
  }
  
  public func start() {
    
    ensureMainThread()
    
    guard state.hasStartedEditing == false else {
      return
    }
    
    commit {
      $0.hasStartedEditing = true
    }
    
    source.start()
    
    store.add(middleware: .unifiedMutation({ (ref) in
      // TODO:
    }))
    
    sinkState(queue: .asyncSerialBackground) { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.targetImage) { image in
        
        guard let image = image else { return }
        
        let smallSizeImage = ImageTool.makeNewResidedCIImage(
          to: Geometry.sizeThatAspectFit(
            aspectRatio: CGSize(width: 1, height: 1),
            boundingSize: CGSize(
              width: 60 * self.targetScreenScale,
              height: 60 * self.targetScreenScale
            )
          ),
          from: image
        ).map {
          $0.transformed(
            by: .init(
              translationX: -$0.extent.origin.x,
              y: -$0.extent.origin.y
            )
          )
        }!
          
        self.commit {
          $0.cubeFilterPreviewSourceImage = smallSizeImage
          
          $0.previewColorCubeFilters = self.colorCubeFilters.concurrentMap {
            let r = PreviewFilterColorCube(sourceImage: smallSizeImage, filter: $0)
            return r
          }
        }
        
      }
      
      state.ifChanged(\.currentEdit, \.croppedTargetImage) { currentEdit, croppedTargetImage in
        if let croppedTargetImage = croppedTargetImage {
          self.updatePreviewImage(from: currentEdit, image: croppedTargetImage)
        }
      }
      
      state.ifChanged(\.currentEdit.cropRect, \.targetImage) { cropRect, targetImage in
        
        if let targetImage = targetImage {
          
          // TODO: ?? targetImage.extent
          var cropRect = cropRect ?? targetImage.extent
          
          cropRect.origin.y = targetImage.extent.height - cropRect.minY - cropRect.height
          
          let croppedImage = targetImage
            .cropped(to: cropRect)
          
          let result = ImageTool.makeNewResidedCIImage(
            to: Geometry.sizeThatAspectFit(
              aspectRatio: croppedImage.extent.size,
              boundingSize: CGSize(
                width: self.preferredPreviewSize.width * self.targetScreenScale,
                height: self.preferredPreviewSize.height * self.targetScreenScale
              )
            ),
            from: croppedImage
          )
          
          self.commit {
            $0.croppedTargetImage = result
          }
        }
        
      }
      
    }
    .store(in: &subscriptions)
        
    source.sinkState { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.currentImage) { image in
        guard let image = image else { return }
        self.commit {
          $0.isLoading = !image.isEditable
          $0.targetImage = image.image
        }
      }
      
    }
    .store(in: &subscriptions)
        
    self.initialCrop()
  
  }

  open func initialCrop() {
  }

  // MARK: - Functions

  /**
   Adds a new snapshot as a history.
   */
  public func takeSnapshot() {
    
    ensureMainThread()
    
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
    
    ensureMainThread()
    
    commit {
      $0.currentEdit = $0.history.last ?? .init()
    }
    
  }

  /**
   Undo editing, pulling the latest history back into the current edit.
   */
  public func undoEdit() {
    
    ensureMainThread()
    
    commit {
      $0.currentEdit = $0.history.popLast() ?? .init()
    }
  }

  /**
   Purges the all of the history
   */
  public func removeAllEditsHistory() {
    
    ensureMainThread()
    
    commit {
      $0.history = []
    }
  }

  public func set(filters: (inout Edit.Filters) -> Void) {
    
    ensureMainThread()
    
    applyIfChanged {
      filters(&$0.filters)
    }
  }

  public func crop(in rect: CGRect) {
    
    ensureMainThread()

    var _cropRect = rect

    _cropRect.origin.x.round(.up)
    _cropRect.origin.y.round(.up)
    _cropRect.size.width.round(.up)
    _cropRect.size.height.round(.up)

    applyIfChanged {
      $0.cropRect = _cropRect
    }
    
  }

  public func set(blurringMaskPaths: [DrawnPathInRect]) {
    
    ensureMainThread()

    applyIfChanged {
      $0.blurredMaskPaths = blurringMaskPaths
    }
  }

  public func makeRenderer() -> ImageRenderer {
    
    ensureMainThread()
    
    guard let targetImage = state.targetImage else {
      preconditionFailure("Image not loaded. You want to catch this error, please file an issue in GitHub.")
    }
        
    let renderer = ImageRenderer(source: targetImage)

    let edit = state.currentEdit

    renderer.edit.croppingRect = edit.cropRect
    renderer.edit.drawer = [
      BlurredMask(paths: edit.blurredMaskPaths)
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
      $0.previewImage = result
    }

    // TODO: Ignore vignette and blur (convolutions)
//    adjustmentImage = filters.reduce(source.image) { (image, filter) -> CIImage in
//      filter.apply(to: image, sourceImage: source.image).insertingIntermediateIfCanUse()
//    }

  }

}

open class SquareEditingStack : EditingStack {

  open override func initialCrop() {
    
    ensureMainThread()
    
    let imageSize = state.imageSize
    
    let cropRect = Geometry.rectThatAspectFit(
      aspectRatio: .init(width: 1, height: 1),
      boundingRect: .init(x: 0, y: 0, width: imageSize.pixelWidth, height: imageSize.pixelHeight)
    )
    
    crop(in: cropRect)
  }
}

private func _ratio(to: CGSize, from: CGSize) -> CGFloat {

  let _from = sqrt(pow(from.height, 2) + pow(from.width, 2))
  let _to = sqrt(pow(to.height, 2) + pow(to.width, 2))

  return _to / _from
}

extension EditingStack {

  public struct Edit : Equatable {

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

    public var cropRect: CGRect?
    public var blurredMaskPaths: [DrawnPathInRect] = []

    public var filters: Filters = .init()

    func makeFilters() -> [Filtering] {
      return filters.makeFilters()
    }
        
    static let zero: Self = .init()
  }

}

extension CIImage {
  
  fileprivate func insertingIntermediateIfCanUse() -> CIImage {
    if #available(iOS 12.0, *) {
      return self.insertingIntermediate(cache: true)
    } else {
      return self
    }
    
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

