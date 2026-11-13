// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

/// Measures neighborhood darkness and atmospheric luminance on a reduced image.
/// The original pixels receive the selected response at the output resolution.
nonisolated enum DehazeRecipe {

  private struct Kernels {
    let guides: CIColorKernel
    let darkChannel: CIColorKernel
    let normalize: CIColorKernel
    let coverage: CIColorKernel
    let response: CIKernel
  }

  private static let kernels: Result<Kernels, FeatureEvaluationError> = {
    do {
      let library = try ColorAdjustmentMetalLibrary.data()
      return .success(Kernels(
        guides: try CIColorKernel(functionName: "brightroomDehazeGuides", fromMetalLibraryData: library),
        darkChannel: try CIColorKernel(functionName: "brightroomDehazeDarkChannel", fromMetalLibraryData: library),
        normalize: try CIColorKernel(functionName: "brightroomDehazeNormalize", fromMetalLibraryData: library),
        coverage: try CIColorKernel(functionName: "brightroomDehazeCoverage", fromMetalLibraryData: library),
        response: try CIKernel(functionName: "brightroomDehaze", fromMetalLibraryData: library)))
    } catch {
      return .failure(.kernelUnavailable(name: "brightroomDehaze", reason: String(describing: error)))
    }
  }()

  static func apply(to image: CIImage, amount: Double) throws -> CIImage {
    let bounds = image.extent
    guard !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite else {
      throw FeatureEvaluationError.imageCreationFailed("Dehaze requires a finite input extent")
    }
    let kernels = try kernels.get()
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomDehaze") { input in
      let origin = bounds.origin
      let localInput = input.transformed(by: .init(translationX: -origin.x, y: -origin.y))
      guard let fields = kernels.guides.apply(extent: localInput.extent, arguments: [localInput]) else {
        throw FeatureEvaluationError.imageCreationFailed("Dehaze input guides")
      }
      let longEdge = max(bounds.width, bounds.height)
      let scale = min(1, 1024 / longEdge)
      let extent = localInput.extent.applying(.init(scaleX: scale, y: scale))
      let guides = fields.clampedToExtent().applyingFilter("CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: scale, "inputAspectRatio": 1]).cropped(to: extent)
      let radius = max(0.5, 16 * longEdge * scale / 1024)
      let diameter = Int(radius.rounded()) * 2 + 1
      func blur(_ source: CIImage, radius: CGFloat) -> CIImage {
        source.clampedToExtent().applyingFilter("CIGaussianBlur",
          parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
      }
      guard let dark = kernels.darkChannel.apply(extent: extent, arguments: [guides]),
        let broad = kernels.normalize.apply(extent: extent, arguments: [blur(guides, radius: radius * 4)])
      else { throw FeatureEvaluationError.imageCreationFailed("Dehaze neighborhood guides") }
      let minimum = dark.clampedToExtent().applyingFilter("CIMorphologyRectangleMinimum",
        parameters: ["inputWidth": diameter, "inputHeight": diameter]).cropped(to: extent)
      let local = blur(minimum, radius: radius / 3)
      guard let weighted = kernels.coverage.apply(extent: extent, arguments: [local, guides]) else {
        throw FeatureEvaluationError.imageCreationFailed("Dehaze scene coverage")
      }
      let region = [kCIInputExtentKey: CIVector(cgRect: extent)]
      let mean = weighted.applyingFilter("CIAreaAverage", parameters: region)
      let peak = broad.applyingFilter("CIAreaMaximum", parameters: region)
      let geometry = CIVector(x: origin.x, y: origin.y, z: scale)
      guard let result = kernels.response.apply(extent: bounds, roiCallback: { index, rect in
        switch index {
        case 0: return rect
        case 1, 2:
          return rect.offsetBy(dx: -origin.x, dy: -origin.y)
            .applying(.init(scaleX: scale, y: scale)).insetBy(dx: -1, dy: -1)
        case 3: return mean.extent
        default: return peak.extent
        }
      }, arguments: [input, local.clampedToExtent(), broad.clampedToExtent(), mean, peak, geometry, Float(amount)])
      else { throw FeatureEvaluationError.imageCreationFailed("brightroomDehaze") }
      return result.cropped(to: bounds)
    }
  }
}
