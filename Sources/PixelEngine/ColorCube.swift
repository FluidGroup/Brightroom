//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
public typealias PlatformImage = UIImage
#endif
import PixelEngineObjc

public enum ColorCube {

  public static func makeColorCubeFilter(
    lutImage: PlatformImage,
    dimension: Int,
    colorSpace: CGColorSpace
    ) -> CIFilter {
            
    let data = try! ColorCubeHelper.createColorCubeData(inputImage: lutImage, cubeDimension: 64)
    
    let filter = CIFilter(
      name: "CIColorCubeWithColorSpace",
      parameters: [
        "inputCubeDimension" : dimension,
        "inputCubeData" : data,
        "inputColorSpace" : colorSpace,
        ]
      )

    return filter!
  }
  
  #if false

  private static func createBitmap(image: CGImage, colorSpace: CGColorSpace) -> UnsafeMutablePointer<UInt8>? {

    let width = image.width
    let height = image.height

    let bitsPerComponent = 8
    let bytesPerRow = width * 4

    let bitmapSize = bytesPerRow * height

    guard let data = malloc(bitmapSize) else {
      return nil
    }

    guard let context = CGContext(
      data: data,
      width: width,
      height: height,
      bitsPerComponent: bitsPerComponent,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
      releaseCallback: nil,
      releaseInfo: nil) else {
        return nil
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    return data.bindMemory(to: UInt8.self, capacity: bitmapSize)
  }

  // Imported from Objective-C code.
  // TODO: Improve more swifty.
  public static func cubeData(lutImage: PlatformImage, dimension: Int, colorSpace: CGColorSpace) -> Data? {

    guard let cgImage = lutImage.cgImage else {
      return nil
    }

    guard let bitmap = createBitmap(image: cgImage, colorSpace: colorSpace) else {
      return nil
    }

    let width = cgImage.width
    let height = cgImage.height
    let rowNum = width / dimension
    let columnNum = height / dimension

    let dataSize = dimension * dimension * dimension * MemoryLayout<Float>.size * 4

    var array = Array<Float>(repeating: 0, count: dataSize)

    var bitmapOffest: Int = 0
    var z: Int = 0

    for _ in stride(from: 0, to: rowNum, by: 1) {
      for y in stride(from: 0, to: dimension, by: 1) {
        let tmp = z
        for _ in stride(from: 0, to: columnNum, by: 1) {
          for x in stride(from: 0, to: dimension, by: 1) {

            let dataOffset = (z * dimension * dimension + y * dimension + x) * 4

            let position = bitmap
              .advanced(by: bitmapOffest)

            array[dataOffset + 0] = Float(position
              .advanced(by: 0)
              .pointee) / 255

            array[dataOffset + 1] = Float(position
              .advanced(by: 1)
              .pointee) / 255

            array[dataOffset + 2] = Float(position
              .advanced(by: 2)
              .pointee) / 255

            array[dataOffset + 3] = Float(position
              .advanced(by: 3)
              .pointee) / 255

            bitmapOffest += 4

          }
          z += 1
        }
        z = tmp
      }
      z += columnNum
    }

    free(bitmap)

    let data = Data.init(bytes: array, count: dataSize)
    return data
  }
  
  #endif
}


//
//  ColorCubeHelper.swift
//
//  Created by Joshua Sullivan on 10/10/16.
//  Copyright © 2016 Joshua Sullivan. All rights reserved.
//

import UIKit
import Accelerate

public class ColorCubeHelper {
  
  public enum ColorCubeError: Error {
    case incorrectImageSize
    case missingImageData
    case unableToCreateDataProvider
    case unableToGetBitmpaDataBuffer
  }
  
  public static func createColorCubeData(inputImage image: UIImage, cubeDimension: Int) throws -> Data {
    
    // Set up some variables for calculating memory size.
    let imageSize = image.size
    let dim = Int(imageSize.width)
    let pixels = dim * dim
    let channels = 4
    
    // If the number of pixels doesn't match what's needed for the supplied cube dimension, abort.
    guard pixels == cubeDimension * cubeDimension * cubeDimension else {
      throw ColorCubeError.incorrectImageSize
    }
    
    // We don't need a sizeof() because uint_8t is explicitly 1 byte.
    let memSize = pixels * channels
    
    // Get the UIImage's backing CGImageRef
    guard let img = image.cgImage else {
      throw ColorCubeError.missingImageData
    }
    
    // Get a reference to the CGImage's data provider.
    guard let inProvider = img.dataProvider else {
      throw ColorCubeError.unableToCreateDataProvider
    }
    
    let inBitmapData = inProvider.data
    guard let inBuffer = CFDataGetBytePtr(inBitmapData) else {
      throw ColorCubeError.unableToGetBitmpaDataBuffer
    }
    
    // Calculate the size of the float buffer and allocate it.
    let floatSize = memSize * MemoryLayout<Float>.size
    let finalBuffer = unsafeBitCast(malloc(floatSize), to:UnsafeMutablePointer<Float>.self)
    
    // Convert the uint_8t to float. Note: a uint of 255 will convert to 255.0f.
    vDSP_vfltu8(inBuffer, 1, finalBuffer, 1, UInt(memSize))
    
    // Divide each float by 255.0 to get the 0-1 range we are looking for.
    var divisor = Float(255.0)
    vDSP_vsdiv(finalBuffer, 1, &divisor, finalBuffer, 1, UInt(memSize))
    
    // Don't copy the bytes, just have the NSData take ownership of the buffer.
    let cubeData = NSData(bytesNoCopy: finalBuffer, length: floatSize, freeWhenDone: true)
    
    return cubeData as Data
    
  }
}
