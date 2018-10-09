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

}

public final class PreviewImageEngine : PreviewImageEngineDelegate {

  var previewImage: CIImage?
  var imageForCropping: UIImage
  let scaleFromOriginal: CGFloat

  let engine: ImageEngine

  init(
    engine: ImageEngine,
    previewSize: CGSize
    ) {

    self.engine = engine

    let ratio = _ratio(
      to: engine.targetImage.extent.size,
      from: previewSize
    )

    self.scaleFromOriginal = ratio

    self.imageForCropping = UIImage.init(
      ciImage: engine.targetImage,
      scale: UIScreen.main.scale,
      orientation: .up
    )
  }

  public func set(cropRect: CGRect, from displayingBounds: CGRect) {

    assert(
      engine.targetImage.extent.size == CGSize(
        width: imageForCropping.size.width * imageForCropping.scale,
        height: imageForCropping.size.height * imageForCropping.scale
      )
    )

    let scale = _ratio(
      to: engine.targetImage.extent.size,
      from: displayingBounds.size
    )

    var _cropRect = cropRect
    _cropRect.origin.x *= scale
    _cropRect.origin.y *= scale
    _cropRect.size.width *= scale
    _cropRect.size.height *= scale



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

extension CGRect {

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
