//
//  FilterUnsharpMask.swift
//  Fil
//
//  Created by Muukii on 11/15/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom

public struct FilterUnsharpMask: Filtering {
    
    public static let maximumValue: Double = 20
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 0
    
    public let value: Double
    
    public let filterChain: FilterChain
    
    public init(value: Double) {
        
        self.value = value
        self.filterChain = {
            
            return FilterChain { (image) -> CIImage? in
                
                guard let image = image else {
                    return nil
                }
                
                let radius = RadiusCalculator.radius(image.extent) * value / FilterUnsharpMask.maximumValue
                let filter = LightRoom.Sharpen.UnsharpMask(radius: radius, intencity: 0.16)
                image >>> filter
                return filter.outputImage
            }
        }()
    }
}
