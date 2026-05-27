import MetalKit
import UIKit

/// Describes how a Metal-backed preview surface should be presented.
///
/// Core Image renders into the drawable using `outputColorSpace`, and the
/// `CAMetalLayer` is tagged with the same color space so Core Animation can
/// color-match the layer while compositing it into the current display.
struct MetalDisplayColorConfiguration {
  /// The color space encoded into the drawable's pixel values.
  let outputColorSpace: CGColorSpace

  /// The drawable texture format used by the Metal layer.
  let pixelFormat: MTLPixelFormat

  /// Whether the layer should present values above SDR white when available.
  let allowsExtendedDynamicRangeContent: Bool
}

enum MetalDisplayColorManagement {
  /// The default SDR output space for displays that do not advertise P3 gamut.
  static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  /// The SDR wide-color output space used on P3 displays.
  static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) ?? sRGB

  static func configuration(
    for traitCollection: UITraitCollection,
    prefersWideColorPixelFormat: Bool,
    allowsExtendedDynamicRangeContent: Bool
  ) -> MetalDisplayColorConfiguration {
    let isP3Display = traitCollection.displayGamut == .P3
    return .init(
      outputColorSpace: isP3Display ? displayP3 : sRGB,
      pixelFormat: pixelFormat(
        isP3Display: isP3Display,
        prefersWideColorPixelFormat: prefersWideColorPixelFormat
      ),
      allowsExtendedDynamicRangeContent: allowsExtendedDynamicRangeContent
    )
  }

  static func apply(
    _ configuration: MetalDisplayColorConfiguration,
    to view: MTKView
  ) {
    view.colorPixelFormat = configuration.pixelFormat

    guard let metalLayer = view.layer as? CAMetalLayer else {
      return
    }

    metalLayer.colorspace = configuration.outputColorSpace
    if #available(iOS 16, *) {
      metalLayer.wantsExtendedDynamicRangeContent =
        configuration.allowsExtendedDynamicRangeContent
    }
  }

  private static func pixelFormat(
    isP3Display: Bool,
    prefersWideColorPixelFormat: Bool
  ) -> MTLPixelFormat {
    guard isP3Display, prefersWideColorPixelFormat else {
      return .bgra8Unorm
    }

    #if targetEnvironment(simulator)
    return .bgra8Unorm
    #else
    return .bgr10a2Unorm
    #endif
  }
}
