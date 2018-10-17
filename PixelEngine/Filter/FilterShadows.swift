//
//  FilterShadows.swift
//  PixelEngine
//
//  Created by muukii on 10/17/18.
//  Copyright © 2018 muukii. All rights reserved.
//

public struct FilterShadows: Filtering {

  public static let range: ParameterRange<Double, FilterShadows> = .init(min: 0, max: 0.6)

  public var value: Double = FilterShadows.range.max

  public init() {

  }

  public func apply(to image: CIImage) -> CIImage {

    return
      image
        .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount" : value])
  }
}
