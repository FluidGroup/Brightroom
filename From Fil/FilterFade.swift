//
//  FilterFade.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import LightRoomExtension

// https://github.com/muukii/Fil/blob/919cc28c19b1aac05f2f8463e646319e3a701b0b/Modules/LightRoomExtension/ExternalFilter.swift
public struct FilterFade: Filtering {
    
    public static let maximumValue: Double = 0.12
    public static let minimumValue: Double = 0
    public static let neutralValue: Double = 0
    
    public let value: Double
    
    public let filterChain: FilterChain

    public init(value: Double) {
        
        self.value = value
        self.filterChain = {
            
            return LightRoom.ExternalFilter.Fade(alpha: value)
        }()
    }
}
