import CoreImage
import Metal
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// The canvas draws `ImageEditorFeature.vignette` after the crop, over the
/// crop frame, the way the export evaluates it.
///
/// Each canvas route renders through the real `EditingCanvasRenderer` with
/// the render images, the committed strokes, and the post-crop pass the
/// surfaces give it, in a drawable the size of the crop output: the crop
/// surface through the source-to-output mapping with its guide on the output,
/// the tool surface at rest.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PostCropVignetteCanvasTests {

  nonisolated private static let imageSize = CGSize(width: 1200, height: 800)
  private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

  enum CropCase: CaseIterable, Sendable {
    /// Off-centre to the left and straightened.
    case offCentreStraightened
    /// The left half, turned a quarter.
    case leftHalfCounterclockwise90

    var crop: CropFeature {
      switch self {
      case .offCentreStraightened:
        .test(
          imageSize: PostCropVignetteCanvasTests.imageSize,
          topLeftRect: CGRect(x: 100, y: 250, width: 400, height: 300),
          straightenRadians: 0.2
        )
      case .leftHalfCounterclockwise90:
        .test(
          imageSize: PostCropVignetteCanvasTests.imageSize,
          topLeftRect: CGRect(x: 0, y: 0, width: 600, height: 800),
          quarterTurn: .counterclockwise90
        )
      }
    }
  }

  enum CanvasRoute: CaseIterable, Sendable {
    /// Crop editing, no strokes (`.viewportBase`).
    case cropViewportBase
    /// Crop editing over a painted blur (`.localAdjustment`).
    case cropLocalAdjustment
    /// Viewing without strokes.
    case toolWithoutStrokes
    /// Viewing a painted blur.
    case toolWithStrokes
    /// Painting the blur: the stroke is still in flight.
    case blur

    var hasStroke: Bool { self != .cropViewportBase && self != .toolWithoutStrokes }
  }

  // MARK: - Every route matches export

  @Test(arguments: CropCase.allCases, CanvasRoute.allCases)
  func `The canvas matches export`(cropCase: CropCase, route: CanvasRoute) async throws {
    let source = Self.makeSmoothImage()
    let document = Self.makeDocument(crop: cropCase.crop, stroked: route.hasStroke)

    let exported = try await EditingDocument(source: SourceImage(cgImage: source), feature: document)
      .render(options: .init(outputColorSpace: Self.displayP3))
      .cgImage
    let canvas = try Self.renderCanvas(document: document, source: source, route: route)
    #expect(canvas.width == exported.width)
    #expect(canvas.height == exported.height)

    let export = Self.rgba(exported)
    var largest = 0
    var point = (0, 0)
    for y in 0..<canvas.height {
      for x in 0..<canvas.width {
        let offset = (y * canvas.width + x) * 4
        let difference = (0..<4).map { abs(Int(canvas.rgba[offset + $0]) - Int(export[offset + $0])) }.max()!
        if difference > largest {
          largest = difference
          point = (x, y)
        }
      }
    }
    #expect(largest <= 2, "the canvas differs from export by \(largest) at \(point)")

    // Without the vignette the same route differs: the pass is what matches.
    var plain = document
    plain.vignette = nil
    let unvignetted = try Self.renderCanvas(document: plain, source: source, route: route)
    #expect(zip(unvignetted.rgba, canvas.rgba).contains { abs(Int($0) - Int($1)) > 20 })
  }

  // MARK: - Crop guide

  /// While the guide is dragged, the pass follows it: the brightest pixel is
  /// the guide's centre, and nothing outside the guide changes.
  @Test func `Moving the crop guide moves the darkening and leaves the outside alone`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let size = CGSize(width: 160, height: 120)
    let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size))
    let images = try #require(EditingCanvasRenderImageFactory.makeRenderImages(
      editingSourceImage: grey,
      effects: nil,
      canvasSize: size,
      mode: .viewportBase
    ))
    let renderer = EditingCanvasRenderer(canvasSize: size, device: device)
    renderer.setRenderImages(images)
    renderer.setViewport(.init(visibleContentRect: CGRect(origin: .zero, size: size), contentToCanvasTransform: .identity))
    let target = try Self.makeTarget(device: device, size: size)

    let plain = Self.topLeft(try Self.render(renderer, into: target, viewportSize: size), width: target.width, height: target.height)
    var feature = ImageEditorFeature(imageSize: size)
    feature.vignette = VignetteFeature(value: 2)

    for guideFrame in [CGRect(x: 20, y: 10, width: 100, height: 80), CGRect(x: 50, y: 30, width: 100, height: 80)] {
      let postCrop = try #require(EditingCanvasView.CanvasPostCrop(
        effect: feature.canvasPostCropEffect,
        guideFrame: guideFrame,
        imageSize: size
      ))
      renderer.setPostCrop(effect: postCrop.effect, frame: postCrop.frame, chainEntry: postCrop.chainEntry)
      let pixels = Self.topLeft(try Self.render(renderer, into: target, viewportSize: size), width: target.width, height: target.height)

      var brightest = (level: -1, x: 0, y: 0)
      for y in 0..<Int(size.height) {
        for x in 0..<Int(size.width) {
          let offset = (y * Int(size.width) + x) * 4
          let inside = guideFrame.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
          if inside == false {
            #expect(Array(pixels[offset..<offset + 4]) == Array(plain[offset..<offset + 4]), "(\(x), \(y)) outside the guide changed")
            continue
          }
          // Prefer the pixel nearest the centre among equal levels.
          let level = Int(pixels[offset])
          let distance = hypot(CGFloat(x) + 0.5 - guideFrame.midX, CGFloat(y) + 0.5 - guideFrame.midY)
          let best = hypot(CGFloat(brightest.x) + 0.5 - guideFrame.midX, CGFloat(brightest.y) + 0.5 - guideFrame.midY)
          if level > brightest.level || (level == brightest.level && distance < best) {
            brightest = (level, x, y)
          }
        }
      }
      #expect(abs(CGFloat(brightest.x) + 0.5 - guideFrame.midX) <= 2)
      #expect(abs(CGFloat(brightest.y) + 0.5 - guideFrame.midY) <= 2)
      let corner = (Int(guideFrame.minY) * Int(size.width) + Int(guideFrame.minX)) * 4
      #expect(Int(pixels[corner]) + 20 < brightest.level, "the guide's corner is darkened")
    }
  }

  // MARK: - Vignette changes keep the render images

  @Test func `A vignette-only change keeps both canvas keys`() throws {
    let size = CGSize(width: 400, height: 300)
    var feature = ImageEditorFeature(imageSize: size)
    feature.effects.exposure = ExposureFeature(ev: 0.3)

    for target in [ImageEditorCanvas.Target.crop, nil] {
      let canvasView = EditingCanvasView(
        source: EditingCanvasSource(
          editingSourceImage: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)),
          imageSize: size
        ),
        feature: feature
      )
      canvasView.setEditingTarget(target)
      canvasView.loadFeature()
      let cropKey = canvasView.cropSurface.currentCanvasInputKey
      let toolKey = canvasView.toolSurface.currentCanvasRenderInputKey
      if target == .crop {
        #expect(cropKey != nil)
      } else {
        #expect(toolKey != nil)
      }

      for value in [1.0, 2.0, -1.0] {
        var vignetted = feature
        vignetted.vignette = VignetteFeature(value: value)
        canvasView.setFeature(vignetted)
        #expect(canvasView.cropSurface.currentCanvasInputKey == cropKey)
        #expect(canvasView.toolSurface.currentCanvasRenderInputKey == toolKey)
      }

      // An effects change does rebuild them.
      var exposed = feature
      exposed.effects.exposure = ExposureFeature(ev: 0.6)
      canvasView.setFeature(exposed)
      if target == .crop {
        #expect(canvasView.cropSurface.currentCanvasInputKey != cropKey)
      } else {
        #expect(canvasView.toolSurface.currentCanvasRenderInputKey != toolKey)
      }
    }
  }

  // MARK: - Evaluation order

  @Test func `The vignette is the last node of the feature tree`() {
    var feature = ImageEditorFeature(imageSize: Self.imageSize)
    feature.effects.exposure = ExposureFeature(ev: 0.3)
    feature.localBlur = LocalAdjustmentFeature(
      mask: .test(displayStamps: [CGPoint(x: 300, y: 400)], diameter: 80, domainHeight: Self.imageSize.height)
    ) {
      GaussianBlurFeature(radius: .proportional(20))
    }
    feature.vignette = VignetteFeature(value: 1)

    let names = FeatureTreeNode.nodes(for: feature).map(\.typeName)
    #expect(names.count == 4, "\(names)")
    #expect(names.first == "Effects", "\(names)")
    #expect(names.dropFirst().first?.hasPrefix("LocalAdjustmentFeature") == true, "\(names)")
    #expect(Array(names.suffix(2)) == ["CropFeature", "VignetteFeature"])
  }

  // MARK: - Fixtures

  private static func makeDocument(crop: CropFeature, stroked: Bool) -> ImageEditorFeature {
    var document = ImageEditorFeature(imageSize: imageSize)
    document.effects.exposure = ExposureFeature(ev: 0.3)
    document.crop = crop
    document.vignette = VignetteFeature(value: 1)
    if stroked {
      // Inside both crops, in the source domain (y-down).
      document.localBlur = LocalAdjustmentFeature(
        mask: .test(
          displayStamps: [CGPoint(x: 280, y: 380), CGPoint(x: 320, y: 420)],
          diameter: 120,
          hardness: 0.7,
          domainHeight: imageSize.height
        )
      ) {
        GaussianBlurFeature(radius: .proportional(20))
      }
    }
    return document
  }

  /// Smooth colour fields, so resampling through the crop's rotation stays
  /// within a level and the comparison is about the vignette.
  private static func makeSmoothImage() -> CGImage {
    let extent = CGRect(origin: .zero, size: imageSize)
    let horizontal = CIFilter(name: "CILinearGradient", parameters: [
      "inputPoint0": CIVector(x: 0, y: 0),
      "inputPoint1": CIVector(x: imageSize.width, y: 0),
      "inputColor0": CIColor(red: 0.85, green: 0.45, blue: 0.25),
      "inputColor1": CIColor(red: 0.25, green: 0.55, blue: 0.85),
    ])!.outputImage!
    let radial = CIFilter(name: "CIRadialGradient", parameters: [
      "inputCenter": CIVector(x: 420, y: 380),
      "inputRadius0": 0,
      "inputRadius1": 700,
      "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.35),
      "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
    ])!.outputImage!
    let image = radial.composited(over: horizontal).cropped(to: extent)
    return CIContext().createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
  }

  // MARK: - Canvas

  struct CanvasPixels {
    let width: Int
    let height: Int
    /// RGBA, top-left origin, Display P3.
    let rgba: [UInt8]
  }

  /// Renders `document` the way `EditingCanvasView` sets up its surfaces for
  /// `route`, with the crop output filling the drawable.
  private static func renderCanvas(
    document: ImageEditorFeature,
    source: CGImage,
    route: CanvasRoute
  ) throws -> CanvasPixels {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize)
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: crop))
    let outputSize = geometry.outputSize
    let outputBounds = geometry.outputBounds
    let editingSource = CIImage(cgImage: source)
    let plan = EditingCanvasView.CanvasRenderPlan(localBlur: document.localBlur)

    let renderer: EditingCanvasRenderer
    let records: [EditingCanvasStrokeRecord]
    let postCrop: EditingCanvasView.CanvasPostCrop?
    switch route {
    case .cropViewportBase, .cropLocalAdjustment:
      renderer = EditingCanvasRenderer(canvasSize: imageSize, device: device)
      renderer.setRenderImages(try #require(EditingCanvasRenderImageFactory.makeRenderImages(
        editingSourceImage: editingSource,
        effects: document.effects.canvasEffect,
        canvasSize: imageSize,
        mode: plan.canvasMode
      )))
      // The crop surface shows the source through the crop's mapping; the
      // guide frames the crop output.
      renderer.setViewport(.init(
        visibleContentRect: CGRect(origin: .zero, size: imageSize),
        contentToCanvasTransform: geometry.inputToOutputTransform
      ))
      records = plan.committedStrokes(in: nil, domainHeight: imageSize.height)
      postCrop = EditingCanvasView.CanvasPostCrop(
        effect: document.canvasPostCropEffect,
        guideFrame: outputBounds,
        imageSize: imageSize
      )

    case .toolWithoutStrokes, .toolWithStrokes, .blur:
      renderer = EditingCanvasRenderer(canvasSize: outputSize, device: device)
      // The Blur target previews its content even before the first stroke.
      let mode: EditingCanvasMode = route == .blur
        ? .localAdjustment(effect: AnyImageEffect(document.localBlur?.content ?? ImageEditorFeature.defaultLocalBlurContent))
        : plan.canvasMode
      renderer.setRenderImages(try #require(EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
        editingSourceImage: editingSource,
        effects: document.effects.canvasEffect,
        geometry: geometry,
        mode: mode
      )))
      renderer.setViewport(.init(visibleContentRect: outputBounds, contentToCanvasTransform: .identity))
      records = plan.committedStrokes(in: geometry, domainHeight: imageSize.height)
      let viewport = try #require(CanvasViewport(
        contentBounds: outputBounds,
        canvasBounds: outputBounds,
        contentToCanvasTransform: .identity,
        contentScaleFactor: 1
      ))
      postCrop = EditingCanvasView.CanvasPostCrop(
        effect: document.canvasPostCropEffect,
        geometry: geometry,
        viewport: viewport
      )
    }

    var activeStroke: EditingCanvasRenderer.ActiveStroke?
    if route == .blur {
      // The stroke is live: the brush the record carries, not yet committed.
      let record = try #require(records.first)
      #expect(records.count == 1)
      activeStroke = .init(brush: record.brush, stamps: record.stamps)
    } else {
      renderer.setCommittedStrokes(records)
    }
    renderer.setPostCrop(
      effect: postCrop?.effect,
      frame: postCrop?.frame ?? .null,
      chainEntry: postCrop?.chainEntry ?? .null
    )

    let target = try makeTarget(device: device, size: outputSize)
    let storage = try render(renderer, into: target, viewportSize: outputSize, activeStroke: activeStroke)

    return CanvasPixels(
      width: target.width,
      height: target.height,
      rgba: topLeft(storage, width: target.width, height: target.height)
    )
  }

  /// Texture rows run bottom-up from the canvas's y-down space: returns the
  /// pixels top-left first, BGRA reordered to RGBA.
  private static func topLeft(_ storage: [UInt8], width: Int, height: Int) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: storage.count)
    for row in 0..<height {
      let y = height - 1 - row
      for x in 0..<width {
        let from = (row * width + x) * 4
        let to = (y * width + x) * 4
        rgba[to] = storage[from + 2]
        rgba[to + 1] = storage[from + 1]
        rgba[to + 2] = storage[from]
        rgba[to + 3] = storage[from + 3]
      }
    }
    return rgba
  }

  private static func makeTarget(device: MTLDevice, size: CGSize) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(size.width.rounded()),
      height: Int(size.height.rounded()),
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
  }

  /// Raw BGRA storage after GPU completion.
  private static func render(
    _ renderer: EditingCanvasRenderer,
    into texture: MTLTexture,
    viewportSize: CGSize,
    activeStroke: EditingCanvasRenderer.ActiveStroke? = nil
  ) throws -> [UInt8] {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    let submitted = try #require(renderer.render(.init(
      texture: texture,
      renderPassDescriptor: descriptor,
      viewportSize: viewportSize,
      activeStroke: activeStroke,
      preferredFramesPerSecond: 60
    )))
    submitted.waitUntilCompleted()
    try #require(submitted.status == .completed)
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

  /// RGBA in Display P3, top-left origin.
  private static func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
      data: &bytes,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: displayP3,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
  }
}
