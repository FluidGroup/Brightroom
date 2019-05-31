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

public protocol EditingStackDelegate : class {

  func editingStack(_ stack: EditingStack, didChangeCurrentEdit edit: EditingStack.Edit)
}

open class EditingStack {

  // MARK: - Stored Properties

  public let source: ImageSource

  public weak var delegate: EditingStackDelegate?

  public let preferredPreviewSize: CGSize

  public let targetScreenScale: CGFloat

  private(set) public var availableColorCubeFilters: [PreviewFilterColorCube] = []

  private(set) public var cubeFilterPreviewSourceImage: CIImage!
  
  private(set) public var previewImage: CIImage?

  private(set) public var originalPreviewImage: CIImage? {
    didSet {
      EngineLog.debug("Changed EditingStack.originalPreviewImage")
      updatePreviewImage()

    }
  }

  public var adjustmentImage: CIImage?
  
  public var aspectRatio: CGSize {
    return originalPreviewImage!.extent.size
  }

  public var isDirty: Bool {
    return draftEdit != nil
  }

  public var canUndo: Bool {
    return edits.count > 1
  }

  public var draftEdit: Edit? {
    didSet {
      if oldValue != draftEdit {
        updatePreviewImage()
      }
    }
  }

  public var currentEdit: Edit {
    return draftEdit ?? edits.last!
  }

  public private(set) var edits: [Edit] {
    didSet {
      EngineLog.debug("Edits changed counnt -> \(edits.count)")
    }
  }
  
  private let queue = DispatchQueue(
    label: "me.muukii.PixelEngine",
    qos: .default,
    attributes: []
  )

  // MARK: - Initializers

  public init(
    source: ImageSource,
    previewSize: CGSize,
    colorCubeStorage: ColorCubeStorage = .default,
    screenScale: CGFloat = UIScreen.main.scale
    ) {

    self.source = source

    self.targetScreenScale = screenScale
    self.preferredPreviewSize = previewSize

    self.adjustmentImage = source.image

    self.edits = [.init()]
    
    initialCrop()
    commit()
    removeAllHistory()
    
    precondition(originalPreviewImage != nil, "originalPreviewImage is nil")

    updatePreviewFilterSizeImage: do {
      let smallSizeImage = ImageTool.resize(
        to: Geometry.sizeThatAspectFit(
          aspectRatio: CGSize(width: 1, height: 1),
          boundingSize: CGSize(
            width: 60 * targetScreenScale,
            height: 60 * targetScreenScale
          )
        ),
        from: originalPreviewImage!
        )!
      
      cubeFilterPreviewSourceImage = smallSizeImage
        .transformed(
          by: .init(
            translationX: -smallSizeImage.extent.origin.x,
            y: -smallSizeImage.extent.origin.y
          )
      )
    }
    set(availableColorCubeFilters: colorCubeStorage.filters)

  }
  
  open func initialCrop() {
     setAdjustment(cropRect: source.image.extent)
  }

  // MARK: - Functions

  public func requestApplyingFilterImage() -> CIImage {
    fatalError()
  }

  private func makeDraft() {
    draftEdit = edits.last ?? .init()
  }

  public func commit() {
    guard let edit = draftEdit else {
      EngineLog.debug("No draft, no needs commit")
      return
    }
    guard edits.last != edit else { return }
    edits.append(edit)
    draftEdit = nil
  }

  public func revert() {
    draftEdit = nil
  }

  public func undo() {
    edits.removeLast()
    updatePreviewImage()
  }

  public func removeAllHistory() {
    edits = [edits.last].compactMap { $0 }
  }

  public func set(filters: (inout Edit.Filters) -> Void) {
    applyIfChanged {
      filters(&$0.filters)
    }
  }

  public func setAdjustment(cropRect: CGRect) {

    let originalImage = source.image

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

  public func set(availableColorCubeFilters: [FilterColorCube]) {
    
    self.availableColorCubeFilters = availableColorCubeFilters.concurrentMap { item in
      let r = PreviewFilterColorCube.init(sourceImage: cubeFilterPreviewSourceImage, filter: item)
      r.preheat()
      return r
    }
    
  }

  public func makeRenderer() -> ImageRenderer {

    let renderer = ImageRenderer(source: source)

    let edit = currentEdit

    renderer.edit.croppingRect = edit.cropRect
    renderer.edit.drawer = [
      BlurredMask(paths: edit.blurredMaskPaths)
    ]

    renderer.edit.modifiers = edit.makeFilters()

    return renderer
  }

  private func applyIfChanged(_ perform: (inout Edit) -> Void) {

    if draftEdit == nil {
      makeDraft()
    }

    var draft = draftEdit!
    perform(&draft)

    guard draftEdit != draft else { return }

    draftEdit = draft

  }

  private func updatePreviewImage() {

    guard let sourceImage = originalPreviewImage else {
      previewImage = nil
      return
    }
    
    let filters = self.currentEdit
      .makeFilters()
    
    let result = filters.reduce(sourceImage) { (image, filter) -> CIImage in
      filter.apply(to: image, sourceImage: sourceImage)
    }
    
    self.previewImage = result
    self.delegate?.editingStack(self, didChangeCurrentEdit: self.currentEdit)
    
    // TODO: Ignore vignette and blur (convolutions)
//    adjustmentImage = filters.reduce(source.image) { (image, filter) -> CIImage in
//      filter.apply(to: image, sourceImage: source.image).insertingIntermediateIfCanUse()
//    }

  }

}

open class SquareEditingStack : EditingStack {

  open override func initialCrop() {
    let cropRect = Geometry.rectThatAspectFit(
      aspectRatio: .init(width: 1, height: 1),
      boundingRect: source.image.extent
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

