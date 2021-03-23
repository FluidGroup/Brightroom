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
