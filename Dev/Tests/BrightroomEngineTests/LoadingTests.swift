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

import CoreImage
import XCTest
import StateGraph

@testable import BrightroomEngine

final class LoadingTests: XCTestCase {

  var subscriptions: [Any] = []

  func testOrientation() throws {

    func fetch(image: ImageProvider) -> CGImagePropertyOrientation {

      image.start()

      let exp = expectation(description: "")
      var result: CGImagePropertyOrientation?
      var previousOrientation: CGImagePropertyOrientation?

      let subscription = withGraphTracking {
        withGraphTrackingGroup {
          let orientation = image.orientation
          if orientation != previousOrientation {
            previousOrientation = orientation
            if let orientation = orientation {
              result = orientation
              exp.fulfill()
            }
          }
        }
      }
      subscriptions.append(subscription)

      wait(for: [exp], timeout: 10)
      withExtendedLifetime(subscriptions) {}

      return result!
    }
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_right", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.right.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_down", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.down.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_left", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.left.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_up", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.up.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_left_mirrored", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.leftMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_down_mirrored", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.downMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_right_mirrored", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.rightMirrored.rawValue)
    
    XCTAssertEqual(fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_up_mirrored", ofType: "HEIC"))).rawValue, CGImagePropertyOrientation.upMirrored.rawValue)
    
  }

}

final class ColorCubeTextParserTests: XCTestCase {

  func testParseCubeDataInCoreImageOrder() throws {
    let parsedCube = try ColorCubeTextParser().parse(Self.identityCube(size: 2, title: "Identity 2"))

    XCTAssertEqual(parsedCube.title, "Identity 2")
    XCTAssertEqual(parsedCube.dimension, 2)

    let values = parsedCube.cubeData.withUnsafeBytes {
      Array($0.bindMemory(to: Float.self))
    }

    XCTAssertEqual(values.count, 2 * 2 * 2 * 4)
    XCTAssertEqual(Array(values[0..<4]), [0, 0, 0, 1])
    XCTAssertEqual(Array(values[4..<8]), [1, 0, 0, 1])
    XCTAssertEqual(Array(values[8..<12]), [0, 1, 0, 1])
    XCTAssertEqual(Array(values[28..<32]), [1, 1, 1, 1])
  }

  func testRejectsNonDefaultDomain() throws {
    let cube = """
    LUT_3D_SIZE 2
    DOMAIN_MIN -0.5 0.0 0.0
    DOMAIN_MAX 1.0 1.0 1.0
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """

    XCTAssertThrowsError(try ColorCubeTextParser().parse(cube)) { error in
      XCTAssertEqual(
        error as? ColorCubeTextParserError,
        .unsupportedDomain(domainMin: [-0.5, 0, 0], domainMax: [1, 1, 1])
      )
    }
  }

  func testColorCubeLoaderLoadsCubeFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("bundle")

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    try Self.identityCube(size: 2, title: "Bundle Look").write(
      to: directory.appendingPathComponent("BundleLook.cube"),
      atomically: true,
      encoding: .utf8
    )

    let bundle = try XCTUnwrap(Bundle(url: directory))
    let filters = try ColorCubeLoader(bundle: bundle).load()

    XCTAssertEqual(filters.count, 1)
    XCTAssertEqual(filters[0].name, "Bundle Look")
    XCTAssertEqual(filters[0].identifier, "BundleLook.cube")
    XCTAssertEqual(filters[0].dimension, 2)

    guard case .cubeData(let cubeData, let dimension) = filters[0].lookupTable else {
      XCTFail("Expected cube data lookup table.")
      return
    }

    XCTAssertEqual(dimension, 2)
    XCTAssertEqual(cubeData.count, 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
  }

  func testCubeDataFilterCreatesOutputImage() throws {
    let parsedCube = try ColorCubeTextParser().parse(Self.identityCube(size: 2, title: "Identity 2"))
    let filter = FilterColorCube(
      name: "Identity 2",
      identifier: "Identity2.cube",
      cubeData: parsedCube.cubeData,
      dimension: parsedCube.dimension
    )

    let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
      .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

    let outputImage = filter.apply(to: image, sourceImage: image)

    XCTAssertEqual(outputImage.extent, image.extent)
  }

  private static func identityCube(size: Int, title: String) -> String {
    let divisor = Float(size - 1)
    var lines = [
      "# comment",
      "TITLE \"\(title)\"",
      "LUT_3D_SIZE \(size)",
      "DOMAIN_MIN 0.0 0.0 0.0",
      "DOMAIN_MAX 1.0 1.0 1.0",
    ]

    for blueIndex in 0..<size {
      for greenIndex in 0..<size {
        for redIndex in 0..<size {
          let red = Float(redIndex) / divisor
          let green = Float(greenIndex) / divisor
          let blue = Float(blueIndex) / divisor
          lines.append("\(red) \(green) \(blue)")
        }
      }
    }

    return lines.joined(separator: "\n")
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
