//
//  BrightnessFilter.swift
//  PixelEngine
//
//  Created by muukii on 10/16/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation
import CoreImage

public struct FilterBrightness : Filtering, Equatable, Codable {

  public static let range: ParameterRange<Double, FilterBrightness> = .init(min: -1.8, max: 1.8)

  public var value: Double = 0

  public init() {

  }
  
  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {
    return
      image
        .applyingFilter(
          "CIExposureAdjust",
          parameters: [
            kCIInputEVKey: value as AnyObject
          ]
    )
  }

}
