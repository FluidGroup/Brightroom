import BrightroomColorAdjustmentKernels
import CoreImage

nonisolated enum TonalPointRecipe {

  enum Control { case whites, blacks }

  private static let kernel: Result<CIColorKernel, any Error> = Result {
    try CIColorKernel(functionName: "brightroomStandardTonalPoint", fromMetalLibraryData: ColorAdjustmentMetalLibrary.data())
  }

  static func apply(to image: CIImage, control: Control, amount: Double) throws -> CIImage {
    try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomStandardTonalPoint") { input in
      guard let output = try kernel.get().apply(
        extent: input.extent,
        arguments: [input, control == .whites ? amount / 100 : 0, control == .blacks ? amount / 100 : 0]
      ) else {
        throw FeatureEvaluationError.imageCreationFailed("brightroomStandardTonalPoint")
      }
      return output.cropped(to: image.extent)
    }
  }
}
