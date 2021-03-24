//
//  LoadingTests.swift
//  PixelEngine
//
//  Created by Muukii on 2021/03/25.
//  Copyright © 2021 muukii. All rights reserved.
//

import XCTest

@testable import PixelEngine

final class LoadingTests: XCTestCase {
  
  
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
