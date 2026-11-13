// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

/// Evaluates the measured global saturation response over straight, linear Display-P3 colors.
nonisolated enum SaturationRecipe {

  private static let dimension = 32
  private static let strengths = [-1.0, -0.5, -0.25, -0.1, 0, 0.1, 0.25, 0.5, 1]

  /// Compiles a small RGB table for the authored strength, then samples it over the image.
  static func apply(to image: CIImage, strength: Double) throws -> CIImage {
    let calibration = try calibration.get()
    let upper = strengths.firstIndex { $0 > strength } ?? (strengths.count - 1)
    let lower = upper - 1
    let interval = strengths[upper] - strengths[lower]
    let t = (strength - strengths[lower]) / interval
    let u = 1 - t
    // Cubic Hermite weights for value and derivative at each end of the interval.
    let weights = CIVector(x: u * u * (1 + 2 * t), y: u * u * t * interval,
      z: t * t * (3 - 2 * t), w: -t * t * u * interval)
    let firstColumn = 2 * lower * dimension
    let extent = CGRect(x: 0, y: 0, width: dimension, height: dimension * dimension)
    guard let table = calibration.interpolation.apply(extent: extent,
      roiCallback: { _, rect in
        rect.offsetBy(dx: CGFloat(firstColumn), dy: 0)
          .union(rect.offsetBy(dx: CGFloat(firstColumn + 3 * dimension), dy: 0))
      }, arguments: [calibration.atlas, Float(firstColumn), Float(dimension), weights])
    else { throw FeatureEvaluationError.imageCreationFailed("Global saturation table") }

    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomGlobalSaturation") { input in
      guard let result = calibration.response.apply(extent: input.extent,
        roiCallback: { index, rect in index == 0 ? rect : extent },
        arguments: [input, table, Float(strength), Float(dimension)])
      else { throw FeatureEvaluationError.imageCreationFailed("Global saturation") }
      return result
    }
  }

  /// The authored slider selects two of nine knots in the immutable half-float atlas.
  private struct Calibration {
    let atlas: CIImage
    let interpolation: CIKernel
    let response: CIKernel
  }

  private static let calibration: Result<Calibration, FeatureEvaluationError> = {
    do {
      guard let url = Bundle.module.url(forResource: "SaturationCalibration", withExtension: "lzfse")
      else { throw FeatureEvaluationError.imageCreationFailed("Missing saturation calibration") }
      let compressed = try Data(contentsOf: url) as NSData
      let data = try compressed.decompressed(using: .lzfse) as Data
      let width = 2 * strengths.count * dimension
      let height = dimension * dimension
      guard data.count == 16 + width * height * 8, data.prefix(8) == Data("BRSAT001".utf8),
        data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian }) == dimension,
        data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }) == strengths.count
      else { throw FeatureEvaluationError.imageCreationFailed("Invalid saturation calibration") }
      let atlas = CIImage(bitmapData: data.subdata(in: 16..<data.count), bytesPerRow: width * 8,
        size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: nil)
      let library = try ColorAdjustmentMetalLibrary.data()
      return .success(try Calibration(atlas: atlas,
        interpolation: CIKernel(functionName: "brightroomSaturationTable", fromMetalLibraryData: library),
        response: CIKernel(functionName: "brightroomGlobalSaturation", fromMetalLibraryData: library)))
    } catch let error as FeatureEvaluationError {
      return .failure(error)
    } catch {
      return .failure(.kernelUnavailable(name: "Global saturation", reason: String(describing: error)))
    }
  }()
}
