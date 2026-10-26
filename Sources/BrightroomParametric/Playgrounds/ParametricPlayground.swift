//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

// Image editing in code with the static composition model.
//
// Open this file in Xcode and run a playground from the canvas. Each
// playground describes an edit as a root feature, a struct whose `body` lists
// features in evaluation order, and ends by rendering it. The canvas shows
// the value of every expression, so changing a value shows the new image.
//
// The playgrounds edit a photo from `Dev/Bundle/Images`, found relative to
// this file, and fall back to a generated image when the repository is not
// reachable (for example on a device). Pass another image to
// `Sample.render(_:from:)` to edit your own.
//
// Debug-only, so release builds never import or link `Playgrounds`.

#if DEBUG && canImport(Playgrounds)

import CoreGraphics
import CoreImage
internal import CoreImage.CIFilterBuiltins
import Foundation
internal import Playgrounds

// MARK: - Adjustments

#Playground("Adjustments") {
  struct PlaygroundFeature: Feature {
    var exposure = ExposureFeature(ev: -0.1)
    var contrast = ContrastFeature(value: 0.1)
    var highlights = HighlightsFeature(value: 0.6)
    var shadows = ShadowsFeature(value: 0.2)
    var saturation = SaturationFeature(value: 0.2)

    var body: some Feature {
      exposure
      contrast
      highlights
      shadows
      saturation
    }
  }

  // Before: an empty feature leaves the image unchanged.
  try Sample.render(EmptyFeature())
  // After.
  try Sample.render(PlaygroundFeature())
}

// MARK: - Reusable look

/// A look made only of image effects.
///
/// The body is `some ImageEffect`, so the look is an `ImageEffect` as well:
/// any root feature can reuse it, it can go inside a `LocalAdjustmentFeature`, and a
/// crop in its body does not compile.
fileprivate struct FilmLook: ImageEffect, Equatable {
  var warmth = 900.0
  var isMonochrome = false

  var body: some ImageEffect {
    if isMonochrome {
      SaturationFeature(value: -1)
      ContrastFeature(value: 0.15)
    } else {
      WhiteBalanceFeature(temperature: warmth)
      SaturationFeature(value: 0.1)
    }
    FadeFeature(intensity: 0.05)
    VignetteFeature(value: 0.8)
  }
}

#Playground("Reusable look") {
  struct PlaygroundFeature: Feature {
    var exposure = ExposureFeature(ev: -0.1)
    var look = FilmLook()

    var body: some Feature {
      exposure
      look
    }
  }

  var feature = PlaygroundFeature()
  try Sample.render(feature)

  feature.look.isMonochrome = true
  try Sample.render(feature)
}

// MARK: - Tone curve and color mixer

#Playground("Tone curve and color mixer") {
  // A gentle S-curve on the luminance channel.
  var curve = ToneCurve()
  curve.insertPoint(input: 0.3, output: 0.24)
  curve.insertPoint(input: 0.7, output: 0.76)

  // Richer reds, greens toward aqua, and the yellow mat toward orange.
  var mix = ColorMixerFeature.Bands()
  mix.red = ColorMixerFeature.BandCorrection(saturation: 40)
  mix.green = ColorMixerFeature.BandCorrection(hue: 40, saturation: 20, luminance: -20)
  mix.yellow = ColorMixerFeature.BandCorrection(hue: -30, saturation: 20)

  struct PlaygroundFeature: Feature {
    var toneCurve: ToneCurveFeature
    var colorMixer: ColorMixerFeature

    var body: some Feature {
      toneCurve
      colorMixer
    }
  }

  let feature = PlaygroundFeature(
    toneCurve: ToneCurveFeature(curves: ToneCurveFeature.Curves(y: curve)),
    colorMixer: ColorMixerFeature(bands: mix)
  )
  try Sample.render(feature)
}

// MARK: - LUT

#Playground("LUT") {
  struct PlaygroundFeature: Feature {
    var exposure = ExposureFeature(ev: 0.1)
    var lut: ColorCubeFeature?

    var body: some Feature {
      exposure
      // A `nil` member contributes nothing.
      lut
    }
  }

  // A 512×512 CLUT image holds a 64³ color cube; the dimension is inferred.
  // The result is `nil` when the file is missing.
  let lut = try? ColorCubeFeature(contentsOfCubeImage: Sample.lutURL, intensity: 0.8)
  try Sample.render(PlaygroundFeature(lut: lut))
}

// MARK: - Crop in the middle

#Playground("Crop in the middle") {
  struct PlaygroundFeature: Feature {
    var exposure = ExposureFeature(ev: -0.1)
    // Core Image coordinates of the incoming image: bottom-left origin, y-up.
    var crop = CropFeature(rect: CGRect(x: 0, y: 270, width: 820, height: 524))
    var vignette = VignetteFeature(value: 1)

    var body: some Feature {
      exposure
      crop
      // Features after the crop receive the cropped image, so the vignette
      // is centered on the crop rather than on the photo.
      vignette
    }
  }

  try Sample.render(PlaygroundFeature())
}

// MARK: - Brush mask

