// Host-side experiment, intentionally outside the library's stable feature API.
import BrightroomColorAdjustmentKernels
import BrightroomParametric
import CoreImage
import Foundation

/// Applies chart-measured Whites, Blacks and Saturation deltas to developed RGB.
///
/// Highlights/Shadows remain separate because they need image-dependent behavior.
/// Positive Whites also has a known chart-to-photo mismatch. This experiment is
/// useful for diagnosis and the supplied presets, not general Adobe compatibility.
/// This host experiment reuses the versioned comparison kernel's three-table
/// evaluator. Its table layout and kernel name are internal implementation details.
nonisolated struct MeasuredLightFeature: ImageEffect, Equatable {

  private let data: Data
  private let tables: [CIImage]
  private let isIdentity: Bool

  init(tableURL: URL) throws {
    let data = try Data(contentsOf: tableURL)
    let tableBytes = 32 * 32 * 32 * 4 * MemoryLayout<Float>.stride
    precondition(data.count == 3 * tableBytes, "Invalid Light tables")
    self.data = data
    let values = data.withUnsafeBytes { bytes in
      stride(from: 0, to: data.count, by: 4).map {
        bytes.loadUnaligned(fromByteOffset: $0, as: Float.self)
      }
    }
    precondition(values.allSatisfy(\.isFinite))
    isIdentity = values.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 0 }
    tables = (0..<3).map { index in
      CIImage(bitmapData: data.subdata(in: (index * tableBytes)..<((index + 1) * tableBytes)),
        bytesPerRow: 32 * 16, size: CGSize(width: 32, height: 1024), format: .RGBAf, colorSpace: nil)
    }
  }

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard !isIdentity else { return image }
    let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let kernel = try Self.kernel.get()
    guard let input = image.matchedFromWorkingSpace(to: space),
      let result = kernel.apply(extent: input.extent,
        roiCallback: { index, rect in
          if index == 0 { return rect }
          return tables[Int(index) - 1].extent
        }, arguments: [input, tables[0], tables[1], tables[2], Float(32)]),
      let output = result.matchedToWorkingSpace(from: space)
    else {
      throw FeatureEvaluationError.imageCreationFailed("Measured Light experiment")
    }
    return output.cropped(to: image.extent)
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.data == rhs.data }

  private static let kernel: Result<CIKernel, any Error> = Result {
    try CIKernel(functionName: "brightroomCalibratedColorMixer",
      fromMetalLibraryData: ColorAdjustmentMetalLibrary.data())
  }
}
