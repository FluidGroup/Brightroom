//
//  Engine.swift
//  PixelEngine
//
//  Created by muukii on 10/8/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation
import CoreImage

public protocol EngineDelegate : class {

}

public final class Engine {

  private enum Static {

    static let cicontext = CIContext(options: [CIContextOption.useSoftwareRenderer : true])
  }

  public let targetImage: CIImage

  public var croppingRect: CGRect?
  public var modifiers: [Filtering] = []
  public var drawer: [GraphicsDrawing] = []

  public convenience init(fullResolutionOriginalImage: UIImage) {

    let image = CIImage(image: fullResolutionOriginalImage)!
    let fixedOriantationImage = image.oriented(forExifOrientation: imageOrientationToTiffOrientation(fullResolutionOriginalImage.imageOrientation))

    self.init(targetImage: fixedOriantationImage)
  }

  public init(targetImage: CIImage) {
    self.targetImage = targetImage
  }

  public func makePreviewEngine() -> PreviewEngine {

    let engine = PreviewEngine(
      fullResolutionOriginalImage: targetImage,
      previewSize: .zero
    )
    return engine
  }

  public func render() -> UIImage {

    let resultImage: CIImage = {

      let image: CIImage

      if var croppingRect = croppingRect {
        croppingRect.origin.y = targetImage.extent.height - croppingRect.minY - croppingRect.height
        image = targetImage.cropped(to: croppingRect.rounded())
      } else {
        image = targetImage
      }

      let result = modifiers.reduce(image, { image, modifier in
        return modifier.modify(to: image)
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
    }

    return image

  }
}

public final class PreviewEngine {

  var image: CIImage
  var imageForCropping: UIImage

  init(
    fullResolutionOriginalImage: CIImage,
    previewSize: CGSize
    ) {

    let ratio = _ratio(
      to: fullResolutionOriginalImage.extent.size,
      from: previewSize
    )

    image = fullResolutionOriginalImage

    imageForCropping = .init()
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
