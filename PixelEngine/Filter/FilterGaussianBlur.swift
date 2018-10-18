//
//  FilterGaussianBlur.swift
//  PixelEngine
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation
import CoreImage

public struct FilterGaussianBlur : Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterGaussianBlur> = .init(min: 0, max: 100)

  public var value: Double = 0

  public init() {

  }

  public func apply(to image: CIImage) -> CIImage {

    let radius = RadiusCalculator.radius(value: value, max: FilterGaussianBlur.range.max, imageExtent: image.extent)

    return
      image
        .clamped(to: image.extent)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [
            "inputRadius" : radius
          ])
        .cropped(to: image.extent)
  }

}
