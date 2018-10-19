//
//  FilterUnsharpMask.swift
//  Fil
//
//  Created by Muukii on 11/15/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import CoreImage

public struct FilterUnsharpMask: Filtering, Equatable {
  
  public enum Params {
    public static let range: ParameterRange<Double, FilterShadows> = .init(min: -1, max: 1)
  }
  
  
  public var intensity: Double = 0
  public var radius: Double = 0
  
  public init() {
    
  }
  
  public func apply(to image: CIImage) -> CIImage {
    
    return
      image
        .applyingFilter(
          "CIUnsharpMask",
          parameters: ["inputIntensity" : intensity])
  }
}
