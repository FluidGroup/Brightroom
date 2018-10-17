//
//  FilterBrightness.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom

public struct FilterBrightness: Filtering {
  
  public static let maximumValue: Double = 1.8
  public static let minimumValue: Double = -1.8
  public static let neutralValue: Double = 0
  
  public let value: Double
  
  public let filterChain: FilterChain
  
  public init(value: Double) {
    
    self.value = value
    self.filterChain = {
      
      let filter = LightRoom.ColorFilter.ExposureAdjust(ev: value)
      return FilterChain { (image) -> CIImage? in
        image >>> filter
        return filter.outputImage
      }
    }()
  }
}
