//
//  CGContextCreationTests.swift
//  BrightroomEngineTests
//
//  Created by Muukii on 2021/06/05.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import Testing
import UIKit

@testable import BrightroomEngine

struct CGContextCreationTests {

  @Test func `create cgcontext`() {

    (1...12).forEach { i in
      let imageName = "test-image-\(i)"
      let cgImage = UIImage(named: imageName, in: _pixelengine_bundle, with: nil)!.cgImage!
      do {
        _ = try CGContext.makeContext(for: cgImage)
      } catch {
        print("❌===")
        print(cgImage.colorSpace as Any)
        print(imageName, error.localizedDescription)
        print("===")
        Issue.record("\(error.localizedDescription)")
      }
    }

  }
}
