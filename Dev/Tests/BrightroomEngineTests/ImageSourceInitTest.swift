//
//  ImageSourceInitTest.swift
//  BrightroomEngineTests
//
//  Created by Antoine Marandon on 28/05/2021.
//  Copyright © 2021 muukii. All rights reserved.
//

import Testing
import Foundation
import UIKit
@testable import BrightroomEngine

struct ImageSourceInitTest {
  let imageTypes =  ["HEIC", "jpg", "jpeg", "png", "DNG", "gif"]
  let imagePaths: [String]

  init() throws {
    var paths = [String]()
    for imageType in imageTypes {
      paths.append(contentsOf: Bundle(for: BundleToken.self) .paths(forResourcesOfType: imageType, inDirectory: nil))
    }
    imagePaths = paths
  }

  @Test func imageSourceCreation() throws {
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

private final class BundleToken {}
