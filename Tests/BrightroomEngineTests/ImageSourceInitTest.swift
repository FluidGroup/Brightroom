//
//  ImageSourceInitTest.swift
//  BrightroomEngineTests
//
//  Created by Antoine Marandon on 28/05/2021.
//  Copyright © 2021 muukii. All rights reserved.
//

import XCTest
import UIKit
@testable import BrightroomEngine

class ImageSourceInitTest: XCTestCase {
  let imageTypes =  ["HEIC", "jpg", "jpeg", "png", "DNG", "gif"]
  var imagePaths: [String]!

  override func setUpWithError() throws {
    var paths = [String]()
    for imageType in imageTypes {
      paths.append(contentsOf: Bundle(for: Self.self) .paths(forResourcesOfType: imageType, inDirectory: nil))
    }
    imagePaths = paths
  }

  func testImageSourceCreation() throws {
    for imagePath in imagePaths {
      guard
        let image = UIImage(contentsOfFile: imagePath),
        image.cgImage != nil else {
        continue
      }
      let imageSource = ImageSource(image: image)
      _ = imageSource.readImageSize()
      _ = imageSource.loadOriginalCGImage()
      _ = imageSource.loadThumbnailCGImage(maxPixelSize: 10)
      _ = imageSource.makeOriginalCIImage()
      // basically test that no crash happen...
    }
  }
}
