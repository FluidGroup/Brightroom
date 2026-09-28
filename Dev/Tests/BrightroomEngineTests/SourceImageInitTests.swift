//
//  SourceImageInitTests.swift
//  BrightroomEngineTests
//
//  Created by Antoine Marandon on 28/05/2021.
//  Copyright © 2021 muukii. All rights reserved.
//

import Testing
import Foundation
import UIKit
@testable import BrightroomEngine

struct SourceImageInitTests {
  let imageTypes =  ["HEIC", "jpg", "jpeg", "png", "DNG", "gif"]
  let imagePaths: [String]

  init() throws {
    var paths = [String]()
    for imageType in imageTypes {
      paths.append(contentsOf: Bundle(for: BundleToken.self) .paths(forResourcesOfType: imageType, inDirectory: nil))
    }
    imagePaths = paths
  }

  @Test func sourceImageCreation() throws {
    // The fixtures include truncated and corrupt files (a decoder corpus).
    // Such a file must throw instead of producing an image without a size.
    var readCount = 0
    for imagePath in imagePaths {
      let decoded = UIImage(contentsOfFile: imagePath).flatMap(\.cgImage)

      // A file read through ImageIO.
      let fromFile: SourceImage
      do {
        fromFile = try SourceImage(contentsOf: URL(fileURLWithPath: imagePath))
      } catch {
        #expect(decoded == nil, "\(imagePath) decodes but could not be read: \(error)")
        continue
      }
      readCount += 1
      #expect(fromFile.pixelSize.width > 0 && fromFile.pixelSize.height > 0)

      // A header can be readable while the pixels are not; only decodable
      // files are rendered.
      guard let image = UIImage(contentsOfFile: imagePath), image.cgImage != nil else {
        continue
      }
      Self.exercise(fromFile)

      // A decoded UIImage.
      let fromImage = SourceImage(image: image)
      Self.exercise(fromImage)
      // UIImage may decode a RAW file's embedded preview instead.
      if imagePath.hasSuffix(".DNG") == false {
        #expect(fromImage.pixelSize == fromFile.pixelSize, "\(imagePath)")
      }
    }
    #expect(readCount > 100)
  }

  private static func exercise(_ image: SourceImage) {
    #expect(image.pixelSize.width > 0 && image.pixelSize.height > 0)
    #expect(image.makeCIImage().extent == CGRect(origin: .zero, size: image.pixelSize))
    let small = image.makeCIImage(maxPixelSize: 10)
    #expect(small.extent.origin == .zero)
    #expect(max(small.extent.width, small.extent.height) <= 10.5)
    #expect(image.storage.makeResizedCGImage(shortSideLength: 10) != nil)
  }
}

private final class BundleToken {}
