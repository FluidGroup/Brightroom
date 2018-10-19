//
//  FilterGaussianBlur.swift
//  Fil
//
//  Created by Muukii on 11/15/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom

public struct FilterGaussianBlur: Filtering {
    
    public static let maximumValue: Double = 100
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 0
    
    public let value: Double
    
    public let filterChain: FilterChain

    public init(value: Double) {
        
        self.value = value
        self.filterChain = {
            
            let clamp = LightRoom.TileEffect.AffineClamp(transform: CGAffineTransform(scaleX: 1,y: 1))
            return FilterChain { (image) -> CIImage? in
                guard let image = image else {
                    return nil
                }
                let radius = RadiusCalculator.radius(image.extent) * value / FilterGaussianBlur.maximumValue
                let filter = LightRoom.Blur.GaussianBlur(radius: radius)
                image >>> clamp >>> filter
                return filter.outputImage?.cropping(to: image.extent)
            }
        }()
    }
}
