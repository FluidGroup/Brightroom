import BrightroomColorAdjustmentKernels
import CoreImage

nonisolated enum ColorGradingRecipe {

  private static let kernel: Result<CIColorKernel, any Error> = Result {
    try CIColorKernel(functionName: "brightroomStandardColorGrading", fromMetalLibraryData: ColorAdjustmentMetalLibrary.data())
  }

  static func apply(to image: CIImage, grading: ColorGradingFeature) throws -> CIImage {
    try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomStandardColorGrading") { input in
      guard let output = try kernel.get().apply(extent: input.extent, arguments: [
        input, vector(grading.shadows), vector(grading.midtones), vector(grading.highlights),
        vector(grading.global), grading.blending / 100, grading.balance / 100,
      ]) else {
        throw FeatureEvaluationError.imageCreationFailed("brightroomStandardColorGrading")
      }
      return output.cropped(to: image.extent)
    }
  }

  private static func vector(_ correction: ColorGradingFeature.Correction) -> CIVector {
    let hue = correction.hue / 60
    let x = 1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)
    let rgb: SIMD3<Double>
    switch Int(hue) {
    case 0: rgb = SIMD3(1, x, 0)
    case 1: rgb = SIMD3(x, 1, 0)
    case 2: rgb = SIMD3(0, 1, x)
    case 3: rgb = SIMD3(0, x, 1)
    case 4: rgb = SIMD3(x, 0, 1)
    default: rgb = SIMD3(1, 0, x)
    }
    let luminance = rgb.x * 0.228974564 + rgb.y * 0.691738522 + rgb.z * 0.079286914
    let tint = (rgb - SIMD3(repeating: luminance)) * (correction.saturation / 100 * 0.15)
    return CIVector(x: tint.x, y: tint.y, z: tint.z, w: correction.luminance / 100)
  }
}
