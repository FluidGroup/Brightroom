//
//  CGContextCreationTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/06/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import XCTest

@testable import BrightroomEngine

final class CGContextCreationTests: XCTestCase {

  func test_create_cgcontext() {

    (1...13).forEach { i in
      let imageName = "test-image-\(i)"
      let cgImage = UIImage(named: imageName, in: _pixelengine_bundle, with: nil)!.cgImage!
      do {
        _ = try CGContext.makeContext(for: cgImage)
      } catch {
        print("❌===")
        print(cgImage.colorSpace)
        print(imageName, error.localizedDescription)
        print("===")
        XCTFail(error.localizedDescription)
      }
    }

  }
}
