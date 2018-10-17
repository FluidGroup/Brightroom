//
//  Saturation.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom

public struct FilterSaturation: Filtering,SingleParameter {
    
    public static let maximumValue: Double = 2
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 1
    
    public let value: Double
    
    public let filterChain: FilterChain
    
    public init(value: Double) {
        
        self.value = value
        self.filterChain = {
            
            let filter = LightRoom.ColorFilter.ColorControls(saturation: value)
            return FilterChain { (image) -> CIImage? in
                image >>> filter
                return filter.outputImage
            }
        }()
    }
}
