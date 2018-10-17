//
//  FilterFade.swift
//  Fil
//
//  Created by Muukii on 8/18/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import LightRoomExtension

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
