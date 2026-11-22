import BrightroomColorAdjustmentKernels
import CoreImage

nonisolated enum DetailRecipe {

  private static let kernel: Result<CIColorKernel, any Error> = Result {
    try CIColorKernel(functionName: "brightroomStandardDetail", fromMetalLibraryData: ColorAdjustmentMetalLibrary.data())
  }

  static func apply(to image: CIImage, amount: Double, radius: Double) throws -> CIImage {
    try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomStandardDetail") { input in
      let guide = input.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: input.extent)
      guard let output = try kernel.get().apply(extent: input.extent, arguments: [input, guide, amount / 100]) else {
        throw FeatureEvaluationError.imageCreationFailed("brightroomStandardDetail")
      }
      return output.cropped(to: image.extent)
    }
  }
}
