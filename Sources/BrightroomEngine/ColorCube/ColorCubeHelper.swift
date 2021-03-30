//
//  ColorCubeHelper.swift
//
//  Created by Joshua Sullivan on 10/10/16.
//  Copyright © 2016 Joshua Sullivan. All rights reserved.
//

import UIKit
import Accelerate

public enum ColorCubeHelperError: Error {
  case incorrectImageSize
  case unableToCreateDataProvider
  case unableToGetBitmpaDataBuffer
  case failedToCreateCGImageSource
}

/**
 arranged code based on https://chibicode.org/?p=57
 */
public class ColorCubeHelper {
    
  public static func createColorCubeData(inputImage inProvider: CGDataProvider, cubeDimension: Int) throws -> Data {
    
    guard let imageSource = CGImageSourceCreateWithDataProvider(inProvider, nil) else {
      throw ColorCubeHelperError.failedToCreateCGImageSource
    }
     
    let cgImage = ImageTool.loadOriginalCGImage(from: imageSource, fixesOrientation: false)!
          
    let pixels = cgImage.width * cgImage.height
    let channels = 4
    
    // If the number of pixels doesn't match what's needed for the supplied cube dimension, abort.
    guard pixels == cubeDimension * cubeDimension * cubeDimension else {
      throw ColorCubeHelperError.incorrectImageSize
    }
    
    // We don't need a sizeof() because uint_8t is explicitly 1 byte.
    let memSize = pixels * channels
           
    let inBitmapData = cgImage.dataProvider!.data
    guard let inBuffer = CFDataGetBytePtr(inBitmapData) else {
      throw ColorCubeHelperError.unableToGetBitmpaDataBuffer
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

extension ColorCubeHelper {
  
  public static func makeColorCubeFilter(
    lutImage: CGDataProvider,
    dimension: Int,
    colorSpace: CGColorSpace,
    cacheKey: String?
  ) -> CIFilter {
    
    let data: Data
    
    if let cacheKey = cacheKey, let cached = cache.object(forKey: cacheKey as NSString) {
      data = cached as Data
    } else {
      data = try! ColorCubeHelper.createColorCubeData(inputImage: lutImage, cubeDimension: dimension)
      
      if let cacheKey = cacheKey {
        cache.setObject(data as NSData, forKey: cacheKey as NSString)
      }
    }
        
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

let cache = NSCache<NSString, NSData>()
