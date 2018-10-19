//
//  FilterHighlightShadowTint.swift
//  Fil
//
//  Created by Muukii on 11/5/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import JAYSON
import LightRoomExtension
import Hue

// https://github.com/muukii/Fil/blob/919cc28c19b1aac05f2f8463e646319e3a701b0b/Modules/LightRoomExtension/ExternalFilter.swift

public func == (lhs: FilterHighlightShadowTint, rhs: FilterHighlightShadowTint) -> Bool {

    if lhs.highlightTintColor == rhs.highlightTintColor &&
        lhs.highlightTintAmount == rhs.highlightTintAmount &&
        lhs.shadowTintColor == rhs.shadowTintColor &&
        lhs.shadowTintAmount == rhs.shadowTintAmount {
            return true
    }
    return false
}

public struct FilterHighlightShadowTint: Filtering, MultipleParameters, Equatable {

    public enum HighlightTintColors {
        public static let Color1 = UIColor(hex: "#E6E377")
        public static let Color2 = UIColor(hex: "#E6BB78")
        public static let Color3 = UIColor(hex: "#E67777")
        public static let Color4 = UIColor(hex: "#EA8CB7")
        public static let Color5 = UIColor(hex: "#B677E6")
        public static let Color6 = UIColor(hex: "#7781E6")
        public static let Color7 = UIColor(hex: "#77D2E5")
        public static let Color8 = UIColor(hex: "#77E681")
    }

    public enum ShadowTintColors {
        public static let Color1 = UIColor(hex: "#C7C12E")
        public static let Color2 = UIColor(hex: "#C78B2E")
        public static let Color3 = UIColor(hex: "#C72E2E")
        public static let Color4 = UIColor(hex: "#C4417E")
        public static let Color5 = UIColor(hex: "#852EC7")
        public static let Color6 = UIColor(hex: "#2E3CC7")
        public static let Color7 = UIColor(hex: "#2EABC7")
        public static let Color8 = UIColor(hex: "#2EC73C")
    }

    public static let neutralTintColor = UIColor(red: 0, green: 0, blue: 0, alpha: 1)

    public static let maximumHighlightAmount: Double = 0.6
    public static let minimumHighlightAmount: Double = 0
    public static let neutralHighlightAmount: Double = 0.3

    public static let maximumShadowAmount: Double = 0.2
    public static let minimumShadowAmount: Double = 0
    public static let neutralShadowAmount: Double = 0.1

    // nilだったらOff
    public var highlightTintColor: UIColor?
    public var highlightTintAmount: Double
    // nilだったらOff
    public var shadowTintColor: UIColor?
    public var shadowTintAmount: Double

    public init(
        highlightTintColor: UIColor? = nil,
        highlightTintAmount: Double = 0.3,
        shadowTintColor: UIColor? = nil,
        shadowTintAmount: Double = 0.1) {

        self.highlightTintColor = highlightTintColor
        self.highlightTintAmount = highlightTintAmount
        self.shadowTintColor = shadowTintColor
        self.shadowTintAmount = shadowTintAmount
    }

    public var filterChain: FilterChain {
        
        let highlightTintColor = CIColor(color: self.highlightTintColor?.withAlphaComponent(CGFloat(self.highlightTintAmount)) ?? UIColor.clear)
        let shadowTintColor = CIColor(color: self.shadowTintColor?.withAlphaComponent(CGFloat(self.shadowTintAmount)) ?? UIColor.clear)
        
        return LightRoom.ExternalFilter.HighlightShadowTint(
            highlightTintColor: highlightTintColor,
            shadowTintColor: shadowTintColor)

    }

    public init?(jayson: JAYSON) {

        guard let highlightTintColorRed = jayson[Keys.highlightTintColorRed].double,
            let highlightTintColorGreen = jayson[Keys.highlightTintColorGreen].double,
            let highlightTintColorBlue = jayson[Keys.highlightTintColorBlue].double,
            let highlightTintColorAlpha = jayson[Keys.highlightTintColorAlpha].double else {
                return nil
        }

        let highlightTintColor = UIColor(red: CGFloat(highlightTintColorRed), green: CGFloat(highlightTintColorGreen), blue: CGFloat(highlightTintColorBlue), alpha: CGFloat(highlightTintColorAlpha))
        

        guard let shadowTintColorRed = jayson[Keys.shadowTintColorRed].double,
            let shadowTintColorGreen = jayson[Keys.shadowTintColorGreen].double,
            let shadowTintColorBlue = jayson[Keys.shadowTintColorBlue].double,
            let shadowTintColorAlpha = jayson[Keys.shadowTintColorAlpha].double else {
                
                return nil
        }

        let shadowTintColor = UIColor(red: CGFloat(shadowTintColorRed), green: CGFloat(shadowTintColorGreen), blue: CGFloat(shadowTintColorBlue), alpha: CGFloat(shadowTintColorAlpha))
        

        guard let highlightTintAmount = jayson[Keys.highlightTintAmout].double, let shadowTintAmount = jayson[Keys.shadowTintAmount].double else {
            return nil
        }

        self.highlightTintColor = highlightTintColor
        self.shadowTintColor = shadowTintColor
        self.highlightTintAmount = highlightTintAmount
        self.shadowTintAmount = shadowTintAmount
    }

    public func toJAYSON() -> JAYSON {

        var dictionary: [String: JAYSON] = [:]

        if let highlightTintColor = self.highlightTintColor {

            let highlightTintColor = CIColor(color: highlightTintColor)

            dictionary[Keys.highlightTintColorRed] = JAYSON(highlightTintColor.red)
            dictionary[Keys.highlightTintColorGreen] = JAYSON(highlightTintColor.green)
            dictionary[Keys.highlightTintColorBlue] = JAYSON(highlightTintColor.blue)
            dictionary[Keys.highlightTintColorAlpha] = JAYSON(highlightTintColor.alpha)
        }

        if let shadowTintColor = self.shadowTintColor {
            let shadowTintColor = CIColor(color: shadowTintColor)

            dictionary[Keys.shadowTintColorRed] = JAYSON(shadowTintColor.red)
            dictionary[Keys.shadowTintColorGreen] = JAYSON(shadowTintColor.green)
            dictionary[Keys.shadowTintColorBlue] = JAYSON(shadowTintColor.blue)
            dictionary[Keys.shadowTintColorAlpha] = JAYSON(shadowTintColor.alpha)
        }

        dictionary[Keys.highlightTintAmout] = JAYSON(self.highlightTintAmount)
        dictionary[Keys.shadowTintAmount] = JAYSON(self.shadowTintAmount)

        return JAYSON(dictionary)
    }

    fileprivate struct Keys {
        static let highlightTintColorRed = "highlight_tint_color_red"
        static let highlightTintColorGreen = "highlight_tint_color_green"
        static let highlightTintColorBlue = "highlight_tint_color_blue"
        static let highlightTintColorAlpha = "highlight_tint_color_alpha"
        static let highlightTintAmout = "highlight_tint_amount"
        static let shadowTintColorRed = "shadow_tint_color_red"
        static let shadowTintColorGreen = "shadow_tint_color_green"
        static let shadowTintColorBlue = "shadow_tint_color_blue"
        static let shadowTintColorAlpha = "shadow_tint_color_alpha"
        static let shadowTintAmount = "shadow_titn_amount"
    }
}
