import BrightroomParametric
import CoreGraphics
import CoreImage
import Metal
import QuartzCore
import Testing

@testable import BrightroomUI

/// The shared drawing path of a canvas that shows a feature's crop output,
/// as the AppKit canvas draws it: the render images and strokes it hands
/// `CanvasMetalSurface.updateCropOutput`, drawn by `EditingCanvasRenderer`
/// with the viewport `CanvasNavigation` produces at the fit.
///
/// The source has four differently coloured quadrants, so a picture drawn
/// flipped, mirrored, cropped wrongly (horizontally or vertically) or placed
/// wrongly for the fitted viewport fails, and so does a frame that draws
/// nothing. A case with a vignette covers the post-crop pass, which writes
/// the frame's pixels a second time.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct CanvasOutputRenderTests {

  /// The source's pixel size: two 32 × 16 quadrants per row.
  private static let sourceSize = CGSize(width: 64, height: 32)

  /// The colour of each quadrant, in sRGB.
  enum Quadrant: CaseIterable, CustomStringConvertible {
    case topLeft, topRight, bottomLeft, bottomRight

    var color: (red: UInt8, green: UInt8, blue: UInt8) {
      switch self {
      case .topLeft: (255, 0, 0)
      case .topRight: (0, 255, 0)
      case .bottomLeft: (0, 0, 255)
      case .bottomRight: (255, 255, 255)
      }
    }

    var description: String {
      switch self {
      case .topLeft: "red (top left)"
      case .topRight: "green (top right)"
      case .bottomLeft: "blue (bottom left)"
      case .bottomRight: "white (bottom right)"
      }
    }
  }

  /// What a canvas point shows.
  enum Expectation: CustomStringConvertible {
    case quadrant(Quadrant)
    /// The quadrant's colour, darkened by the vignette: its strongest channel
    /// stays the strongest and is clearly lower.
    case darkened(Quadrant)
    /// Outside the content: the canvas is transparent there.
    case letterbox

    var description: String {
      switch self {
      case .quadrant(let quadrant): quadrant.description
      case .darkened(let quadrant): "darkened \(quadrant)"
      case .letterbox: "letterbox"
      }
    }
  }

  struct Case: CustomTestStringConvertible, Sendable {
    let name: String
    /// The crop's rectangle, bottom-left and y-up as `CropFeature.rect` is.
    let cropRect: CGRect
    /// The canvas in points, drawn at scale 1.
    let canvasSize: CGSize
    let samples: [(point: CGPoint, expectation: Expectation)]
    /// The vignette drawn by the post-crop pass, centred on the crop output.
    var vignette: VignetteFeature? = nil
    /// Points that must show the same colour: mirror images about the
    /// centre of the crop output, where the vignette is centred.
    var mirroredPoints: [(CGPoint, CGPoint)] = []

    var testDescription: String { name }
  }

  nonisolated static let cases: [Case] = [
    // 64 × 32 fitted into 80 × 80: scale 1.25, the content 80 × 40 points at
    // y 20...60, transparent above and below.
    Case(
      name: "whole image, letterboxed",
      cropRect: CGRect(x: 0, y: 0, width: 64, height: 32),
      canvasSize: CGSize(width: 80, height: 80),
      samples: [
        (CGPoint(x: 20, y: 30), .quadrant(.topLeft)),
        (CGPoint(x: 60, y: 30), .quadrant(.topRight)),
        (CGPoint(x: 20, y: 50), .quadrant(.bottomLeft)),
        (CGPoint(x: 60, y: 50), .quadrant(.bottomRight)),
        (CGPoint(x: 40, y: 8), .letterbox),
        (CGPoint(x: 40, y: 72), .letterbox),
      ]
    ),
    // The right half (32 × 32) fitted into 120 × 80: scale 2.5, the content
    // 80 × 80 points at x 20...100, transparent left and right.
    Case(
      name: "right half, pillarboxed",
      cropRect: CGRect(x: 32, y: 0, width: 32, height: 32),
      canvasSize: CGSize(width: 120, height: 80),
      samples: [
        (CGPoint(x: 40, y: 20), .quadrant(.topRight)),
        (CGPoint(x: 80, y: 20), .quadrant(.topRight)),
        (CGPoint(x: 40, y: 60), .quadrant(.bottomRight)),
        (CGPoint(x: 80, y: 60), .quadrant(.bottomRight)),
        (CGPoint(x: 10, y: 40), .letterbox),
        (CGPoint(x: 110, y: 40), .letterbox),
      ]
    ),
    // The bottom half (64 × 16; y 0 is the bottom) fitted into 80 × 80:
    // scale 1.25, the content 80 × 20 points at y 30...50.
    Case(
      name: "bottom half, letterboxed",
      cropRect: CGRect(x: 0, y: 0, width: 64, height: 16),
      canvasSize: CGSize(width: 80, height: 80),
      samples: [
        (CGPoint(x: 20, y: 40), .quadrant(.bottomLeft)),
        (CGPoint(x: 60, y: 40), .quadrant(.bottomRight)),
        (CGPoint(x: 40, y: 20), .letterbox),
        (CGPoint(x: 40, y: 60), .letterbox),
      ]
    ),
    // The lower-left 32 × 24, off the source's centre: its top 8 rows are
    // red and the other 16 blue. Fitted into 64 × 48 at scale 2 it fills the
    // canvas. The vignette is centred on the crop output, at the canvas's
    // centre (blue, undimmed), and darkens the corners alike.
    Case(
      name: "lower-left crop with a vignette",
      cropRect: CGRect(x: 0, y: 0, width: 32, height: 24),
      canvasSize: CGSize(width: 64, height: 48),
      samples: [
        (CGPoint(x: 32, y: 24), .quadrant(.bottomLeft)),
        (CGPoint(x: 2, y: 2), .darkened(.topLeft)),
        (CGPoint(x: 61, y: 2), .darkened(.topLeft)),
        (CGPoint(x: 2, y: 45), .darkened(.bottomLeft)),
        (CGPoint(x: 61, y: 45), .darkened(.bottomLeft)),
      ],
      vignette: VignetteFeature(value: 0.6),
      mirroredPoints: [
        (CGPoint(x: 2, y: 2), CGPoint(x: 61, y: 2)),
        (CGPoint(x: 2, y: 45), CGPoint(x: 61, y: 45)),
      ]
    ),
  ]

  @Test(arguments: cases)
  func `The fitted crop output is drawn upright and in place`(testCase: Case) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = EditingCanvasSource(
      editingSourceImage: CIImage(cgImage: try Self.makeQuadrantImage()),
      imageSize: Self.sourceSize
    )
    let feature = ImageEditorFeature(
      crop: CropFeature(rect: testCase.cropRect),
      vignette: testCase.vignette
    )

    // The content, as `EditingCanvasView.updateContent()` (AppKit) builds it.
    let crop = CropGuideState(cropFeature: feature.crop, imageSize: source.imageSize)
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: crop))
    let plan = CanvasRenderPlan(localBlur: feature.localBlur)
    var strokeRecords = CommittedStrokeRecords()
    let images = try #require(try EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
      editingSourceImage: source.editingSourceImage,
      effects: feature.effects.canvasEffect,
      geometry: geometry,
      mode: plan.canvasMode
    ))
    let renderer = EditingCanvasRenderer(canvasSize: geometry.outputSize, device: device)
    renderer.setRenderImages(images)
    renderer.setCommittedStrokes(strokeRecords.outputRecords(
      localBlur: feature.localBlur,
      geometry: geometry,
      domainHeight: source.imageSize.height
    ))

    // One frame, as `EditingCanvasView.drawFrame()` (AppKit) and
    // `CanvasMetalSurface.draw(viewport:postCrop:)` draw it.
    var navigation = CanvasNavigation(contentSize: .zero, canvasSize: .zero)
    navigation.setContentSize(geometry.outputSize)
    navigation.setCanvasSize(testCase.canvasSize)
    #expect(navigation.isFitted)
    let viewport = try #require(navigation.viewport(contentScaleFactor: 1))
    let postCrop = CanvasPostCrop(
      effect: feature.canvasPostCropEffect, geometry: geometry, viewport: viewport
    )
    #expect((postCrop != nil) == (testCase.vignette != nil))
    renderer.setViewport(viewport.editingCanvasViewport)
    renderer.setPostCrop(
      effect: postCrop?.effect,
      frame: postCrop?.frame ?? .null,
      chainEntry: postCrop?.chainEntry ?? .null
    )

    // Kept alive until its pixels are read.
    let drawable = try Self.makeDrawable(device: device, size: testCase.canvasSize)
    let texture = drawable.texture
    let pixels = try Self.render(renderer, into: texture, viewportSize: testCase.canvasSize)
    withExtendedLifetime(drawable) {}
    let expected = try Self.expectedQuadrantPixels()

    for (point, expectation) in testCase.samples {
      let actual = Self.pixel(pixels, at: point, width: texture.width)
      switch expectation {
      case .letterbox:
        #expect(actual[3] == 0, "\(point) should be the \(expectation), found BGRA \(actual)")
      case .quadrant(let quadrant):
        let reference = expected[quadrant]!
        #expect(
          Self.difference(actual, reference) <= 6,
          "\(point) should be \(expectation) (BGRA \(reference)), found BGRA \(actual)"
        )
      case .darkened(let quadrant):
        let reference = expected[quadrant]!
        // The strongest colour channel (B, G or R) of the undimmed colour.
        let channel = (0..<3).max { reference[$0] < reference[$1] }!
        let strongest = (0..<3).max { actual[$0] < actual[$1] }!
        #expect(
          actual[3] == 255 && strongest == channel
            && Int(actual[channel]) <= Int(reference[channel]) - 40,
          "\(point) should be \(expectation) (undimmed BGRA \(reference)), found BGRA \(actual)"
        )
      }
    }

    for (first, second) in testCase.mirroredPoints {
      let a = Self.pixel(pixels, at: first, width: texture.width)
      let b = Self.pixel(pixels, at: second, width: texture.width)
      #expect(
        Self.difference(a, b) <= 6,
        "\(first) and \(second) should match, found BGRA \(a) and \(b)"
      )
    }
  }

  private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
  }

  // MARK: - Fixtures

  /// A 64 × 32 sRGB image whose first row is its top row: red top left,
  /// green top right, blue bottom left, white bottom right.
  private static func makeQuadrantImage() throws -> CGImage {
    let width = Int(sourceSize.width)
    let height = Int(sourceSize.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
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
        bytes[offset + 3] = 255
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
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
  }

  /// Each quadrant's colour as the canvas encodes it into a BGRA8 drawable,
  /// computed with Core Image on this machine.
  private static func expectedQuadrantPixels() throws -> [Quadrant: [UInt8]] {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = CIContext(options: [
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
    ])
    var result: [Quadrant: [UInt8]] = [:]
    for quadrant in Quadrant.allCases {
      let color = try #require(CIColor(
        red: CGFloat(quadrant.color.red) / 255,
        green: CGFloat(quadrant.color.green) / 255,
        blue: CGFloat(quadrant.color.blue) / 255,
        alpha: 1,
        colorSpace: sRGB
      ))
      var pixel = [UInt8](repeating: 0, count: 4)
      context.render(
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
        toBitmap: &pixel,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .BGRA8,
        colorSpace: EditingCanvasImageProcessing.drawableColorSpace
      )
      result[quadrant] = pixel
    }
    return result
  }

  /// A drawable of an offscreen Metal layer, the destination the canvas
  /// renders into.
  ///
  /// It is a drawable, not a plain texture, because Core Image writes the
  /// rows of a drawable in the order the screen shows them (its first row is
  /// the top), and the rows of a plain texture it can write with a compute
  /// kernel in the opposite order; the renderer writes for the drawable.
  /// The format is BGRA8, which reads back the same on every GPU; the
  /// canvas's own drawable is 10-bit on macOS and on devices, and the
  /// renderer encodes into either the same way.
  private static func makeDrawable(device: MTLDevice, size: CGSize) throws -> CAMetalDrawable {
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.colorspace = EditingCanvasImageProcessing.drawableColorSpace
    layer.drawableSize = size
    return try #require(layer.nextDrawable(), "No drawable for an offscreen layer")
  }

  private static func render(
    _ renderer: EditingCanvasRenderer,
    into texture: MTLTexture,
    viewportSize: CGSize
  ) throws -> [UInt8] {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    let submitted = try #require(renderer.render(.init(
      texture: texture,
      renderPassDescriptor: descriptor,
      viewportSize: viewportSize,
      activeStroke: nil,
      preferredFramesPerSecond: 60
    )), "The renderer drew nothing")
    submitted.waitUntilCompleted()
    try #require(
      submitted.status == .completed,
      "GPU submission failed: \(String(describing: submitted.error))"
    )
    #if os(macOS)
    if texture.storageMode == .managed {
      // Copies what the GPU wrote back to the CPU's copy of the texture.
      let buffer = try #require(texture.device.makeCommandQueue()?.makeCommandBuffer())
      let blit = try #require(buffer.makeBlitCommandEncoder())
      blit.synchronize(resource: texture)
      blit.endEncoding()
      buffer.commit()
      buffer.waitUntilCompleted()
    }
    #endif
    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    pixels.withUnsafeMutableBytes { bytes in
      texture.getBytes(
        bytes.baseAddress!,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
      )
    }
    return pixels
  }

  /// The BGRA pixel under a canvas point; the texture's first row is the
  /// canvas's top.
  private static func pixel(_ pixels: [UInt8], at point: CGPoint, width: Int) -> [UInt8] {
    let offset = (Int(point.y) * width + Int(point.x)) * 4
    return Array(pixels[offset..<offset + 4])
  }
}
