//
//  EditingStack.swift
//  PixelEngine
//
//  Created by muukii on 10/13/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public protocol EditingStackDelegate : class {

  func editingStack(_ stack: EditingStack, didChangePreviewImage image: UIImage?)
  func editingStack(_ stack: EditingStack, didChangeAdjustmentImage image: UIImage?)
  func editingStack(_ stack: EditingStack, didChangeCurrentEdit edit: EditingStack.Edit)
}

public final class EditingStack {

  public struct Edit : Equatable {

    public var cropRect: CGRect?
    public var blurredMaskPaths: [DrawnPath] = []
    public var doodlePaths: [DrawnPath] = []

  }

  private enum Static {

    static let cicontext = CIContext(options: [
      .useSoftwareRenderer : false,
      ])

  }

  public var previewImage: UIImage? {
    didSet {
      delegate?.editingStack(self, didChangePreviewImage: previewImage)
    }
  }

  public var originalPreviewImage: CIImage? {
    didSet {

      previewImage = originalPreviewImage.map {
        UIImage(ciImage: $0, scale: targetScreenScale, orientation: .up)
      }

    }
  }

  public var adjustmentImage: UIImage? {
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

    self.adjustmentImage = UIImage(
      ciImage: source.image,
      scale: screenScale,
      orientation: .up
    )

    self.edits = [.init()]

    originalPreviewImage = ImageTool.resize(
      to: ContentRect.sizeThatAspectFill(
        aspectRatio: source.image.extent.size,
        minimumSize: CGSize(
          width: preferredPreviewSize.width * targetScreenScale,
          height: preferredPreviewSize.height * targetScreenScale
        )
      ),
      from: source.image
    )

    setAdjustment(cropRect: source.image.extent)

    self.adjustmentImage = source.image.cgImage
      .flatMap { UIImage(cgImage: $0, scale: screenScale, orientation: .up) }
      ?? UIImage(ciImage: source.image, scale: screenScale, orientation: .up)
  }

  public func requestApplyingFilterImage() -> CIImage {
    fatalError()
  }

  public func commit() {
    edits.append(currentEdit)
  }

  public func setAdjustment(cropRect: CGRect) {

    let originalImage = source.image

    var _cropRect = cropRect.rounded()

    apply {
      $0.cropRect = _cropRect
    }

    _cropRect.origin.y = originalImage.extent.height - _cropRect.minY - _cropRect.height

    let croppedImage = originalImage
      .cropped(to: _cropRect)

    let result = ImageTool.resize(
      to: ContentRect.sizeThatAspectFit(
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

  public func set(blurringMaskPaths: [DrawnPath]) {

    apply {
      $0.blurredMaskPaths = blurringMaskPaths
    }
  }

  public func makeRenderer() -> ImageRenderer {

    let renderer = ImageRenderer(source: source)

    let edit = currentEdit

    renderer.edit.croppingRect = edit.cropRect
    renderer.edit.drawer = [BlurredMask(paths: edit.blurredMaskPaths)]

    return renderer
  }

  private func apply(_ perform: (inout Edit) -> Void) {

    perform(&currentEdit)

  }


}

private func _ratio(to: CGSize, from: CGSize) -> CGFloat {

  let _from = sqrt(pow(from.height, 2) + pow(from.width, 2))
  let _to = sqrt(pow(to.height, 2) + pow(to.width, 2))

  return _to / _from
}
