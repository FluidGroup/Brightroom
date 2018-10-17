//
//  EditingStack.swift
//  PixelEngine
//
//  Created by muukii on 10/13/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public protocol EditingStackDelegate : class {

  func editingStack(_ stack: EditingStack, didChangePreviewImage image: CIImage?)
  func editingStack(_ stack: EditingStack, didChangeAdjustmentImage image: CIImage?)
  func editingStack(_ stack: EditingStack, didChangeCurrentEdit edit: EditingStack.Edit)
}

open class EditingStack {

  // MARK: - Stored Properties

  public let source: ImageSource

  public weak var delegate: EditingStackDelegate?

  public let preferredPreviewSize: CGSize

  public let targetScreenScale: CGFloat

  public var availableColorCubeFilters: [PreviewFilterColorCube] = []

  private var cubeFilterPreviewSourceImage: CIImage!

  // MARK: - Computed Properties

  public var previewImage: CIImage? {
    didSet {
      Log.debug("Changed EditingStack.previewImage")
      delegate?.editingStack(self, didChangePreviewImage: previewImage)
    }
  }

  public var originalPreviewImage: CIImage? {
    didSet {
      Log.debug("Changed EditingStack.originalPreviewImage")
      updatePreviewImage()

    }
  }

  public var adjustmentImage: CIImage? {
    didSet {
      delegate?.editingStack(self, didChangeAdjustmentImage: adjustmentImage)
    }
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
      Log.debug("Edits changed counnt -> \(edits.count)")
    }
  }

  // MARK: - Initializers

  public init(
    source: ImageSource,
    previewSize: CGSize,
    screenScale: CGFloat = UIScreen.main.scale,
    colorCubeFilters: [FilterColorCube] = []
    ) {

    self.source = source

    self.targetScreenScale = screenScale
    self.preferredPreviewSize = previewSize

    self.adjustmentImage = source.image

    self.edits = [.init()]

    setAdjustment(cropRect: source.image.extent)
    commit()
    removeAllHistory()
    updatePreviewFilterSizeImage()
    set(availableColorCubeFilters: colorCubeFilters)

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
      assertionFailure("Call makeDraft()")
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

    let items = availableColorCubeFilters.map {
      PreviewFilterColorCube.init(sourceImage: cubeFilterPreviewSourceImage, filter: $0)
    }

    self.availableColorCubeFilters = items

    items.forEach { $0.preheat() }
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

    guard let image = originalPreviewImage else {
      previewImage = nil
      return
    }

    let filters = currentEdit
      .makeFilters()

    previewImage = filters.reduce(image) { (image, filter) -> CIImage in
      filter.apply(to: image)
    }

    adjustmentImage = filters.reduce(source.image) { (image, filter) -> CIImage in
      filter.apply(to: image)
    }

    delegate?.editingStack(self, didChangeCurrentEdit: currentEdit)
  }

  private func updatePreviewFilterSizeImage() {

    let smallSizeImage = ImageTool.resize(
      to: Geometry.sizeThatAspectFit(
        aspectRatio: CGSize(width: 1, height: 1),
        boundingSize: CGSize(
          width: 60 * targetScreenScale,
          height: 60 * targetScreenScale
        )
      ),
      from: source.image
    )

    cubeFilterPreviewSourceImage = smallSizeImage

  }

}

open class SquareEditingStack : EditingStack {

  public override init(
    source: ImageSource,
    previewSize: CGSize,
    screenScale: CGFloat = UIScreen.main.scale,
    colorCubeFilters: [FilterColorCube] = []
    ) {

    super.init(source: source, previewSize: previewSize, screenScale: screenScale)

    let cropRect = Geometry.rectThatAspectFit(
      aspectRatio: .init(width: 1, height: 1),
      boundingRect: source.image.extent
    )

    setAdjustment(cropRect: cropRect)
    commit()
    removeAllHistory()

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
      public var brightness: FilterBrightness?
      public var gaussianBlur: FilterGaussianBlur?
      public var colorCube: FilterColorCube?
    }

    public var cropRect: CGRect?
    public var blurredMaskPaths: [DrawnPathInRect] = []
    public var doodlePaths: [DrawnPath] = []

    public var filters: Filters = .init()

    func makeFilters() -> [Filtering] {
      return ([
        filters.brightness,
        filters.colorCube,
        filters.gaussianBlur,
        ] as [Optional<Filtering>])
        .compactMap { $0 }
    }
  }

}
