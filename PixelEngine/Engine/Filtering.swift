//
//  Filtering.swift
//  PixelEngine
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import CoreImage

public protocol Filtering {

  func apply(to image: CIImage) -> CIImage
}

public final class ColorCube : Filtering, Equatable {

  public static func == (lhs: ColorCube, rhs: ColorCube) -> Bool {
    guard lhs.cubeData == rhs.cubeData else { return false }
    guard lhs.name == rhs.name else { return false }
    guard lhs.cubeDimension == rhs.cubeDimension else { return false }
    return true
  }

  public let cubeData: Data
  public let name: String
  public let cubeDimension: UInt

  init(name: String, cubeData: Data, cubeDimension: UInt) {
    self.cubeData = cubeData
    self.name = name
    self.cubeDimension = cubeDimension
  }

  public func apply(to image: CIImage) -> CIImage {

    let filter = CIFilter(
      name: "CIColorCubeWithColorSpace",
      parameters: [
        kCIInputImageKey : image,
        "inputCubeDimension" : cubeDimension,
        "inputCubeData" : cubeData,
        "inputColorSpace" : image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        ]
      )!

    return filter.outputImage!

  }
}
