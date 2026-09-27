//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

// Image editing in code with the static composition model.
//
// Open this file in Xcode and run a playground from the canvas. Each
// playground describes an edit as a document, a struct whose `body` lists
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
  struct Document: Feature {
    var exposure = ExposureFeature(value: -0.1)
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

  // Before: an empty document leaves the image unchanged.
  try Sample.render(EmptyFeature())
  // After.
  try Sample.render(Document())
}

// MARK: - Reusable look

/// A look made only of image effects.
///
/// The body is `some ImageEffect`, so the look is an `ImageEffect` as well:
/// any document can reuse it, it can go inside a `LocalAdjustment`, and a
/// crop in its body does not compile.
fileprivate struct FilmLook: ImageEffect, Equatable {
  var warmth = 900.0
  var isMonochrome = false

  var body: some ImageEffect {
    if isMonochrome {
      SaturationFeature(value: -1)
      ContrastFeature(value: 0.15)
    } else {
      TemperatureFeature(value: warmth)
      SaturationFeature(value: 0.1)
    }
    FadeFeature(intensity: 0.05)
    VignetteFeature(value: 0.8)
  }
}

#Playground("Reusable look") {
  struct Document: Feature {
    var exposure = ExposureFeature(value: -0.1)
    var look = FilmLook()

    var body: some Feature {
      exposure
      look
    }
  }

  var document = Document()
  try Sample.render(document)

  document.look.isMonochrome = true
  try Sample.render(document)
}

// MARK: - Tone curve and color mixer

#Playground("Tone curve and color mixer") {
  // A gentle S-curve on the luminance channel.
  var curve = ToneCurve()
  curve.insertPoint(input: 0.3, output: 0.24)
  curve.insertPoint(input: 0.7, output: 0.76)

  // Richer reds, greens toward aqua, and the yellow mat toward orange.
  var mix = ColorMixerAdjustment()
  mix.red = ColorMixerBandAdjustment(saturation: 40)
  mix.green = ColorMixerBandAdjustment(hue: 40, saturation: 20, luminance: -20)
  mix.yellow = ColorMixerBandAdjustment(hue: -30, saturation: 20)

  struct Document: Feature {
    var toneCurve: ToneCurveFeature
    var colorMixer: ColorMixerFeature

    var body: some Feature {
      toneCurve
      colorMixer
    }
  }

  let document = Document(
    toneCurve: ToneCurveFeature(value: ToneCurveEditorValue(y: curve)),
    colorMixer: ColorMixerFeature(adjustment: mix)
  )
  try Sample.render(document)
}

// MARK: - LUT

#Playground("LUT") {
  struct Document: Feature {
    var exposure = ExposureFeature(value: 0.1)
    var lut: ColorCubeFeature?

    var body: some Feature {
      exposure
      // A `nil` member contributes nothing.
      lut
    }
  }

  // A 512×512 CLUT image holds a 64³ color cube; the dimension is inferred.
  // The result is `nil` when the file is missing.
  let lut = try? ColorCubeFeature(cubeImageAt: Sample.lutURL, amount: 0.8)
  try Sample.render(Document(lut: lut))
}

// MARK: - Crop in the middle

#Playground("Crop in the middle") {
  struct Document: Feature {
    var exposure = ExposureFeature(value: -0.1)
    // Core Image coordinates of the incoming image: bottom-left origin, y-up.
    var crop = CropFeature(cropRect: CGRect(x: 0, y: 270, width: 820, height: 524))
    var vignette = VignetteFeature(value: 1)

    var body: some Feature {
      exposure
      crop
      // Features after the crop receive the cropped image, so the vignette
      // is centered on the crop rather than on the photo.
      vignette
    }
  }

  try Sample.render(Document())
}

// MARK: - Brush mask

#Playground("Brush mask blur") {
  // A soft stroke over the bowl. Stamps are Core Image coordinates of the
  // image the local adjustment receives: bottom-left origin, y-up.
  let stroke = BrushMaskStroke(
    stamps: stride(from: 120.0, through: 460.0, by: 10).map { x in
      CGPoint(x: x, y: 600 + 40 * sin(x / 60))
    },
    brush: BrushMaskBrush(diameter: 260, hardness: 0.3, opacity: 1)
  )

  struct Document: Feature {
    var localBlur: LocalAdjustment<GaussianBlurFeature>?

    var body: some Feature {
      localBlur
    }
  }

  var document = Document()
  document.localBlur = LocalAdjustment(
    maskTree: MaskTree(root: .brush(BrushMask(strokes: [stroke])))
  ) {
    GaussianBlurFeature(value: 40)
  }
  try Sample.render(document)
}

// MARK: - Data-driven effects

#Playground("Data-driven effects") {
  // `any` stays only where data decides the content, such as a list of
  // effects the host decoded. `[AnyImageEffect]` is itself an image effect
  // that evaluates in order.
  struct Document: Feature {
    var isMonochrome = false
    var extraEffects: [AnyImageEffect] = []

    var body: some Feature {
      if isMonochrome {
        SaturationFeature(value: -1)
      }
      extraEffects
    }
  }

  var document = Document()
  document.extraEffects = [
    AnyImageEffect(ContrastFeature(value: 0.2)),
    AnyImageEffect(VignetteFeature(value: 1)),
  ]
  try Sample.render(document)

  document.isMonochrome = true
  try Sample.render(document)
}

// MARK: - Editor document

#Playground("Editor document") {
  /// The kind of document an editor owns. The editor decides which edits
  /// exist, keeps the history of this value, and renders views of it by
  /// substituting values.
  struct PhotoDocument: Feature, Equatable {
    var exposure = ExposureFeature(value: 0)
    var look: FilmLook?
    var localBlur: LocalAdjustment<GaussianBlurFeature>?
    var crop: CropFeature

    var body: some Feature {
      exposure
      look
      localBlur
      crop
    }
  }

  let fullFrame = CGRect(origin: .zero, size: Sample.photo.extent.size)

  var document = PhotoDocument(crop: CropFeature(cropRect: fullFrame))
  document.exposure.value = -0.1
  document.look = FilmLook(warmth: 500)
  document.localBlur = LocalAdjustment(
    maskTree: MaskTree(
      root: .brush(
        BrushMask(strokes: [
          BrushMaskStroke(
            stamps: [CGPoint(x: 260, y: 600)],
            brush: BrushMaskBrush(diameter: 520, hardness: 0.2, opacity: 1)
          )
        ])
      )
    )
  ) {
    GaussianBlurFeature(value: 30)
  }
  document.crop.cropRect = CGRect(x: 400, y: 40, width: 680, height: 720)
  document.crop.straightenRadians = 0.05

  // The exported image.
  try Sample.render(document)

  // The view a crop tool shows: every edit before the crop, on the whole
  // image. Substituting the crop value is all it takes.
  var uncropped = document
  uncropped.crop = CropFeature(cropRect: fullFrame)
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

  /// Renders a document from `source`.
  ///
  /// The context works in extended-linear Display P3 with half-float pixels,
  /// which the tone curve and the color mixer require. The result is
  /// discardable: the canvas shows the value of every expression, and a
  /// named constant would warn about an unused value in ordinary builds.
  @discardableResult
  static func render(_ document: some Feature, from source: CIImage = photo) throws -> CGImage {
    let output = try ParametricImageRenderer().makeImage(from: source, feature: document)
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
