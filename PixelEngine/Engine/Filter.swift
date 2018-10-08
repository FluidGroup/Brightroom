//
//  Filter.swift
//  PixelEngine
//
//  Created by muukii on 10/8/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public final class ColorCube : Equatable {

  public static func == (lhs: ColorCube, rhs: ColorCube) -> Bool {
    guard lhs.cubeData == rhs.cubeData else { return false }
    guard lhs.name == rhs.name else { return false }
    guard lhs.cubeDimension == rhs.cubeDimension else { return false }
    return true
  }

  public let cubeData: Data
  public let name: String
  public let cubeDimension: UInt

  public func ciFilter(image: CIImage, colorSpace: CGColorSpace) -> CIFilter {

    let filter = CIFilter(
      name: "CIColorCubeWithColorSpace",
      parameters: [
        kCIInputImageKey : image,
        "inputCubeDimension" : cubeDimension,
        "inputCubeData" : cubeData,
        "inputColorSpace" : colorSpace,
        ]
      )!

    return filter
  }

  init(name: String, cubeData: Data, cubeDimension: UInt) {
    self.cubeData = cubeData
    self.name = name
    self.cubeDimension = cubeDimension
  }
}
