//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import XCTest
import Verge

@testable import BrightroomEngine

final class LoadingTests: XCTestCase {
  
  var subs = Set<VergeAnyCancellable>()
  
  func testOrientation() throws {
    
    func fetch(image: ImageProvider) -> CGImagePropertyOrientation {
               
      image.start()
      
      let exp = expectation(description: "")
      var result: CGImagePropertyOrientation?
      
      image.sinkState { (state) in
        
        state.ifChanged(\.orientation) { orientation in
          result = orientation
          exp.fulfill()
        }
        
      }
      .store(in: &subs)
      
      wait(for: [exp], timeout: 10)
      withExtendedLifetime(subs) {}
      
      return result!
    }
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5528", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.right.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5529", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.down.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5530", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.left.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5531", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.up.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5532", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.leftMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5533", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.downMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5534", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.rightMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "IMG_5535", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.upMirrored.rawValue)
    
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
