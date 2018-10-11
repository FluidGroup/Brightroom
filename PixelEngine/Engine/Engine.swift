//
//  Engine.swift
//  PixelEngine
//
//  Created by muukii on 10/8/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation
import CoreImage

public protocol ImageEngineDelegate : class {

}

public final class ImageEngine {

  public struct Edit {
    public var croppingRect: CGRect?
    public var modifiers: [Filtering] = []
    public var drawer: [GraphicsDrawing] = []
  }

  private enum Static {

    static let cicontext = CIContext(options: [
      .useSoftwareRenderer : false,
      .highQualityDownsample : true,
      ])
  }

  public weak var delegate: ImageEngineDelegate?

  public let targetImage: CIImage

  public var edit: Edit = .init()

  public convenience init(targetImage: UIImage) {

    let image = CIImage(image: targetImage)!
    let fixedOriantationImage = image.oriented(forExifOrientation: imageOrientationToTiffOrientation(targetImage.imageOrientation))

    self.init(targetImage: fixedOriantationImage)
  }

  public init(targetImage: CIImage) {
    self.targetImage = targetImage
  }

  public func render() -> UIImage {

    let resultImage: CIImage = {

      let image: CIImage

      if var croppingRect = edit.croppingRect {
        croppingRect.origin.y = targetImage.extent.height - croppingRect.minY - croppingRect.height
        image = targetImage.cropped(to: croppingRect.rounded())
      } else {
        image = targetImage
      }

      let result = edit.modifiers.reduce(image, { image, modifier in
        return modifier.apply(to: image)
      })

      return result

    }()

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1

    let image = UIGraphicsImageRenderer(
      size: resultImage.extent.size,
      format: format
      )
      .image { (context) in

        let cgContext = context.cgContext

        let cgImage = Static.cicontext.createCGImage(resultImage, from: resultImage.extent, format: .ARGB8, colorSpace: resultImage.colorSpace)!

        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: resultImage.extent.height)
        cgContext.scaleBy(x: 1, y: -1)
        cgContext.draw(cgImage, in: CGRect(origin: .zero, size: resultImage.extent.size))
        cgContext.restoreGState()

        self.edit.drawer.forEach { drawer in
          drawer.draw(in: context)
        }
    }

    return image

  }
}

public protocol PreviewImageEngineDelegate : class {

  func previewImageEngine(_ engine: PreviewImageEngine, didChangePreviewImage image: UIImage?)
  func previewImageEngine(_ engine: PreviewImageEngine, didChangeAdjustmentImage image: UIImage?)
}

public final class PreviewImageEngine {

  private enum Static {

    static let cicontext = CIContext(options: [
      .useSoftwareRenderer : false,
      ])
  }

  public var previewImage: UIImage? {
    didSet {
      delegate?.previewImageEngine(self, didChangePreviewImage: previewImage)
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
      delegate?.previewImageEngine(self, didChangeAdjustmentImage: adjustmentImage)
    }
  }

  public let engine: ImageEngine

  public let preferredPreviewSize: CGSize

  public let targetScreenScale: CGFloat

  public weak var delegate: PreviewImageEngineDelegate?

  public init(
    engine: ImageEngine,
    previewSize: CGSize,
    screenScale: CGFloat = UIScreen.main.scale
    ) {

    self.targetScreenScale = screenScale
    self.preferredPreviewSize = previewSize

    self.engine = engine

    self.adjustmentImage = UIImage(
      ciImage: engine.targetImage,
      scale: screenScale,
      orientation: .up
    )

    originalPreviewImage = ImageTool.resize(
      to: ContentRect.sizeThatAspectFill(
        aspectRatio: engine.targetImage.extent.size,
        minimumSize: CGSize(
          width: preferredPreviewSize.width * targetScreenScale,
          height: preferredPreviewSize.height * targetScreenScale
        )
      ),
      from: engine.targetImage
    )

    setAdjustment(cropRect: engine.edit.croppingRect ?? engine.targetImage.extent)

    self.adjustmentImage = engine.targetImage.cgImage
      .flatMap { UIImage(cgImage: $0, scale: screenScale, orientation: .up) }
      ?? UIImage(ciImage: engine.targetImage, scale: screenScale, orientation: .up)
  }

  public func requestApplyingFilterImage() -> CIImage {
    fatalError()
  }

  public func setAdjustment(cropRect: CGRect) {

    let originalImage = engine.targetImage

    var _cropRect = cropRect.rounded()

    engine.edit.croppingRect = _cropRect

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
}

private func _ratio(to: CGSize, from: CGSize) -> CGFloat {

  let _from = sqrt(pow(from.height, 2) + pow(from.width, 2))
  let _to = sqrt(pow(to.height, 2) + pow(to.width, 2))

  return _to / _from
}

fileprivate func imageOrientationToTiffOrientation(_ value: UIImage.Orientation) -> Int32 {
  switch value{
  case .up:
    return 1
  case .down:
    return 3
  case .left:
    return 8
  case .right:
    return 6
  case .upMirrored:
    return 2
  case .downMirrored:
    return 4
  case .leftMirrored:
    return 5
  case .rightMirrored:
    return 7
  }
}

extension CGFloat {

  fileprivate mutating func ceil() {
    self = Darwin.ceil(self)
  }
}

extension CGRect {

  /// Round x, y, width, height
  fileprivate func ceiled() -> CGRect {

    var _rect = self

    _rect.origin.x.ceil()
    _rect.origin.y.ceil()
    _rect.size.width.ceil()
    _rect.size.height.ceil()

    return _rect

  }

  /// Round x, y, width, height
  fileprivate func rounded() -> CGRect {

    var _rect = self

    _rect.origin.x.round()
    _rect.origin.y.round()
    _rect.size.width.round()
    _rect.size.height.round()

    return _rect

  }
}
