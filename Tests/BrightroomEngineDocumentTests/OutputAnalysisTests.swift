import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// `OutputAnalysis`: what the canvas draws, rendered small through the export path over a prepared
/// preview, binned into a histogram and read back under the pointer.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct OutputAnalysisTests {

  typealias SRGB = (red: UInt8, green: UInt8, blue: UInt8)

  /// The colours of `quadrantImage()`, in sRGB.
  enum Quadrant {
    case topLeft, topRight, bottomLeft, bottomRight

    var color: SRGB {
      switch self {
      case .topLeft: (255, 0, 0)
      case .topRight: (0, 255, 0)
      case .bottomLeft: (0, 0, 255)
      case .bottomRight: (255, 255, 255)
      }
    }
  }

  /// The pixel size of the small fixtures.
  private static let imageSize = CGSize(width: 64, height: 48)

  /// A feature that keeps the whole of a small fixture and changes nothing.
  private static let wholeImage = ImageEditorFeature(
    crop: CropFeature(rect: CGRect(origin: .zero, size: imageSize))
  )

  /// A brush stroke across the centre of a small fixture, where its quadrants meet.
  private static let stroke = BrushMask.Stroke(
    stampCenters: stride(from: 16, through: 48, by: 4).map { CGPoint(x: $0, y: 24) },
    brush: BrushMask.Brush(diameter: 16, hardness: 0.5, opacity: 1)
  )

  // MARK: - Histogram

  @Test func `A solid colour puts every opaque pixel in one bin per channel at its Display P3 value`() async throws {
    let color: SRGB = (200, 120, 40)
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage(color)))
    let analysis = try await Self.analysis(of: Self.wholeImage, over: previewSource)
    let histogram = analysis.histogram
    let expected = try Self.displayP3(color)

    #expect(histogram.pixelCount == analysis.pixelWidth * analysis.pixelHeight)
    let channels = [
      (histogram.red, expected.red),
      (histogram.green, expected.green),
      (histogram.blue, expected.blue),
    ]
    for (bins, value) in channels {
      let filled = bins.indices.filter { bins[$0] > 0 }
      #expect(filled.count == 1, "filled bins \(filled)")
      let bin = try #require(filled.first)
      #expect(abs(bin - Int(value)) <= 1, "bin \(bin), Display P3 \(value)")
      #expect(Int(bins[bin]) == histogram.pixelCount)
    }
    #expect(histogram.shadowClipping == 0)
    #expect(histogram.highlightClipping == 0)

    // Each channel's one bin is the tallest, so its level is 1 and every other level is 0.
    let levels = histogram.levels()
    for (heights, bins) in [(levels.red, histogram.red), (levels.green, histogram.green), (levels.blue, histogram.blue)] {
      #expect(heights == bins.map { $0 > 0 ? 1.0 : 0.0 })
    }
  }

  @Test func `Transparent pixels stay out of bin 0`() async throws {
    // A transparent pixel's premultiplied colour is black, which bin 0 would count.
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.halfTransparentImage()))
    let analysis = try await Self.analysis(of: Self.wholeImage, over: previewSource)

    let transparent = stride(from: 3, to: analysis.pixels.count, by: 4).count { analysis.pixels[$0] == 0 }
    #expect(transparent == analysis.pixelWidth * analysis.pixelHeight / 2)
    #expect(analysis.histogram.pixelCount == analysis.pixelWidth * analysis.pixelHeight - transparent)
    #expect(analysis.histogram.red[0] == 0)
    #expect(analysis.histogram.green[0] == 0)
    #expect(analysis.histogram.blue[0] == 0)
    #expect(analysis.histogram.shadowClipping == 0)
    #expect(analysis.color(atOutputPoint: CGPoint(x: 16, y: 24)) == nil)
    #expect(analysis.color(atOutputPoint: CGPoint(x: 48, y: 24)) != nil)
  }

  @Test func `A partly transparent pixel is counted at the colour the readout reports`() async throws {
    // A mid gray at half opacity, whose premultiplied value is half its own.
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.halfOpaqueGrayImage()))
    let analysis = try await Self.analysis(of: Self.wholeImage, over: previewSource)

    let color = try #require(analysis.color(atOutputPoint: CGPoint(x: 32, y: 24)))
    #expect(abs(Int(color.green) - 128) <= 1, "readout \(color)")
    let channels = [
      (analysis.histogram.red, color.red),
      (analysis.histogram.green, color.green),
      (analysis.histogram.blue, color.blue),
    ]
    for (bins, value) in channels {
      let filled = bins.indices.filter { bins[$0] > 0 }
      #expect(filled == [Int(value)], "filled bins \(filled), readout \(value)")
    }
  }

  @Test func `Clipped pixels are measured, and the levels peak among the unclipped bins`() async throws {
    // Half white, which every channel clips at 255, a quarter black, at 0, and a quarter mid gray.
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.clippedImage()))
    let histogram = try await Self.analysis(of: Self.wholeImage, over: previewSource).histogram

    #expect(histogram.highlightClipping == 0.5)
    #expect(histogram.shadowClipping == 0.25)
    // The gray is the tallest bin among 1...254, so it and the taller clipped bins are at 1.
    let levels = histogram.levels()
    let gray = try #require((1...254).first { histogram.green[$0] > 0 })
    for heights in [levels.red, levels.green, levels.blue] {
      #expect(heights[255] == 1)
      #expect(heights[0] == 1)
      #expect(heights[gray] == 1)
    }
  }

  @Test func `One stop of exposure moves the bins up`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage((90, 90, 90))))
    var exposed = Self.wholeImage
    exposed.effects.exposure = ExposureFeature(ev: 1)
    let plain = try await Self.analysis(of: Self.wholeImage, over: previewSource).histogram
    let brighter = try await Self.analysis(of: exposed, over: previewSource).histogram

    for (before, after) in [(plain.red, brighter.red), (plain.green, brighter.green), (plain.blue, brighter.blue)] {
      let from = try #require(before.indices.max { before[$0] < before[$1] })
      let to = try #require(after.indices.max { after[$0] < after[$1] })
      #expect(to > from, "the tallest bin moves from \(from) to \(to)")
    }
  }

  @Test func `The adjustments render with the rendering passed`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage((90, 90, 90))))
    var exposed = Self.wholeImage
    exposed.effects.exposure = ExposureFeature(ev: 1)
    let plain = try await Self.analysis(of: Self.wholeImage, over: previewSource)

    let ignored = try await Self.analysis(of: exposed, over: previewSource, adjustmentRendering: Self.exposureIgnored)
    #expect(ignored.pixels == plain.pixels)
    #expect(try await Self.analysis(of: exposed, over: previewSource).pixels != plain.pixels)
  }

  // MARK: - Readouts

  @Test func `Quadrant colours read back at their output points, with row 0 at the top`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.quadrantImage()))
    let analysis = try await Self.analysis(of: Self.wholeImage, over: previewSource)

    #expect(analysis.outputSize == Self.imageSize)
    #expect(analysis.pixelWidth == 64)
    #expect(analysis.pixelHeight == 48)
    try Self.expect(analysis, reads: [
      (CGPoint(x: 16, y: 12), .topLeft),
      (CGPoint(x: 48, y: 12), .topRight),
      (CGPoint(x: 16, y: 36), .bottomLeft),
      (CGPoint(x: 48, y: 36), .bottomRight),
    ])
    for outside in [CGPoint(x: -1, y: 12), CGPoint(x: 64, y: 12), CGPoint(x: 16, y: 48)] {
      #expect(analysis.color(atOutputPoint: outside) == nil, "\(outside) is outside the output")
    }
  }

  @Test func `A quarter-turned crop turns the readouts with it`() async throws {
    // A counterclockwise turn brings the top-right quadrant to the top left.
    var feature = Self.wholeImage
    feature.crop.quarterTurn = .counterclockwise90
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.quadrantImage()))
    let analysis = try await Self.analysis(of: feature, over: previewSource)

    #expect(analysis.outputSize == CGSize(width: 48, height: 64))
    #expect(analysis.pixelWidth == 48)
    #expect(analysis.pixelHeight == 64)
    try Self.expect(analysis, reads: [
      (CGPoint(x: 12, y: 16), .topRight),
      (CGPoint(x: 36, y: 16), .bottomRight),
      (CGPoint(x: 12, y: 48), .topLeft),
      (CGPoint(x: 36, y: 48), .bottomLeft),
    ])
  }

  @Test func `A crop the canvas fits to the image is analysed as the canvas shows it`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.quadrantImage()))

    // Wider than the image on both sides, so the canvas shows the whole image.
    let wide = try await Self.analysis(
      of: ImageEditorFeature(crop: CropFeature(rect: CGRect(x: -32, y: 0, width: 128, height: 48))),
      over: previewSource
    )
    #expect(wide.outputSize == Self.imageSize)
    #expect(wide.pixelWidth == 64)
    #expect(wide.pixelHeight == 48)
    try Self.expect(wide, reads: [
      (CGPoint(x: 1, y: 12), .topLeft),
      (CGPoint(x: 62, y: 12), .topRight),
      (CGPoint(x: 1, y: 36), .bottomLeft),
      (CGPoint(x: 62, y: 36), .bottomRight),
    ])

    // Far larger than the image: the bitmap covers only what the canvas shows.
    let oversized = try await Self.analysis(
      of: ImageEditorFeature(crop: CropFeature(rect: CGRect(x: -6400, y: -4800, width: 12800, height: 9600))),
      over: previewSource
    )
    #expect(oversized.pixelWidth == 64)
    #expect(oversized.pixelHeight == 48)

    // The whole image straightened as it is: the canvas shows the largest crop inside the turned
    // image, so even its corners are part of the picture.
    var straightened = Self.wholeImage
    straightened.crop.straightenRadians = 0.3
    let turned = try await Self.analysis(of: straightened, over: previewSource)
    let shown = try #require(
      EditingCanvasCropOutputGeometry(
        crop: CropGuideState(cropFeature: straightened.crop, imageSize: Self.imageSize)
      )
    )
    #expect(turned.outputSize == shown.outputSize)
    #expect(turned.pixelWidth < 64 && turned.pixelHeight < 48)
    let size = turned.outputSize
    try Self.expect(turned, reads: [
      (CGPoint(x: 1, y: 1), .topLeft),
      (CGPoint(x: size.width - 2, y: 1), .topRight),
      (CGPoint(x: 1, y: size.height - 2), .bottomLeft),
      (CGPoint(x: size.width - 2, y: size.height - 2), .bottomRight),
    ])
  }

  @Test func `The vignette darkens the corners of the crop output`() async throws {
    let feature = ImageEditorFeature(crop: Self.wholeImage.crop, vignette: VignetteFeature(value: 1))
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage((200, 200, 200))))
    let analysis = try await Self.analysis(of: feature, over: previewSource)

    let centre = try #require(analysis.color(atOutputPoint: CGPoint(x: 32, y: 24)))
    for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 63, y: 0), CGPoint(x: 0, y: 47), CGPoint(x: 63, y: 47)] {
      let color = try #require(analysis.color(atOutputPoint: corner))
      #expect(
        Int(color.green) <= Int(centre.green) - 20,
        "\(corner) reads \(color), the centre \(centre)"
      )
    }
  }

  // MARK: - Export path

  @Test func `At the preview's resolution the bitmap equals a render of the same feature`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.quadrantImage()))
    var feature = ImageEditorFeature(
      crop: CropFeature(rect: CGRect(x: 8, y: 4, width: 48, height: 40)),
      vignette: VignetteFeature(value: 0.5)
    )
    feature.effects.exposure = ExposureFeature(ev: 0.3)
    feature.effects.sharpen = SharpenFeature(intensity: 0.4, radius: .proportional(1))
    feature.localBlur = LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [Self.stroke]))) {
      GaussianBlurFeature(radius: .proportional(20))
    }

    let analysis = try await Self.analysis(of: feature, over: previewSource)
    // A crop output far below 1024 pixels is analysed over the preview itself, which is the
    // whole source at full resolution for an image this small.
    #expect(previewSource.image.extent.size == Self.imageSize)
    #expect(analysis.pixelWidth == 48)
    #expect(analysis.pixelHeight == 40)
    let render = try FeatureRenderer().makeImage(from: previewSource.image, feature: feature)
    #expect(try Self.bitmap(of: render) == analysis.pixels)
  }

  @Test func `At half the resolution the bitmap matches a halved export`() async throws {
    let source = SourceImage(cgImage: try Self.patternImage())
    // The 2048-pixel crop halves to 1024 pixels. The stroke crosses the stripes, which the blur
    // flattens, so a misplaced crop or stroke would show.
    var feature = ImageEditorFeature(
      crop: CropFeature(rect: CGRect(x: 256, y: 192, width: 2048, height: 1536)),
      vignette: VignetteFeature(value: 0.5)
    )
    feature.effects.exposure = ExposureFeature(ev: 0.3)
    let stroke = BrushMask.Stroke(
      stampCenters: stride(from: 600, through: 2000, by: 40).map { CGPoint(x: $0, y: 960) },
      brush: BrushMask.Brush(diameter: 500, hardness: 0.5, opacity: 1)
    )
    feature.localBlur = LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [stroke]))) {
      GaussianBlurFeature(radius: .proportional(40))
    }

    let analysis = try await Self.analysis(of: feature, over: Self.previewSource(of: source))
    #expect(analysis.pixelWidth == 1024)
    #expect(analysis.pixelHeight == 768)

    let export = try ExportRenderer().render(
      from: source.makeCIImage(),
      feature: feature,
      options: .init(
        resolution: .resize(maxPixelSize: 1024),
        outputFormat: .RGBA8,
        outputColorSpace: EditingCanvasImageProcessing.drawableColorSpace
      )
    )
    let exported = try Self.bytes(of: export.cgImage)
    try #require(exported.count == analysis.pixels.count)
    var difference = 0
    for index in exported.indices where index % 4 != 3 {
      difference += abs(Int(exported[index]) - Int(analysis.pixels[index]))
    }
    let mean = Double(difference) / Double(exported.count / 4 * 3)
    #expect(mean <= 2, "The mean difference is \(mean) of 255.")
  }

  @Test func `A local blur the canvas does not composite is left out`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.quadrantImage()))
    var inverted = Self.wholeImage
    inverted.localBlur = LocalAdjustmentFeature(mask: .inverted(.brush(BrushMask(strokes: [Self.stroke])))) {
      GaussianBlurFeature(radius: .proportional(40))
    }
    var brushed = Self.wholeImage
    brushed.localBlur = LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [Self.stroke]))) {
      GaussianBlurFeature(radius: .proportional(40))
    }

    let plain = try await Self.analysis(of: Self.wholeImage, over: previewSource)
    #expect(try await Self.analysis(of: inverted, over: previewSource).pixels == plain.pixels)
    // The same stroke as a plain brush is composited, so the blur shows.
    #expect(try await Self.analysis(of: brushed, over: previewSource).pixels != plain.pixels)
  }

  // MARK: - Size

  @Test func `The copy follows the crop output, at most 1024 pixels long and never finer than the preview`() async throws {
    // A 2600-pixel square loads as a 2560-pixel preview: the preview scale is 2560 / 2600.
    let source = SourceImage(cgImage: try DocumentTestFixtures.makeCGImage(width: 2600, height: 2600))
    let previewSource = try await Self.previewSource(of: source)
    #expect(previewSource.image.extent.size == CGSize(width: 2560, height: 2560))

    let cases: [(crop: CGRect, longSide: Int)] = [
      // The whole image is capped at 1024.
      (CGRect(x: 0, y: 0, width: 2600, height: 2600), 1024),
      // So is half of each side, which a copy sized by the source would give 512.
      (CGRect(x: 650, y: 650, width: 1300, height: 1300), 1024),
      // A quarter of each side is 650 × 2560 / 2600 = 640 pixels at the preview's resolution.
      (CGRect(x: 975, y: 975, width: 650, height: 650), 640),
    ]
    for (crop, longSide) in cases {
      let analysis = try await Self.analysis(
        of: ImageEditorFeature(crop: CropFeature(rect: crop)),
        over: previewSource
      )
      #expect(analysis.outputSize == crop.size)
      #expect(
        analysis.pixelWidth == longSide && analysis.pixelHeight == longSide,
        "\(crop) is analysed at \(analysis.pixelWidth) × \(analysis.pixelHeight)"
      )
    }
  }

  @Test func `The edges of the crop output read back when its copy is a fraction of a pixel taller`() async throws {
    // At 1024 / 1500 the whole image is 1024 × 682.67 pixels, and a 1499 × 999 crop of it
    // 1024 × 682.44.
    let source = SourceImage(
      cgImage: try DocumentTestFixtures.makeCGImage(
        width: 1500,
        height: 1000,
        color: CGColor(srgbRed: 0.5, green: 0.4, blue: 0.3, alpha: 1)
      )
    )
    let previewSource = try await Self.previewSource(of: source)

    for crop in [CGRect(x: 0, y: 0, width: 1500, height: 1000), CGRect(x: 0, y: 0, width: 1499, height: 999)] {
      let analysis = try await Self.analysis(
        of: ImageEditorFeature(crop: CropFeature(rect: crop)),
        over: previewSource
      )
      let translucent = stride(from: 3, to: analysis.pixels.count, by: 4).count { analysis.pixels[$0] < 255 }
      #expect(translucent == 0, "\(crop) has \(translucent) translucent pixels")
      let edges = [
        CGPoint(x: crop.width / 2, y: 0),
        CGPoint(x: crop.width - 1, y: crop.height / 2),
        CGPoint(x: crop.width - 1, y: 0),
      ]
      for point in edges {
        #expect(analysis.color(atOutputPoint: point) != nil, "\(crop) reads nothing at \(point)")
      }
    }
  }

  // MARK: - Helpers

  /// The preview of `source`, prepared as the editors prepare it.
  private static func previewSource(of source: SourceImage) async throws -> PreviewSource {
    let loader = PreviewSourceLoader(source: source)
    await loader.load()
    return try #require(loader.previewSource)
  }

  private static func analysis(
    of feature: ImageEditorFeature,
    over previewSource: PreviewSource,
    adjustmentRendering: AdjustmentRendering = .standard
  ) async throws -> OutputAnalysis {
    try #require(
      await OutputAnalysis.analyze(feature, over: previewSource, adjustmentRendering: adjustmentRendering)
    )
  }

  /// A rendering whose exposure leaves the image as it is.
  private static let exposureIgnored: AdjustmentRendering = {
    var setup = AdjustmentRendering.Setup()
    setup.replace(
      ExposureFeature.self,
      with: .init(identity: .init(implementation: "test.exposure-ignored", version: "1", configuration: "")) { _, image, _ in
        image
      }
    )
    return setup.makeRendering()
  }()

  /// Expects each point to read its quadrant's colour, within one 8-bit step per channel for the
  /// rounding of Core Image's half-float working space.
  private static func expect(
    _ analysis: OutputAnalysis,
    reads expectations: [(CGPoint, Quadrant)]
  ) throws {
    for (point, quadrant) in expectations {
      let expected = try displayP3(quadrant.color)
      let color = try #require(analysis.color(atOutputPoint: point), "\(point) reads nothing")
      let difference = [
        Int(color.red) - Int(expected.red),
        Int(color.green) - Int(expected.green),
        Int(color.blue) - Int(expected.blue),
      ]
      .map(abs)
      .max()!
      #expect(difference <= 1, "\(point) should read \(quadrant) \(expected), found \(color)")
    }
  }

  /// `color`, given in sRGB, in 8-bit Display P3 as ColorSync converts it.
  private static func displayP3(_ color: SRGB) throws -> OutputAnalysis.Color {
    let sRGB = CGColor(
      srgbRed: CGFloat(color.red) / 255,
      green: CGFloat(color.green) / 255,
      blue: CGFloat(color.blue) / 255,
      alpha: 1
    )
    let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let components = try #require(sRGB.converted(to: displayP3, intent: .defaultIntent, options: nil)?.components)
    func byte(_ value: CGFloat) -> UInt8 {
      UInt8((min(max(value, 0), 1) * 255).rounded())
    }
    return .init(red: byte(components[0]), green: byte(components[1]), blue: byte(components[2]))
  }

  /// `image` rendered as the analysis renders it: in the canvas's working space, into RGBA8
  /// Display P3 with row 0 at the top.
  private static func bitmap(of image: CIImage) throws -> [UInt8] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let context = CIContext(mtlDevice: device, options: [
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
      .cacheIntermediates: false,
    ])
    let bounds = image.extent.integral
    let width = Int(bounds.width)
    var pixels = [UInt8](repeating: 0, count: width * Int(bounds.height) * 4)
    context.render(
      image,
      toBitmap: &pixels,
      rowBytes: width * 4,
      bounds: bounds,
      format: .RGBA8,
      colorSpace: EditingCanvasImageProcessing.drawableColorSpace
    )
    return pixels
  }

  /// The bytes of an image with 8-bit RGBA pixels, rows from the top without padding.
  private static func bytes(of image: CGImage) throws -> [UInt8] {
    #expect(image.bitsPerPixel == 32)
    let data = try #require(image.dataProvider?.data) as Data
    let rowLength = image.width * 4
    return (0..<image.height).flatMap { row in
      data[row * image.bytesPerRow..<row * image.bytesPerRow + rowLength]
    }
  }

  // MARK: - Fixtures

  /// A 64 × 48 sRGB image of one colour.
  private static func solidImage(_ color: SRGB) throws -> CGImage {
    try DocumentTestFixtures.makeCGImage(
      width: Int(imageSize.width),
      height: Int(imageSize.height),
      color: CGColor(
        srgbRed: CGFloat(color.red) / 255,
        green: CGFloat(color.green) / 255,
        blue: CGFloat(color.blue) / 255,
        alpha: 1
      )
    )
  }

  /// A 64 × 48 sRGB image whose first row is its top, in the colours of `Quadrant`.
  private static func quadrantImage() throws -> CGImage {
    let width = Int(imageSize.width)
    let height = Int(imageSize.height)
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for row in 0..<height {
      for column in 0..<width {
        let quadrant: Quadrant = switch (row < height / 2, column < width / 2) {
        case (true, true): .topLeft
        case (true, false): .topRight
        case (false, true): .bottomLeft
        case (false, false): .bottomRight
        }
        let offset = (row * width + column) * 4
        bytes[offset] = quadrant.color.red
        bytes[offset + 1] = quadrant.color.green
        bytes[offset + 2] = quadrant.color.blue
      }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: sRGB,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
  }

  /// A 64 × 48 sRGB image whose left half is transparent and whose right half is a mid gray.
  private static func halfTransparentImage() throws -> CGImage {
    let width = Int(imageSize.width)
    let height = Int(imageSize.height)
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    return try #require(context.makeImage())
  }

  /// A 64 × 48 sRGB image of a mid gray at half opacity.
  private static func halfOpaqueGrayImage() throws -> CGImage {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil,
        width: Int(imageSize.width),
        height: Int(imageSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.clear(CGRect(origin: .zero, size: imageSize))
    context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5))
    context.fill(CGRect(origin: .zero, size: imageSize))
    return try #require(context.makeImage())
  }

  /// A 64 × 48 sRGB image whose left half is white, then a quarter black and a quarter mid gray.
  private static func clippedImage() throws -> CGImage {
    let width = Int(imageSize.width)
    let height = Int(imageSize.height)
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width / 4, height: height))
    context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: width * 3 / 4, y: 0, width: width / 4, height: height))
    return try #require(context.makeImage())
  }

  /// A 2560 × 1920 sRGB image in which a misplaced crop or blur shows: red rises from left to right
  /// and green from bottom to top, under soft dark stripes 64 pixels apart.
  private static func patternImage() throws -> CGImage {
    let width = 2560
    let height = 1920
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    func gradient(_ colors: [CGColor], at locations: [CGFloat]) throws -> CGGradient {
      try #require(CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations))
    }

    context.drawLinearGradient(
      try gradient(
        [CGColor(srgbRed: 0, green: 0, blue: 0.5, alpha: 1), CGColor(srgbRed: 1, green: 0, blue: 0.5, alpha: 1)],
        at: [0, 1]
      ),
      start: .zero,
      end: CGPoint(x: width, y: 0),
      options: []
    )
    context.setBlendMode(.plusLighter)
    context.drawLinearGradient(
      try gradient(
        [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)],
        at: [0, 1]
      ),
      start: .zero,
      end: CGPoint(x: 0, y: height),
      options: []
    )
    context.setBlendMode(.normal)
    let stripe = try gradient(
      [
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
      ],
      at: [0, 0.5, 1]
    )
    for x in stride(from: 0, to: width, by: 64) {
      context.drawLinearGradient(
        stripe,
        start: CGPoint(x: x, y: 0),
        end: CGPoint(x: x + 64, y: 0),
        options: []
      )
    }
    return try #require(context.makeImage())
  }
}
