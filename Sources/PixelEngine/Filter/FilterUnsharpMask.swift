//
//  FilterUnsharpMask.swift
//  Fil
//
//  Created by Muukii on 11/15/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import CoreImage

public struct FilterUnsharpMask: Filtering, Equatable, Codable {
  
  public enum Params {
    public static let intensity: ParameterRange<Double, FilterShadows> = .init(min: 0, max: 0.3)
    public static let radius: ParameterRange<Double, FilterShadows> = .init(min: 0, max: 1)
  }
  
  public var intensity: Double = 0
  public var radius: Double = 0
  
  public init() {
    
  }
  
  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {
    
    let _radius = RadiusCalculator.radius(value: radius, max: FilterUnsharpMask.Params.radius.max, imageExtent: image.extent)
    
    return
      image
        .applyingFilter(
          "CIUnsharpMask",
          parameters: [
            "inputIntensity" : intensity,
            "inputRadius" : _radius,
          ])
  }
}
