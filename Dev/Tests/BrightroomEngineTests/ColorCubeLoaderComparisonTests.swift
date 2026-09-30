//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import ImageIO
import Testing

@testable import BrightroomEngine
import BrightroomParametric

/// A one-time comparison, before the Engine LUT loader is removed: the
/// demo's bundled LUT images read through `ColorCubeLoader` and through
/// `ColorCubeFeature(contentsOfCubeImage:)` give the same cube and render a
/// photo the same.
struct ColorCubeLoaderComparisonTests {

  @Test func `Engine and Parametric LUT image loaders agree on the bundled LUTs`() throws {
    let lutDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("../../Bundle/LUTs")
      .standardizedFileURL
    let names = try FileManager.default.contentsOfDirectory(atPath: lutDirectory.path)
      .filter { $0.hasPrefix("LUT_") }
      .sorted()
    #expect(names.count == 5)

    // ColorCubeLoader scans the root of a bundle.
    let bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("bundle")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: bundleURL)
    }
    for name in names {
      try FileManager.default.copyItem(
        at: lutDirectory.appendingPathComponent(name),
        to: bundleURL.appendingPathComponent(name)
      )
    }
    let bundle = try #require(Bundle(url: bundleURL))
    let engineCubes = try ColorCubeLoader(bundle: bundle).load()
    #expect(engineCubes.map(\.id) == names)

    let photo = try Self.makePhoto()
    let renderer = FeatureRenderer()
    let context = CIContext(options: [.cacheIntermediates: false])
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let unfilteredBytes = Self.rgba8(
      try renderer.makeImage(from: photo, feature: EmptyFeature()),
      context: context,
      colorSpace: sRGB
    )

    for engineCube in engineCubes {
      let url = bundleURL.appendingPathComponent(engineCube.id)
      let parametricCube = try ColorCubeFeature(
        contentsOfCubeImage: url,
        dimension: engineCube.dimension
      )
      #expect(parametricCube.dimension == engineCube.dimension)

      let engineValues = Self.floats(of: engineCube.cubeData)
      let parametricValues = Self.floats(of: parametricCube.cubeData)
      #expect(engineValues.count == parametricValues.count)
      let cubeDifference = zip(engineValues, parametricValues)
        .reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }

      // Distinct ids so the render cache cannot hand one cube's filter to
      // the other.
      var engineFeature = engineCube
      engineFeature.id = "engine/" + engineCube.id
      var parametricFeature = parametricCube
      parametricFeature.id = "parametric/" + engineCube.id

      let engineBytes = try Self.rgba8(
        renderer.makeImage(from: photo, feature: engineFeature),
        context: context,
        colorSpace: sRGB
      )
      let parametricBytes = try Self.rgba8(
        renderer.makeImage(from: photo, feature: parametricFeature),
        context: context,
        colorSpace: sRGB
      )
      let renderDifference = zip(engineBytes, parametricBytes)
        .reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
      let changedChannels = zip(engineBytes, parametricBytes).filter { $0 != $1 }.count
      // The LUT must change the photo, or equal renders prove nothing.
      let lutEffect = zip(unfilteredBytes, parametricBytes)
        .reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
      let imageSpace = CGImageSourceCreateWithURL(url as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?
        .colorSpace?.name.map { $0 as String } ?? "unnamed"

      print(
        "LUT comparison \(engineCube.id) (\(imageSpace)): dimension \(engineCube.dimension),"
          + " max cube difference \(cubeDifference),"
          + " max RGBA8 difference \(renderDifference),"
          + " changed channels \(changedChannels)/\(engineBytes.count),"
          + " max LUT effect on the photo \(lutEffect)"
      )
      #expect(lutEffect > 8)
      #expect(cubeDifference <= 0.000_1)
      #expect(renderDifference <= 1)
    }
  }

  /// A test photo scaled to about 1024 pixels wide.
  private static func makePhoto() throws -> CIImage {
    let source = try SourceImage(contentsOf: _url(forResource: "orientation_up", ofType: "HEIC"))
    let image = source.makeCIImage()
    let scale = 1024 / image.extent.width
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return scaled.cropped(to: scaled.extent.integral.insetBy(dx: 1, dy: 1))
  }

  private static func floats(of data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  private static func rgba8(
    _ image: CIImage,
    context: CIContext,
    colorSpace: CGColorSpace
  ) -> [UInt8] {
    let extent = image.extent
    let width = Int(extent.width)
    let height = Int(extent.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      context.render(
        image,
        toBitmap: buffer.baseAddress!,
        rowBytes: width * 4,
        bounds: extent,
        format: .RGBA8,
        colorSpace: colorSpace
      )
    }
    return bytes
  }
}
