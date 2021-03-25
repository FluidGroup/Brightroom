//
//  LoadingTests.swift
//  PixelEngine
//
//  Created by Muukii on 2021/03/25.
//  Copyright © 2021 muukii. All rights reserved.
//

import XCTest
import Verge

@testable import PixelEngine

final class LoadingTests: XCTestCase {
  
  var subs = Set<VergeAnyCancellable>()
  
  func testOrientation() throws {
    
    func fetch(image: ImageProvider) -> ImageProvider.State.ImageMetadata {
               
      image.start()
      
      let exp = expectation(description: "")
      var result: ImageProvider.State.ImageMetadata?
      
      image.sinkState { (state) in
        
        state.ifChanged(\.metadata) { metadata in
          
          if let metadata = metadata {
            result = metadata
            exp.fulfill()
          }
          
        }
      }
      .store(in: &subs)
      
      wait(for: [exp], timeout: 10)
      withExtendedLifetime(subs) {}
      
      return result!
    }
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5528", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.right.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5529", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.down.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5530", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.left.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5531", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.up.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5532", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.leftMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5533", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.downMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5534", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.rightMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5535", ofType: "HEIC"))).orientation.rawValue, CGImagePropertyOrientation.upMirrored.rawValue)
    
  }
  
  func testBasic() throws {
    
    let stack = EditingStack(imageProvider: try .init(fileURL: _url(forResource: "gaku", ofType: "jpeg")))
    
    let exp = expectation(description: "")
    
    let subs = stack.sinkState { (state) in
      
      if state.loadedState != nil {
        exp.fulfill()
      }
    }
    
    stack.start()
    
    wait(for: [exp], timeout: 10)
    withExtendedLifetime(subs) {}
  }
}

func _url(forResource: String, ofType: String) -> URL {
  _pixelengine_bundle.path(
    forResource: forResource,
    ofType: ofType
  ).map {
    URL(fileURLWithPath: $0)
  }!
}

let _pixelengine_bundle = Bundle.init(for: Dummy.self)

fileprivate final class Dummy {}
