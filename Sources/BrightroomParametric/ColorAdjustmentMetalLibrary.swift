import Foundation

/// Locates the package-owned general Core Image kernels for this platform.
///
/// These legacy Core Image libraries are compiled with `-fcikernel`. Keeping
/// them separate from the live brush shaders preserves the sampler ABI without
/// requiring client-specific Metal linker settings or runtime source compilation.
enum ColorAdjustmentMetalLibrary {

  static func data() throws -> Data {
    #if targetEnvironment(macCatalyst)
      let platform = "catalyst"
    #elseif os(iOS)
      #if targetEnvironment(simulator)
        let platform = "simulator"
      #else
        let platform = "ios"
      #endif
    #elseif os(macOS)
      let platform = "macos"
    #else
      #error("Color adjustment kernels require iOS, Mac Catalyst, or macOS.")
    #endif

    let name = "BrightroomColorAdjustments-\(platform)"
    guard let url = Bundle.module.url(forResource: name, withExtension: "metallib") else {
      throw ColorAdjustmentMetalLibraryError.missingResource(name)
    }
    return try Data(contentsOf: url)
  }
}

/// A required platform kernel library was not packaged with BrightroomParametric.
enum ColorAdjustmentMetalLibraryError: Error {
  case missingResource(String)
}
