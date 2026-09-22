import CoreGraphics
import Foundation
import ImageIO

import BrightroomParametric

public enum ColorCubeLoaderError: Error {
  case failedToGetDimensionFromFilename(String)
  case failedToCreageCGDataProvider(String)
  case failedToCraeteCGImageSource(String)
  case failedToCreateCGImage(String)
  case unsupportedFileExtension(String)
}

/// An object for loading color-cube LUTs from bundle.
/// It finds image LUTs based on specified naming-rule and also loads `.cube` files.
///
/// `LUT_<Dimension>_<filterName>.<extension {jpg, png}>`
/// `<filterName>.cube`
public final class ColorCubeLoader {
  public let bundle: Bundle

  public init(bundle: Bundle) {
    self.bundle = bundle
  }

  public func load() throws -> [ColorCubeFeature] {
    let rootPath = bundle.bundlePath as NSString
    let fileList = try FileManager.default.contentsOfDirectory(atPath: rootPath as String)

    func takeDimension(from string: String) -> Int? {
      enum Static {
        static let regex: NSRegularExpression = {
          let pattern = "LUT_([0-9]+)_.*"
          let regex = try! NSRegularExpression(pattern: pattern, options: [])
          return regex
        }()
      }

      guard
        let matched = Static.regex.firstMatch(
          in: string,
          options: [],
          range: NSRange(location: 0, length: string.count)
        )
      else {
        return nil
      }

      let numberString = (string as NSString).substring(with: matched.range(at: 1))

      return Int(numberString)
    }

    func name(from path: String, dimension: Int) -> String {
      (path as NSString).deletingPathExtension
        .replacingOccurrences(of: "LUT_\(dimension)_", with: "")
    }

    let parser = ColorCubeTextParser()

    let features =
      try fileList
      .filter {
        let pathExtension = ($0 as NSString).pathExtension.lowercased()
        return $0.hasPrefix("LUT_") || pathExtension == "cube"
      }
      .sorted()
      .map { path -> ColorCubeFeature in

        let url = URL(fileURLWithPath: rootPath.appendingPathComponent(path))
        let pathExtension = (path as NSString).pathExtension.lowercased()

        if pathExtension == "cube" {
          let parsedCube = try parser.parse(contentsOf: url)
          return ColorCubeFeature(
            id: .init(rawValue: path),
            name: parsedCube.title ?? name(from: path, dimension: parsedCube.dimension),
            identifier: path,
            dimension: parsedCube.dimension,
            cubeData: parsedCube.cubeData
          )
        }

        guard ["jpg", "jpeg", "png"].contains(pathExtension) else {
          throw ColorCubeLoaderError.unsupportedFileExtension(path)
        }

        guard let dimension = takeDimension(from: path) else {
          throw ColorCubeLoaderError.failedToGetDimensionFromFilename(path)
        }

        guard let dataProvider = CGDataProvider(url: url as CFURL) else {
          throw ColorCubeLoaderError.failedToCreageCGDataProvider(path)
        }

        guard let imageSource = CGImageSourceCreateWithDataProvider(dataProvider, nil) else {
          throw ColorCubeLoaderError.failedToCraeteCGImageSource(path)
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
          throw ColorCubeLoaderError.failedToCreateCGImage(path)
        }

        // The parametric document stores cube data directly, so image-based
        // LUTs are materialized into float cube data at load time.
        let cubeData = try ColorCubeHelper.createColorCubeData(
          inputImage: cgImage,
          cubeDimension: dimension
        )

        return ColorCubeFeature(
          id: .init(rawValue: path),
          name: name(from: path, dimension: dimension),
          identifier: path,
          dimension: dimension,
          cubeData: cubeData
        )
      }
    return features
  }
}
