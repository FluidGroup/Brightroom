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

  public struct Edit : Equatable {

    public var cropRect: CGRect?
    public var blurredMaskPaths: [DrawnPathInRect] = []
    public var doodlePaths: [DrawnPath] = []

  }

  public var previewImage: CIImage? {
    didSet {
      delegate?.editingStack(self, didChangePreviewImage: previewImage)
    }
  }

  public var originalPreviewImage: CIImage? {
    didSet {

      // TODO apply Filter
      previewImage = originalPreviewImage

    }
  }

  public var adjustmentImage: CIImage? {
    didSet {
      delegate?.editingStack(self, didChangeAdjustmentImage: adjustmentImage)
    }
  }

  public let preferredPreviewSize: CGSize

  public let targetScreenScale: CGFloat

  public weak var delegate: EditingStackDelegate?

  public let source: ImageSource

  public var canUndo: Bool {
    return edits.count > 1
  }

  public var currentEdit: Edit {
    get {
      return edits.last!
    }
    set {
      edits[edits.indices.last!] = newValue
    }
  }

  public private(set) var edits: [Edit] {
    didSet {
      delegate?.editingStack(self, didChangeCurrentEdit: currentEdit)
    }
  }

  public init(
    source: ImageSource,
    previewSize: CGSize,
    screenScale: CGFloat = UIScreen.main.scale
    ) {

    self.source = source

    self.targetScreenScale = screenScale
    self.preferredPreviewSize = previewSize

    self.adjustmentImage = source.image

    self.edits = [.init()]

    originalPreviewImage = ImageTool.resize(
      to: Geometry.sizeThatAspectFill(
        aspectRatio: source.image.extent.size,
        minimumSize: CGSize(
          width: preferredPreviewSize.width * targetScreenScale,
          height: preferredPreviewSize.height * targetScreenScale
        )
      ),
      from: source.image
    )

    setAdjustment(cropRect: source.image.extent)
    
  }

  public func requestApplyingFilterImage() -> CIImage {
    fatalError()
  }

  public func commit() {
    edits.append(currentEdit)
  }

  public func setAdjustment(cropRect: CGRect) {

    let originalImage = source.image

    var _cropRect = cropRect

    _cropRect.origin.x.round(.up)
    _cropRect.origin.y.round(.up)
    _cropRect.size.width.round(.up)
    _cropRect.size.height.round(.up)

    apply {
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

    apply {
      $0.blurredMaskPaths = blurringMaskPaths
    }
  }

  public func makeRenderer() -> ImageRenderer {

    guard let originalPreviewImage = originalPreviewImage else {
      preconditionFailure()
    }

    let scale = _ratio(to: source.image.extent.size, from: originalPreviewImage.extent.size)

    let renderer = ImageRenderer(source: source)

    let edit = currentEdit

    renderer.edit.croppingRect = edit.cropRect
    renderer.edit.drawer = [
      BlurredMask(paths: edit.blurredMaskPaths)
    ]

    return renderer
  }

  private func apply(_ perform: (inout Edit) -> Void) {

    perform(&currentEdit)

  }

}

open class SquareEditingStack : EditingStack {

  public override init(
    source: ImageSource,
    previewSize: CGSize,
    screenScale: CGFloat = UIScreen.main.scale
    ) {

    super.init(source: source, previewSize: previewSize, screenScale: screenScale)

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
