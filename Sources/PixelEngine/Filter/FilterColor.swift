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
  
  public static let range: ParameterRange<Double, FilterColor> = .init(min: -180, max: 180)
  
  public var value: Double = 0
  
  public init() {
    
  }
  
  func degreesToRadians(_ degrees: Double) -> Double {
    return Double(Int(degrees)) * .pi / 180
  }
  
  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {
    
    return
      image
        .applyingFilter(
          "CIHueAdjust",
          parameters: [
            kCIInputAngleKey: degreesToRadians(value),
          ]
    )
  }
  
}
