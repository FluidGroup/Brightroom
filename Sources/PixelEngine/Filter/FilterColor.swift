//
//  FilterColor.swift
//  PixelEngine
//
//  Created by Danny on 14.11.18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation
import CoreImage

public struct FilterColor: Filtering, Equatable, Codable {
  
  public static let range: ParameterRange<Double, FilterContrast> = .init(min: -0.18, max: 0.18)
  
  public var value: Double = 0
  
  public init() {
    
  }
  
  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {
    
    return
      image
        .applyingFilter(
          "CIHueAdjust",
          parameters: [
            kCIInputAngleKey: 1 + value,
            ]
    )
  }
  
}
