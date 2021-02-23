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

public protocol EditingStackDelegate : class {
  func editingStack(_ stack: EditingStack, didUpdate imageSource: ImageSourceType)
  func editingStack(_ stack: EditingStack, didChangeCurrentEdit edit: EditingStack.Edit)
}

public extension EditingStackDelegate {
  func editingStack(_ stack: EditingStack, didUpdate imageSource: ImageSourceType) {}
}

/**
 A stateful object that manages current editing status from original image.
 And supports rendering a result image.
 */
open class EditingStack: Equatable, StoreComponentType {
  
  public static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }
    
  public struct State: Equatable {
    
    public fileprivate(set) var history: [Edit] = []
    
    public fileprivate(set) var currentEdit: Edit = .init()
    
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

  public let source: ImageSourceType

  public weak var delegate: EditingStackDelegate?

  public let preferredPreviewSize: CGSize

  public let targetScreenScale: CGFloat

  private(set) public var previewColorCubeFilters: [PreviewFilterColorCube] = []
  private var colorCubeFilters: [FilterColorCube] = []

  private(set) public var cubeFilterPreviewSourceImage: CIImage?
  
  private(set) public var previewImage: CIImage?

  private(set) public var originalPreviewImage: CIImage? {
    didSet {
      EngineLog.debug("Changed EditingStack.originalPreviewImage")
      updatePreviewImage()

    }
  }

  public var adjustmentImage: CIImage?
  
  public var aspectRatio: CGSize? {
    return originalPreviewImage?.extent.size
  }
   
  private let queue = DispatchQueue(
    label: "me.muukii.PixelEngine",
    qos: .default,
    attributes: []
  )
  
  private var subscriptions = Set<VergeAnyCancellable>()

  // MARK: - Initializers

  public init(
    source: ImageSourceType,
    previewSize: CGSize,
    colorCubeStorage: ColorCubeStorage = .default,
    screenScale: CGFloat = UIScreen.main.scale
    ) {
    
    self.store = .init(initialState: .init())

    self.source = source

    self.targetScreenScale = screenScale
    self.preferredPreviewSize = previewSize
    self.adjustmentImage = source.imageSource?.image
    
    initialCrop()
    takeSnapshot()
    removeAllEditsHistory()
    
    self.sinkState { [weak self] (state) in
      
      guard let self = self else { return }
      
      state.ifChanged(\.currentEdit) { currentEdit in
        self.updatePreviewImage(from: currentEdit)
      }
      
    }
    .store(in: &subscriptions)
        
    self.source.setImageUpdateListener { [weak self] in
      guard let self = self else { return }
      self.adjustmentImage = $0.imageSource?.image
      self.initialCrop()
      guard $0.imageSource?.image != nil else { return }
      self.set(colorCubeFilters: colorCubeStorage.filters)

      updatePreviewFilterSizeImage: do {
        let smallSizeImage = ImageTool.resize(
          to: Geometry.sizeThatAspectFit(
            aspectRatio: CGSize(width: 1, height: 1),
            boundingSize: CGSize(
              width: 60 * self.targetScreenScale,
              height: 60 * self.targetScreenScale
            )
          ),
          from: self.originalPreviewImage!
          )!
        self.cubeFilterPreviewSourceImage = smallSizeImage
          .transformed(
            by: .init(
              translationX: -smallSizeImage.extent.origin.x,
              y: -smallSizeImage.extent.origin.y
            )
        )
      }
      self.refreshColorCubeFilters()
      self.delegate?.editingStack(self, didUpdate: self.source)
    }
  
  }

  open func initialCrop() {
    guard let image = source.imageSource?.image else { return }
    setAdjustment(cropRect: image.extent)
  }

  // MARK: - Functions

  public func requestApplyingFilterImage() -> CIImage {
    fatalError()
  }

  public func takeSnapshot() {
    commit {
      $0.withType { (type, ref) -> Void in
        type.makeVersion(ref: ref)
      }
    }
  }

  public func revertEdit() {
    
    commit {
      $0.currentEdit = $0.history.last ?? .init()
    }
    
  }

  public func undoEdit() {
    
    commit {
      $0.currentEdit = $0.history.popLast() ?? .init()
    }
  }

  public func removeAllEditsHistory() {
    commit {
      $0.history = []
    }
  }

  public func set(filters: (inout Edit.Filters) -> Void) {
    applyIfChanged {
      filters(&$0.filters)
    }
  }

  public func setAdjustment(cropRect: CGRect) {

    guard let originalImage = source.imageSource?.image else { return } //XXX check for croppability ?

    var _cropRect = cropRect

    _cropRect.origin.x.round(.up)
    _cropRect.origin.y.round(.up)
    _cropRect.size.width.round(.up)
    _cropRect.size.height.round(.up)

    applyIfChanged {
      $0.cropRect = _cropRect
    }

    _cropRect.origin.y = originalImage.extent.height - _cropRect.minY - _cropRect.height

    let croppedImage = originalImage
      .cropped(to: _cropRect)

    let result = ImageTool.resize(
      to: Geometry.sizeThatAspectFit(
        aspectRatio: croppedImage.extent.size,
        boundingSize: CGSize(
          width: preferredPreviewSize.width * targetScreenScale,
          height: preferredPreviewSize.height * targetScreenScale
        )
      ),
      from: croppedImage
    )

    originalPreviewImage = result
  }

  public func set(blurringMaskPaths: [DrawnPathInRect]) {

    applyIfChanged {
      $0.blurredMaskPaths = blurringMaskPaths
    }
  }

  private func refreshColorCubeFilters() {
    guard let cubeFilterPreviewSourceImage = cubeFilterPreviewSourceImage else { return }
    self.previewColorCubeFilters = colorCubeFilters.concurrentMap {
      let r = PreviewFilterColorCube(sourceImage: cubeFilterPreviewSourceImage, filter: $0)
      r.preheat()
      return r
    }
  }

  @available(*, deprecated, renamed: "set(colorCubeFilters:)")
  public func set(availableColorCubeFilters: [FilterColorCube]) {
    set(colorCubeFilters: availableColorCubeFilters)
  }

  public func set(colorCubeFilters: [FilterColorCube]) {
    self.colorCubeFilters = colorCubeFilters
    refreshColorCubeFilters()
  }

  public func makeRenderer() -> ImageRenderer {
    let renderer = ImageRenderer(source: source)

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

  private func updatePreviewImage(from edit: Edit) {

    guard let sourceImage = originalPreviewImage else {
      previewImage = nil
      return
    }
    
    let filters = edit
      .makeFilters()
    
    let result = filters.reduce(sourceImage) { (image, filter) -> CIImage in
      filter.apply(to: image, sourceImage: sourceImage)
    }
    
    self.previewImage = result
    self.delegate?.editingStack(self, didChangeCurrentEdit: edit)
    
    // TODO: Ignore vignette and blur (convolutions)
//    adjustmentImage = filters.reduce(source.image) { (image, filter) -> CIImage in
//      filter.apply(to: image, sourceImage: source.image).insertingIntermediateIfCanUse()
//    }

  }

}

open class SquareEditingStack : EditingStack {

  open override func initialCrop() {
    guard let image = source.imageSource?.image else { return }
    let cropRect = Geometry.rectThatAspectFit(
      aspectRatio: .init(width: 1, height: 1),
      boundingRect: image.extent
    )
    
    setAdjustment(cropRect: cropRect)
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

extension Collection where Index == Int {
  
  fileprivate func concurrentMap<U>(_ transform: (Element) -> U) -> [U] {
    var buffer = [U?].init(repeating: nil, count: count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: count) { i in
      let e = self[i]
      let r = transform(e)
      lock.lock()
      buffer[i] = r
      lock.unlock()
    }
    return buffer.compactMap { $0 }
  }
}

