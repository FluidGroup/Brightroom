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

  public let source: ImageSource

  public var edit: Edit = .init()

  public init(source: ImageSource) {
    self.source = source
  }

  public func render() -> UIImage {

    let resultImage: CIImage = {

      let targetImage = source.image
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

    let canvasSize = resultImage.extent.size
    let image = UIGraphicsImageRenderer(
      size: canvasSize,
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
          drawer.draw(in: context, canvasSize: canvasSize)
        }
    }

    return image

  }
}

