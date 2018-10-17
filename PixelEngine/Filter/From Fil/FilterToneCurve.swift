//
//  ToneCurve.swift
//  Fil
//
//  Created by Muukii on 9/17/15.
//  Copyright © 2015 muukii. All rights reserved.
//

import LightRoom
import LightRoomExtension
import SwiftyJAYSON

public func == (lhs: FilterToneCurve, rhs: FilterToneCurve) -> Bool {
    if lhs.rgbCurvePoints == rhs.rgbCurvePoints &&
        lhs.rCurvePoints == rhs.rCurvePoints &&
        lhs.gCurvePoints == rhs.gCurvePoints &&
        lhs.bCurvePoints == rhs.bCurvePoints {
            return true
    }
    return false
}

public func == (lhs: FilterToneCurve.CurvePoints, rhs: FilterToneCurve.CurvePoints) -> Bool {
    
    if lhs.point1 == rhs.point1
        && lhs.point2 == rhs.point2
        && lhs.point3 == rhs.point3
        && lhs.point4 == rhs.point4
        && lhs.point5 == rhs.point5 {
            return true
    }
    return false
}

public struct FilterToneCurve: Filtering, Equatable {
    
    public struct CurvePoints: Equatable {
        public var point1: CGPoint = CGPoint(x: 0.00, y: 0.00)
        public var point2: CGPoint = CGPoint(x: 0.25, y: 0.25)
        public var point3: CGPoint = CGPoint(x: 0.50, y: 0.50)
        public var point4: CGPoint = CGPoint(x: 0.75, y: 0.75)
        public var point5: CGPoint = CGPoint(x: 1.00, y: 1.00)
        
        public init(point1: CGPoint, point2: CGPoint, point3: CGPoint, point4: CGPoint, point5: CGPoint) {
            
            self.point1 = point1
            self.point2 = point2
            self.point3 = point3
            self.point4 = point4
            self.point5 = point5
        }
        
        private init(values: [[NSNumber]]) {
            
            self.point1 = CGPoint(x: values[0][0].doubleValue, y: values[0][1].doubleValue)
            self.point2 = CGPoint(x: values[1][0].doubleValue, y: values[1][1].doubleValue)
            self.point3 = CGPoint(x: values[2][0].doubleValue, y: values[2][1].doubleValue)
            self.point4 = CGPoint(x: values[3][0].doubleValue, y: values[3][1].doubleValue)
            self.point5 = CGPoint(x: values[4][0].doubleValue, y: values[4][1].doubleValue)
        }
    }

    public let rgbCurvePoints: CurvePoints
    public let rCurvePoints: CurvePoints
    public let gCurvePoints: CurvePoints
    public let bCurvePoints: CurvePoints

    public init(rgb: CurvePoints, r: CurvePoints, g: CurvePoints, b: CurvePoints) {
        
        self.rgbCurvePoints = rgb
        self.rCurvePoints = r
        self.gCurvePoints = g
        self.bCurvePoints = b
    }
    
    public init?(json: JAYSON) {
        
        guard let rValues = json[Keys.RValues].arrayObject as? [[NSNumber]],
            let gValues = json[Keys.GValues].arrayObject as? [[NSNumber]],
            let bValues = json[Keys.BValues].arrayObject as? [[NSNumber]],
            let rgbValues = json[Keys.RGBValues].arrayObject as? [[NSNumber]] else {
                
                return nil
        }
        
        self.rgbCurvePoints = CurvePoints(values: rgbValues)
        self.rCurvePoints = CurvePoints(values: rValues)
        self.gCurvePoints = CurvePoints(values: gValues)
        self.bCurvePoints = CurvePoints(values: bValues)
    }
    
