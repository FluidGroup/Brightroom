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
import Foundation
import StateGraph
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric

// Kept on the main actor: the original `testOrientation` ran as a synchronous
// XCTest method (implicitly main-actor isolated) and observes the reactive
// `ImageProvider.orientation` through StateGraph on that actor.
@MainActor
struct LoadingTests {

  @Test(.timeLimit(.minutes(1)))
  func orientation() async throws {

    var subscriptions: [Any] = []

    func fetch(image: ImageProvider) async -> CGImagePropertyOrientation {

      image.start()

      var previousOrientation: CGImagePropertyOrientation?

      return await withCheckedContinuation { continuation in
        var didResume = false
        let subscription = withGraphTracking {
          withGraphTrackingGroup {
            let orientation = image.orientation
            if orientation != previousOrientation {
              previousOrientation = orientation
              if let orientation = orientation, !didResume {
                didResume = true
                continuation.resume(returning: orientation)
              }
            }
          }
        }
        subscriptions.append(subscription)
      }
    }

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_right", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.right.rawValue)

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_down", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.down.rawValue)

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_left", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.left.rawValue)

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_up", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.up.rawValue)

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_left_mirrored", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.leftMirrored.rawValue)

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_down_mirrored", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.downMirrored.rawValue)

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_right_mirrored", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.rightMirrored.rawValue)

    #expect(await fetch(image: try ImageProvider(fileURL: _url(forResource: "orientation_up_mirrored", ofType: "HEIC"))).rawValue == CGImagePropertyOrientation.upMirrored.rawValue)

    withExtendedLifetime(subscriptions) {}
  }

}

struct ColorCubeTextParserTests {

  @Test func `Parse cube data in Core Image order`() throws {
    let parsedCube = try ColorCubeTextParser().parse(Self.identityCube(size: 2, title: "Identity 2"))

    #expect(parsedCube.title == "Identity 2")
    #expect(parsedCube.dimension == 2)

    let values = parsedCube.cubeData.withUnsafeBytes {
      Array($0.bindMemory(to: Float.self))
    }

    #expect(values.count == 2 * 2 * 2 * 4)
    #expect(Array(values[0..<4]) == [0, 0, 0, 1])
    #expect(Array(values[4..<8]) == [1, 0, 0, 1])
    #expect(Array(values[8..<12]) == [0, 1, 0, 1])
    #expect(Array(values[28..<32]) == [1, 1, 1, 1])
  }

  @Test func `Rejects non-default domain`() throws {
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

    #expect(throws: ColorCubeTextParserError.unsupportedDomain(domainMin: [-0.5, 0, 0], domainMax: [1, 1, 1])) {
      try ColorCubeTextParser().parse(cube)
    }
  }

  @Test func `Color cube loader loads cube files`() throws {
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

    let bundle = try #require(Bundle(url: directory))
    let filters = try ColorCubeLoader(bundle: bundle).load()

    #expect(filters.count == 1)
    #expect(filters[0].name == "Bundle Look")
    #expect(filters[0].identifier == "BundleLook.cube")
    #expect(filters[0].dimension == 2)
    #expect(filters[0].cubeData.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
  }

  @Test func `Cube data filter creates output image`() throws {
    let parsedCube = try ColorCubeTextParser().parse(Self.identityCube(size: 2, title: "Identity 2"))
    let filter = ColorCubeFeature(
      name: "Identity 2",
      identifier: "Identity2.cube",
      dimension: parsedCube.dimension,
      cubeData: parsedCube.cubeData
    )

    let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
      .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

    let outputImage = try filter.apply(to: image, context: FeatureEvaluationContext())

    #expect(outputImage.extent == image.extent)
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
