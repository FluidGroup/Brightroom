//
//  Vignette.swift
//  Fil
//
//  Created by Muukii on 9/27/15.
//  Copyright © 2015 muukii. All rights reserved.
//

public struct FilterVignette: Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterVignette> = .init(min: 0, max: 8)

  public var value: Double = 0

  public init() {

  }
    
  public func apply(to image: CIImage) -> CIImage {

    let radius = RadiusCalculator.radius(value: value, max: FilterVignette.range.max, imageExtent: image.extent)

    return
      image.applyingFilter(
        "CIVignette",
        parameters: [
          kCIInputRadiusKey: radius as AnyObject,
          kCIInputIntensityKey: value as AnyObject,
        ])
  }
}
