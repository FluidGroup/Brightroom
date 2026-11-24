import CoreGraphics
import CoreImage
import Metal
import Testing

// Public API only: this file plays the role of a host app that builds its own
// editor from the components. It prepares one preview source and analyses,
// samples and previews filters over it, as a host's views share one decode.
// It must not need `@testable` access (the test-only image fixture is the
// test target's own).
import BrightroomEngine
import BrightroomParametric
import BrightroomUI

/// The editor components over one preview source: a histogram and the colour
/// under the pointer, a gray point and filter swatches.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct EditorComponentsPublicAPITests {

  typealias SRGB = (red: UInt8, green: UInt8, blue: UInt8)

  /// The pixel size of the fixtures.
  private static let imageSize = CGSize(width: 64, height: 48)

  /// A feature that keeps the whole of a fixture and changes nothing.
  private static let wholeImage = ImageEditorFeature(
    crop: CropFeature(rect: CGRect(origin: .zero, size: imageSize))
  )

  // MARK: - Histogram and readout

  @Test func `A solid colour fills one bin per channel, and the readout reads it inside the crop output only`() async throws {
    let color: SRGB = (200, 120, 40)
    let previewSource = try await Self.previewSource(of: Self.image(left: color, right: color))

    let analysis = try #require(await OutputAnalysis.analyze(Self.wholeImage, over: previewSource))
    #expect(analysis.outputSize == Self.imageSize)
    let histogram = analysis.histogram
    for bins in [histogram.red, histogram.green, histogram.blue] {
      #expect(bins.count == 256)
      #expect(bins.filter { $0 > 0 }.count == 1)
      #expect(bins.max().map(Int.init) == histogram.pixelCount)
    }
    #expect(histogram.shadowClipping == 0)
    #expect(histogram.highlightClipping == 0)

    let readout = try #require(analysis.color(atOutputPoint: CGPoint(x: 32, y: 24)))
    let expected = try Self.displayP3(color)
    #expect(Self.difference(readout, expected) <= 1, "read \(readout), Display P3 \(expected)")
    #expect(histogram.red[Int(readout.red)] > 0)
    #expect(histogram.green[Int(readout.green)] > 0)
    #expect(histogram.blue[Int(readout.blue)] > 0)

    // A crop of the right half: the output is 32 points wide.
    let rightHalf = ImageEditorFeature(crop: CropFeature(rect: CGRect(x: 32, y: 0, width: 32, height: 48)))
    let cropped = try #require(await OutputAnalysis.analyze(rightHalf, over: previewSource))
    #expect(cropped.outputSize == CGSize(width: 32, height: 48))
    #expect(cropped.color(atOutputPoint: CGPoint(x: 16, y: 24)) != nil)
    for outside in [CGPoint(x: -1, y: 24), CGPoint(x: 32, y: 24), CGPoint(x: 16, y: 48)] {
      #expect(cropped.color(atOutputPoint: outside) == nil, "\(outside) is outside the output")
    }
  }

  @Test func `A host's histogram levels peak among the unclipped bins`() {
    var bins = [UInt32](repeating: 0, count: 256)
    bins[0] = 50
    bins[50] = 5
    bins[100] = 10
    bins[255] = 35
    let histogram = OutputAnalysis.Histogram(
      red: bins,
      green: bins,
      blue: bins,
      pixelCount: 100,
      shadowClipping: 0.5,
      highlightClipping: 0.35
    )

    let levels = histogram.levels()
    for heights in [levels.red, levels.green, levels.blue] {
      #expect(heights[100] == 1)
      #expect(heights[50] == 0.5)
      #expect(heights[0] == 1)
      #expect(heights[255] == 1)
      #expect(heights[1] == 0)
    }
    #expect(OutputAnalysis.Color(red: 1, green: 2, blue: 3) != OutputAnalysis.Color(red: 3, green: 2, blue: 1))
  }

  // MARK: - Gray point

  @Test func `A gray point balances a cast area, which then reads neutral`() async throws {
    // A warm gray on the left, a cool one on the right.
    let previewSource = try await Self.previewSource(of: Self.image(left: (140, 128, 112), right: (120, 128, 140)))
    let point = CGPoint(x: 16, y: 24)

    let result = await GrayPoint.solve(at: point, in: Self.wholeImage, over: previewSource)
    let balance = try #require(try result.get())

    var balanced = Self.wholeImage
    balanced.effects.whiteBalance = balance
    let analysis = try #require(await OutputAnalysis.analyze(balanced, over: previewSource))
    let readout = try #require(analysis.color(atOutputPoint: point))
    let channels = [Int(readout.red), Int(readout.green), Int(readout.blue)]
    #expect(channels.max()! - channels.min()! <= 2, "read \(readout)")
  }

  @Test func `A neutral area needs no white balance, and a point off the image is rejected`() async throws {
    let gray: SRGB = (128, 128, 128)
    let previewSource = try await Self.previewSource(of: Self.image(left: gray, right: gray))

    #expect(await GrayPoint.solve(at: CGPoint(x: 32, y: 24), in: Self.wholeImage, over: previewSource) == .success(nil))
    for outside in [CGPoint(x: -1, y: 24), CGPoint(x: 64, y: 24), CGPoint(x: 32, y: 48)] {
      let result = await GrayPoint.solve(at: outside, in: Self.wholeImage, over: previewSource)
      #expect(result == .failure(.outsideImage), "\(outside)")
    }
  }

  // MARK: - Filter swatches

  @Test func `A swatch is the point size times the scale at most, in Display P3, and a preset changes it`() async throws {
    // The thumbnail of a 64 × 48 image is the image itself, so a swatch is at most 48 pixels.
    let previewSource = try await Self.previewSource(of: Self.image(left: (90, 90, 90), right: (90, 90, 90)))

    let original = try #require(await FilterSwatch.render(nil, over: previewSource, pointSize: 20, scale: 2))
    #expect(original.width == 40)
    #expect(original.height == 40)
    #expect(original.colorSpace?.name == CGColorSpace.displayP3)

    let capped = try #require(await FilterSwatch.render(nil, over: previewSource, pointSize: 30, scale: 2))
    #expect(capped.width == 48)
    #expect(capped.height == 48)

    let brighter = FilterFeature(name: "Brighter", id: "brighter", effects: [AnyImageEffect(ExposureFeature(ev: 1))])
    let filtered = try #require(await FilterSwatch.render(brighter, over: previewSource, pointSize: 20, scale: 2))
    #expect(filtered.width == 40)
    #expect(try Self.centre(of: filtered).green > Self.centre(of: original).green)
  }

  // MARK: - Fixtures

  /// The preview source of `image`, prepared once, as a host's editor prepares it for its views.
  private static func previewSource(of image: CGImage) async throws -> PreviewSource {
    let loader = PreviewSourceLoader(source: SourceImage(cgImage: image))
    await loader.load()
    return try #require(loader.previewSource)
  }

  /// A 64 × 48 sRGB image whose left half is `left` and whose right half is `right`.
  private static func image(left: SRGB, right: SRGB) throws -> CGImage {
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
    for (color, x) in [(left, 0), (right, width / 2)] {
      context.setFillColor(
        CGColor(
          srgbRed: CGFloat(color.red) / 255,
          green: CGFloat(color.green) / 255,
          blue: CGFloat(color.blue) / 255,
          alpha: 1
        )
      )
      context.fill(CGRect(x: x, y: 0, width: width / 2, height: height))
    }
    return try #require(context.makeImage())
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

  /// The largest difference of one channel between two colours.
  private static func difference(_ first: OutputAnalysis.Color, _ second: OutputAnalysis.Color) -> Int {
    [
      Int(first.red) - Int(second.red),
      Int(first.green) - Int(second.green),
      Int(first.blue) - Int(second.blue),
    ]
    .map(abs)
    .max()!
  }

  /// The centre pixel of `image`, drawn into 8-bit Display P3.
  private static func centre(of image: CGImage) throws -> OutputAnalysis.Color {
    let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { buffer in
      let context = try #require(
        CGContext(
          data: buffer.baseAddress,
          width: 1,
          height: 1,
          bitsPerComponent: 8,
          bytesPerRow: 4,
          space: displayP3,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      // Only the centre pixel lands in the 1 × 1 context.
      context.draw(
        image,
        in: CGRect(
          x: -CGFloat(image.width / 2),
          y: -CGFloat(image.height / 2),
          width: CGFloat(image.width),
          height: CGFloat(image.height)
        )
      )
    }
    return .init(red: pixel[0], green: pixel[1], blue: pixel[2])
  }
}