    public func toJAYSON() -> JAYSON {
        
        var dictionary: [String: AnyObject] = [:]
        dictionary[Keys.RValues] = [
            [NSNumber(double: Double(self.rCurvePoints.point1.x)), NSNumber(double: Double(self.rCurvePoints.point1.y))],
            [NSNumber(double: Double(self.rCurvePoints.point2.x)), NSNumber(double: Double(self.rCurvePoints.point2.y))],
            [NSNumber(double: Double(self.rCurvePoints.point3.x)), NSNumber(double: Double(self.rCurvePoints.point3.y))],
            [NSNumber(double: Double(self.rCurvePoints.point4.x)), NSNumber(double: Double(self.rCurvePoints.point4.y))],
            [NSNumber(double: Double(self.rCurvePoints.point5.x)), NSNumber(double: Double(self.rCurvePoints.point5.y))]
        ]
        
        dictionary[Keys.GValues] = [
            [NSNumber(double: Double(self.gCurvePoints.point1.x)), NSNumber(double: Double(self.gCurvePoints.point1.y))],
            [NSNumber(double: Double(self.gCurvePoints.point2.x)), NSNumber(double: Double(self.gCurvePoints.point2.y))],
            [NSNumber(double: Double(self.gCurvePoints.point3.x)), NSNumber(double: Double(self.gCurvePoints.point3.y))],
            [NSNumber(double: Double(self.gCurvePoints.point4.x)), NSNumber(double: Double(self.gCurvePoints.point4.y))],
            [NSNumber(double: Double(self.gCurvePoints.point5.x)), NSNumber(double: Double(self.gCurvePoints.point5.y))]
        ]
        
        dictionary[Keys.BValues] = [
            [NSNumber(double: Double(self.bCurvePoints.point1.x)), NSNumber(double: Double(self.bCurvePoints.point1.y))],
            [NSNumber(double: Double(self.bCurvePoints.point2.x)), NSNumber(double: Double(self.bCurvePoints.point2.y))],
            [NSNumber(double: Double(self.bCurvePoints.point3.x)), NSNumber(double: Double(self.bCurvePoints.point3.y))],
            [NSNumber(double: Double(self.bCurvePoints.point4.x)), NSNumber(double: Double(self.bCurvePoints.point4.y))],
            [NSNumber(double: Double(self.bCurvePoints.point5.x)), NSNumber(double: Double(self.bCurvePoints.point5.y))]
        ]
        
        dictionary[Keys.RGBValues] = [
            [NSNumber(double: Double(self.rgbCurvePoints.point1.x)), NSNumber(double: Double(self.rgbCurvePoints.point1.y))],
            [NSNumber(double: Double(self.rgbCurvePoints.point2.x)), NSNumber(double: Double(self.rgbCurvePoints.point2.y))],
            [NSNumber(double: Double(self.rgbCurvePoints.point3.x)), NSNumber(double: Double(self.rgbCurvePoints.point3.y))],
            [NSNumber(double: Double(self.rgbCurvePoints.point4.x)), NSNumber(double: Double(self.rgbCurvePoints.point4.y))],
            [NSNumber(double: Double(self.rgbCurvePoints.point5.x)), NSNumber(double: Double(self.rgbCurvePoints.point5.y))]
        ]
        
        return JAYSON(dictionary)
    }

   public let filterChain: FilterChain = {
        return LightRoom.ExternalFilter.RGBToneCurve(
            rPoints: [
                [self.rCurvePoints.point1.x, self.rCurvePoints.point1.y],
                [self.rCurvePoints.point2.x, self.rCurvePoints.point2.y],
                [self.rCurvePoints.point3.x, self.rCurvePoints.point3.y],
                [self.rCurvePoints.point4.x, self.rCurvePoints.point4.y],
                [self.rCurvePoints.point5.x, self.rCurvePoints.point5.y],
            ],
            gPoints: [
                [self.gCurvePoints.point1.x, self.gCurvePoints.point1.y],
                [self.gCurvePoints.point2.x, self.gCurvePoints.point2.y],
                [self.gCurvePoints.point3.x, self.gCurvePoints.point3.y],
                [self.gCurvePoints.point4.x, self.gCurvePoints.point4.y],
                [self.gCurvePoints.point5.x, self.gCurvePoints.point5.y],
            ],
            bPoints: [
                [self.bCurvePoints.point1.x, self.bCurvePoints.point1.y],
                [self.bCurvePoints.point2.x, self.bCurvePoints.point2.y],
                [self.bCurvePoints.point3.x, self.bCurvePoints.point3.y],
                [self.bCurvePoints.point4.x, self.bCurvePoints.point4.y],
                [self.bCurvePoints.point5.x, self.bCurvePoints.point5.y],
            ],
            rgbPoints: [
                [self.rgbCurvePoints.point1.x, self.rgbCurvePoints.point1.y],
                [self.rgbCurvePoints.point2.x, self.rgbCurvePoints.point2.y],
                [self.rgbCurvePoints.point3.x, self.rgbCurvePoints.point3.y],
                [self.rgbCurvePoints.point4.x, self.rgbCurvePoints.point4.y],
                [self.rgbCurvePoints.point5.x, self.rgbCurvePoints.point5.y],
            ])
    }

    // MARK: Private
    
    private struct Keys {
        static let RValues = "rValues"
        static let GValues = "gValues"
        static let BValues = "bValues"
        static let RGBValues = "RGBValues"
        static let Point = "point"
    }
}