#Playground("Brush mask blur") {
  // A soft stroke over the bowl. Stamps are Core Image coordinates of the
  // image the local adjustment receives: bottom-left origin, y-up.
  let stroke = BrushMask.Stroke(
    stampCenters: stride(from: 120.0, through: 460.0, by: 10).map { x in
      CGPoint(x: x, y: 600 + 40 * sin(x / 60))
    },
    brush: BrushMask.Brush(diameter: 260, hardness: 0.3, opacity: 1)
  )

  struct PlaygroundFeature: Feature {
    var localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?

    var body: some Feature {
      localBlur
    }
  }

  var feature = PlaygroundFeature()
  feature.localBlur = LocalAdjustmentFeature(
    mask: .brush(BrushMask(strokes: [stroke]))
  ) {
    GaussianBlurFeature(radius: .proportional(40))
  }
  try Sample.render(feature)
}

// MARK: - Data-driven effects

#Playground("Data-driven effects") {
  // `any` stays only where data decides the content, such as a list of
  // effects the host decoded. `[AnyImageEffect]` is itself an image effect
  // that evaluates in order.
  struct PlaygroundFeature: Feature {
    var isMonochrome = false
    var extraEffects: [AnyImageEffect] = []

    var body: some Feature {
      if isMonochrome {
        SaturationFeature(value: -1)
      }
      extraEffects
    }
  }

  var feature = PlaygroundFeature()
  feature.extraEffects = [
    AnyImageEffect(ContrastFeature(value: 0.2)),
    AnyImageEffect(VignetteFeature(value: 1)),
  ]
  try Sample.render(feature)

  feature.isMonochrome = true
  try Sample.render(feature)
}

// MARK: - Editor root feature

#Playground("Editor root feature") {
  /// The kind of root feature an editor owns. The editor decides which edits
  /// exist, keeps the history of this value, and renders views of it by
  /// substituting values.
  struct PhotoFeature: Feature, Equatable {
    var exposure = ExposureFeature(ev: 0)
    var look: FilmLook?
    var localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?
    var crop: CropFeature

    var body: some Feature {
      exposure
      look
      localBlur
      crop
    }
  }

  let fullFrame = CGRect(origin: .zero, size: Sample.photo.extent.size)

  var feature = PhotoFeature(crop: CropFeature(rect: fullFrame))
  feature.exposure.ev = -0.1
  feature.look = FilmLook(warmth: 500)
  feature.localBlur = LocalAdjustmentFeature(
    mask: .brush(
      BrushMask(strokes: [
        BrushMask.Stroke(
          stampCenters: [CGPoint(x: 260, y: 600)],
          brush: BrushMask.Brush(diameter: 520, hardness: 0.2, opacity: 1)
        )
      ])
    )
  ) {
    GaussianBlurFeature(radius: .proportional(30))
  }
  feature.crop.rect = CGRect(x: 400, y: 40, width: 680, height: 720)
  feature.crop.straightenRadians = 0.05

  // The exported image.
  try Sample.render(feature)

  // The view a crop tool shows: every edit before the crop, on the whole
  // image. Substituting the crop value is all it takes.
  var uncropped = feature
  uncropped.crop = CropFeature(rect: fullFrame)
  try Sample.render(uncropped)
}

// MARK: - Sample

/// The inputs and the renderer shared by the playgrounds in this file.
fileprivate enum Sample {

  /// The repository's `Dev/Bundle` directory, found relative to this file.
  static let bundleDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()  // Playgrounds
    .deletingLastPathComponent()  // BrightroomParametric
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // repository root
    .appending(path: "Dev/Bundle")

  /// A colorful 1123×794 photo, or a generated image of the same size when
  /// the file is missing.
  static let photo =
    CIImage(contentsOf: bundleDirectory.appending(path: "Images/gaku.jpeg"))
    ?? generatedPhoto()

  /// A 512×512 CLUT image.
  static let lutURL = bundleDirectory.appending(path: "LUTs/LUT_64_Dark_HighContrast_v3.png")

  /// Renders a root feature from `source`.
  ///
  /// The context works in extended-linear Display P3 with half-float pixels,
  /// which the tone curve and the color mixer require. The result is
  /// discardable: the canvas shows the value of every expression, and a
  /// named constant would warn about an unused value in ordinary builds.
  @discardableResult
  static func render(_ feature: some Feature, from source: CIImage = photo) throws -> CGImage {
    let output = try FeatureRenderer().makeImage(from: source, feature: feature)
    guard
      let image = context.createCGImage(
        output,
        from: output.extent,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
      )
    else {
      throw SampleError.failedToCreateCGImage
    }
    return image
  }

  enum SampleError: Error {
    case failedToCreateCGImage
  }

  private static let context = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
      ?? CGColorSpaceCreateDeviceRGB(),
    .workingFormat: CIFormat.RGBAh,
  ])

  /// A colorful stand-in with the photo's size, so the coordinates in the
  /// playgrounds stay inside the image.
  private static func generatedPhoto() -> CIImage {
    let extent = CGRect(x: 0, y: 0, width: 1123, height: 794)

    let gradient = CIFilter.linearGradient()
    gradient.point0 = CGPoint(x: 0, y: 0)
    gradient.point1 = CGPoint(x: extent.width, y: extent.height)
    gradient.color0 = CIColor(red: 0.95, green: 0.4, blue: 0.1)
    gradient.color1 = CIColor(red: 0.1, green: 0.55, blue: 0.4)

    let checkerboard = CIFilter.checkerboardGenerator()
    checkerboard.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.3)
    checkerboard.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.3)
    checkerboard.width = 40

    let pattern = checkerboard.outputImage ?? CIImage.empty()
    let background = gradient.outputImage ?? CIImage(color: .gray)
    return pattern.composited(over: background).cropped(to: extent)
  }
}

#endif
