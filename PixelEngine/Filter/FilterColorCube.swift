//
//  FilterColorCube.swift
//  PixelEngine
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public struct PreviewFilterColorCube : Equatable {

  private enum Static {
    static let ciContext = CIContext(options: [.useSoftwareRenderer : false])
    static let heatingQueue = DispatchQueue.init(label: "me.muukii.PixelEngine.Preheat", attributes: [.concurrent])
  }

  public let image: CIImage
  public let filter: FilterColorCube

  init(sourceImage: CIImage, filter: FilterColorCube) {
    self.filter = filter
    self.image = filter.apply(to: sourceImage)
  }

  public func preheat() {
    Static.heatingQueue.async {
      _ = Static.ciContext.createCGImage(self.image, from: self.image.extent)
    }
  }
}

/**
 TODO: Add filter name
 */
public struct FilterColorCube : Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterColorCube> = .init(min: 0, max: 1)

  public let filter: CIFilter

  public var amount: Double = 1

  public init(
    lutImage: Image,
    dimension: Int,
    colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    ) {

    self.filter = ColorCube.makeColorCubeFilter(lutImage: lutImage, dimension: dimension, colorSpace: colorSpace)
  }

  public func apply(to image: CIImage) -> CIImage {

    let f = filter.copy() as! CIFilter

    f.setValue(image, forKeyPath: kCIInputImageKey)
    if let colorSpace = image.colorSpace {
      f.setValue(colorSpace, forKeyPath: "inputColorSpace")
    }

    return f.outputImage!

  }
}
