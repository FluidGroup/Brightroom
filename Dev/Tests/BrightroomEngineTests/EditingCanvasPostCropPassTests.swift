import CoreGraphics
import CoreImage
import Metal
import Testing

@testable import BrightroomParametric
@testable import BrightroomUI

/// The renderer's post-crop pass: an effect the feature evaluates after its
/// final crop is drawn over the crop frame of each frame, with the frame as
/// its input extent, wherever the viewport places that frame.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct EditingCanvasPostCropPassTests {

  private static let contentSize = CGSize(width: 200, height: 250)
  private static let contentBounds = CGRect(origin: .zero, size: contentSize)
  private static let viewportSize = CGSize(width: 80, height: 80)

  /// A zoomed viewport with a crop frame that extends beyond the drawable.
  struct ViewportCase: CustomTestStringConvertible, Sendable {
    let zoom: CGFloat
    let translation: CGPoint
    /// The crop output in content coordinates.
    let frameInContent: CGRect

    var transform: CGAffineTransform {
      CGAffineTransform(scaleX: zoom, y: zoom)
        .concatenating(.init(translationX: translation.x, y: translation.y))
    }

    var testDescription: String { "zoom \(zoom)" }
  }

  static let viewportCases: [ViewportCase] = [
    // 200×250 content at 62×77.5 points, shifted left: the frame, at
    // (-20, 46, 31, 31) points, is partly outside the drawable. The frame's
    // edges land on whole texture pixels inside the content, so the
    // comparison is not about how Core Image covers fractional edges.
    .init(zoom: 0.31, translation: CGPoint(x: -20, y: 15), frameInContent: CGRect(x: 0, y: 100, width: 100, height: 100)),
    // Zoomed in: the frame is 240×192 points on an 80-point drawable.
    .init(zoom: 2.4, translation: CGPoint(x: -100, y: -60), frameInContent: CGRect(x: 30, y: 20, width: 100, height: 80)),
  ]

  enum Route: CaseIterable, Sendable {
    /// `renderViewportBaseImage`: the base image evaluated for the viewport.
    case baseImage
    /// `renderViewportCachedSource`: the viewport source texture.
    case cachedSource
  }

  // MARK: - Placement

  @Test(arguments: viewportCases, Route.allCases)
  func `The pass matches crop then vignette through a zoomed viewport`(
    viewportCase: ViewportCase,
    route: Route
  ) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = EditingCanvasRenderer(canvasSize: Self.contentSize, device: device)
    let target = try Self.makeTarget(device: device)
    let content = Self.gradientContent()
    renderer.setRenderImages(.init(
      source: content,
      base: content,
      adjusted: content,
      hasGlobalEffects: route == .baseImage,
      hasLocalEffect: false,
      usesPreparedBaseImage: route == .baseImage
    ))
    renderer.setViewport(.init(
      visibleContentRect: Self.contentBounds,
      contentToCanvasTransform: viewportCase.transform
    ))
    let frame = viewportCase.frameInContent.applying(viewportCase.transform)
    #expect(CGRect(origin: .zero, size: Self.viewportSize).contains(frame) == false)
    renderer.setPostCrop(
      effect: AnyImageEffect(VignetteFeature(value: 1)),
      frame: frame,
      chainEntry: Self.contentBounds
    )

    let rendered = try Self.render(renderer, into: target)
    let expected = try Self.renderExpected(
      content: content,
      frameInContent: viewportCase.frameInContent,
      vignette: 1,
      transform: viewportCase.transform,
      device: device
    )
    let unfinished = try Self.renderExpected(
      content: content,
      frameInContent: nil,
      vignette: 1,
      transform: viewportCase.transform,
      device: device
    )

    let difference = Self.maximumDifference(rendered, expected)
    #expect(
      difference <= 2,
      "the pass differs from crop then vignette by \(difference) at \(Self.worstPixel(rendered, expected)); rendered \(Self.pixel(rendered, Self.worstPixel(rendered, expected))) expected \(Self.pixel(expected, Self.worstPixel(rendered, expected)))"
    )
    #expect(
      Self.maximumDifference(rendered, unfinished) > 20,
      "the vignette must darken the frame's corners"
    )
  }

  /// A crop output placed at a fractional position, as fitting it to the
  /// view usually does. The pixels along its edges, which the content covers
  /// in part (or, through Core Image's edge sampling, in full), are vignetted
  /// like their inner neighbours; a pass over the frame rounded to the
  /// nearest pixels left a whole edge column or row at the unvignetted
  /// brightness, a bright line where the export is darkest.
  ///
  /// How much of an edge pixel the content covers depends on the drawing
  /// route, so the edge is checked by how much the pass darkens each pixel
  /// against the same frame drawn without it, and the fully covered pixels
  /// against the export recipe.
  ///
  /// A frame drawn during a live stroke is not cached, and it must reach the
  /// edges too.
  @Test(arguments: Route.allCases, [false, true])
  func `The pass reaches the edge pixels of a frame at a fractional position`(route: Route, live: Bool) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let content = Self.gradientContent()
    // The content is the crop output (the tool surface), at
    // (10.85, 1.6, 62, 77.5) points on the 80-point drawable: every edge
    // falls inside a pixel.
    let transform = CGAffineTransform(scaleX: 0.31, y: 0.31)
      .concatenating(.init(translationX: 10.85, y: 1.6))
    func render(_ effect: AnyImageEffect?) throws -> [UInt8] {
      let renderer = EditingCanvasRenderer(canvasSize: Self.contentSize, device: device)
      renderer.setRenderImages(.init(
        source: content,
        base: content,
        adjusted: content,
        hasGlobalEffects: route == .baseImage,
        hasLocalEffect: false,
        usesPreparedBaseImage: route == .baseImage
      ))
      renderer.setViewport(.init(visibleContentRect: Self.contentBounds, contentToCanvasTransform: transform))
      renderer.setPostCrop(effect: effect, frame: Self.contentBounds.applying(transform), chainEntry: Self.contentBounds)
      // A stroke outside the viewport changes no pixel.
      return try Self.render(
        renderer,
        into: try Self.makeTarget(device: device),
        activeStroke: live
          ? .init(brush: .init(size: 1, hardness: 1, opacity: 1), stamps: [CGPoint(x: -500, y: -500)])
          : nil
      )
    }
    let plain = try render(nil)
    let rendered = try render(AnyImageEffect(VignetteFeature(value: 2)))
    // The pass's input extent is the frame rounded outward to whole pixels,
    // (10, 1, 63, 79) on this 1× drawable, so its centre and radius differ
    // from the exact frame's by up to half a pixel. The recipe uses that
    // rectangle, mapped back to content space.
    let passFrame = CGRect(x: 10, y: 1, width: 63, height: 79)
    let expected = try Self.renderExpected(
      content: content,
      frameInContent: passFrame.applying(transform.inverted()),
      vignette: 2,
      transform: transform,
      device: device
    )

    let height = Int(Self.viewportSize.height)
    /// The pixel at canvas (x, y), y-down; texture rows run bottom-up.
    func at(_ pixels: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
      Self.pixel(pixels, (x, height - 1 - y))
    }
    /// How much the pass scales the pixel's green (premultiplied) channel.
    func darkening(_ x: Int, _ y: Int) -> Double {
      Double(at(rendered, x, y)[1]) / Double(at(plain, x, y)[1])
    }

    // The outermost drawn pixel of rows and columns away from the corners
    // (which pixel that is depends on the route's edge sampling), and its
    // inner neighbour.
    let width = Int(Self.viewportSize.width)
    var pairs: [(edge: (Int, Int), inner: (Int, Int))] = []
    for y in stride(from: 10, through: 70, by: 6) {
      let drawn = (0..<width).filter { at(plain, $0, y)[3] > 0 }
      let first = try #require(drawn.first)
      let last = try #require(drawn.last)
      pairs.append(((first, y), (first + 1, y)))
      pairs.append(((last, y), (last - 1, y)))
    }
    for x in stride(from: 16, through: 64, by: 6) {
      let drawn = (0..<height).filter { at(plain, x, $0)[3] > 0 }
      let first = try #require(drawn.first)
      let last = try #require(drawn.last)
      pairs.append(((x, first), (x, first + 1)))
      pairs.append(((x, last), (x, last - 1)))
    }
    for (edge, inner) in pairs {
      let edgeDarkening = darkening(edge.0, edge.1)
      let innerDarkening = darkening(inner.0, inner.1)
      #expect(innerDarkening < 0.8, "the vignette darkens \(inner)")
      #expect(
        abs(edgeDarkening - innerDarkening) <= 0.1,
        "edge \(edge) (alpha \(at(plain, edge.0, edge.1)[3])) is scaled by \(edgeDarkening), its neighbour \(inner) by \(innerDarkening)"
      )
    }

    // Fully covered pixels match crop then vignette over the pass's frame.
    // The recipe vignettes the content before the viewport scales it by
    // 0.31 and the pass after, and on this 62-point frame a value-2 vignette
    // changes by a few levels per pixel, so the two sample it a few levels
    // apart (measured: 4 and 5).
    var largest = 0
    for y in 0..<height {
      for x in 0..<width where at(plain, x, y)[3] == 255 && at(expected, x, y)[3] == 255 {
        largest = max(largest, zip(at(rendered, x, y), at(expected, x, y)).map { abs(Int($0) - Int($1)) }.max()!)
      }
    }
    #expect(largest <= 6, "covered pixels differ from crop then vignette by \(largest)")
  }

  /// The pass replaces only the frame's pixels: every other pixel, including
  /// the content's fractional edges, is the one drawn without a pass. Under
  /// a pass every frame goes through the half-float pre-finish texture, which
  /// may round a channel by one level; a live stroke makes a frame one that
  /// is not cached.
  @Test(arguments: Route.allCases, [true, false])
  func `Pixels outside the frame are drawn as without a pass`(route: Route, cached: Bool) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let content = Self.gradientContent()
    // 200×250 content at 62×77.5 points: its bottom edge is fractional.
    let transform = CGAffineTransform(scaleX: 0.31, y: 0.31).concatenating(.init(translationX: -20, y: -10))
    let frame = CGRect(x: 5, y: 20, width: 20, height: 30)
    // A stroke outside the viewport changes no pixel but makes each frame
    // live, so it is not cached.
    let liveStroke = EditingCanvasRenderer.ActiveStroke(
      brush: .init(size: 1, hardness: 1, opacity: 1),
      stamps: [CGPoint(x: -500, y: -500)]
    )
    func render(_ effect: AnyImageEffect?) throws -> [UInt8] {
      let renderer = EditingCanvasRenderer(canvasSize: Self.contentSize, device: device)
      renderer.setRenderImages(.init(
        source: content,
        base: content,
        adjusted: content,
        hasGlobalEffects: route == .baseImage,
        hasLocalEffect: false,
        usesPreparedBaseImage: route == .baseImage
      ))
      renderer.setViewport(.init(visibleContentRect: Self.contentBounds, contentToCanvasTransform: transform))
      renderer.setPostCrop(effect: effect, frame: frame, chainEntry: Self.contentBounds)
      let pixels = try Self.render(
        renderer,
        into: try Self.makeTarget(device: device),
        activeStroke: cached ? nil : liveStroke
      )
      #expect(renderer.cacheMissCounts.preFinish == (effect != nil && cached ? 1 : 0))
      return pixels
    }

    let plain = try render(nil)
    let finished = try render(AnyImageEffect(VignetteFeature(value: 2)))
    var insideDifference = 0
    for row in 0..<Int(Self.viewportSize.height) {
      for x in 0..<Int(Self.viewportSize.width) {
        // Texture rows run bottom-up from the y-down canvas.
        let y = Int(Self.viewportSize.height) - 1 - row
        let lhs = Self.pixel(plain, (x, row))
        let rhs = Self.pixel(finished, (x, row))
        if frame.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
          insideDifference = max(insideDifference, zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.max()!)
        } else if zip(lhs, rhs).contains(where: { abs(Int($0) - Int($1)) > 1 }) {
          Issue.record("pixel (\(x), \(y)) outside the frame changed from \(lhs) to \(rhs)")
          return
        }
      }
    }
    #expect(insideDifference > 20, "the vignette must darken the frame's corners")
  }

  // MARK: - Frame-only changes

  @Test func `Moving only the frame redraws from the cached image`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = EditingCanvasRenderer(canvasSize: Self.contentSize, device: device)
    let target = try Self.makeTarget(device: device)
    // The composite route: a local effect under a committed stroke.
    let content = Self.gradientContent()
    let adjusted = AnyImageEffect(ExposureFeature(ev: 1))
      .applyIgnoringFailure(to: content, chainEntryExtent: Self.contentBounds, renderScale: 1)
    renderer.setRenderImages(.init(
      source: content,
      base: content,
      adjusted: adjusted,
      hasGlobalEffects: false,
      hasLocalEffect: true,
      usesPreparedBaseImage: true
    ))
    renderer.setCommittedStrokes([
      .init(stamps: [CGPoint(x: 60, y: 40)], brush: .init(size: 40, hardness: 0.7, opacity: 1)),
    ])
    let transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
    renderer.setViewport(.init(visibleContentRect: Self.contentBounds, contentToCanvasTransform: transform))
    let vignette = AnyImageEffect(VignetteFeature(value: 1.5))

    let frameA = CGRect(x: 0, y: 0, width: 50, height: 60)
    #expect(renderer.setPostCrop(effect: vignette, frame: frameA, chainEntry: Self.contentBounds))
    let first = try Self.render(renderer, into: target)
    let afterBake = renderer.cacheMissCounts
    #expect(afterBake.preFinish == 1)

    for frame in [CGRect(x: 20, y: 0, width: 60, height: 50), CGRect(x: 10, y: 10, width: 40, height: 40)] {
      #expect(renderer.setPostCrop(effect: vignette, frame: frame, chainEntry: Self.contentBounds))
      let moved = try Self.render(renderer, into: target)
      #expect(renderer.cacheMissCounts == afterBake, "a frame-only change must not rebuild a cache")
      #expect(Self.maximumDifference(first, moved) > 20, "the vignette follows the frame")

      // The cached route draws what a fresh renderer draws.
      let fresh = EditingCanvasRenderer(canvasSize: Self.contentSize, device: device)
      fresh.setRenderImages(.init(
        source: content,
        base: content,
        adjusted: adjusted,
        hasGlobalEffects: false,
        hasLocalEffect: true,
        usesPreparedBaseImage: true
      ))
      fresh.setCommittedStrokes([
        .init(stamps: [CGPoint(x: 60, y: 40)], brush: .init(size: 40, hardness: 0.7, opacity: 1)),
      ])
      fresh.setViewport(.init(visibleContentRect: Self.contentBounds, contentToCanvasTransform: transform))
      fresh.setPostCrop(effect: vignette, frame: frame, chainEntry: Self.contentBounds)
      let freshPixels = try Self.render(fresh, into: try Self.makeTarget(device: device))
      #expect(Self.maximumDifference(moved, freshPixels) <= 1)
    }

    // A viewport change rebuilds the image under the pass, in the same
    // texture.
    renderer.setViewport(.init(
      visibleContentRect: Self.contentBounds,
      contentToCanvasTransform: transform.concatenating(.init(translationX: 4, y: 0))
    ))
    _ = try Self.render(renderer, into: target)
    #expect(renderer.cacheMissCounts.preFinish == 2)
    #expect(renderer.cacheMissCounts.preFinishTexture == 1)
    #expect(renderer.hasPreFinishCache)

    // A hidden canvas releases it.
    renderer.releasePreFinishCache()
    #expect(renderer.hasPreFinishCache == false)
  }

  /// Pan, zoom, and straighten ticks change the viewport on every frame, so
  /// each one renders the image under the pass again; they reuse one
  /// drawable-size texture for it instead of allocating one per tick, on
  /// every drawing route.
  @Test(arguments: Route.allCases, [false, true])
  func `Viewport ticks with a post-crop effect allocate one texture`(route: Route, composite: Bool) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = EditingCanvasRenderer(canvasSize: Self.contentSize, device: device)
    let target = try Self.makeTarget(device: device)
    let content = Self.gradientContent()
    renderer.setRenderImages(.init(
      source: content,
      base: content,
      adjusted: composite
        ? AnyImageEffect(ExposureFeature(ev: 1)).applyIgnoringFailure(to: content, chainEntryExtent: Self.contentBounds, renderScale: 1)
        : content,
      hasGlobalEffects: route == .baseImage,
      hasLocalEffect: composite,
      usesPreparedBaseImage: route == .baseImage || composite
    ))
    if composite {
      renderer.setCommittedStrokes([
        .init(stamps: [CGPoint(x: 60, y: 40)], brush: .init(size: 40, hardness: 0.7, opacity: 1)),
      ])
    }
    let vignette = AnyImageEffect(VignetteFeature(value: 1))
    for tick in 0..<30 {
      let transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        .concatenating(.init(translationX: CGFloat(tick), y: 0))
      renderer.setViewport(.init(visibleContentRect: Self.contentBounds, contentToCanvasTransform: transform))
      renderer.setPostCrop(
        effect: vignette,
        frame: CGRect(x: 0, y: 0, width: 50, height: 60).applying(.init(translationX: CGFloat(tick), y: 0)),
        chainEntry: Self.contentBounds
      )
      _ = try Self.render(renderer, into: target)
    }
    #expect(renderer.cacheMissCounts.preFinish == 30)
    #expect(renderer.cacheMissCounts.preFinishTexture == 1)

    // Removing the pass releases the texture; setting it again allocates one.
    renderer.setPostCrop(effect: nil, frame: .null, chainEntry: .null)
    #expect(renderer.hasPreFinishCache == false)
    renderer.setPostCrop(effect: vignette, frame: CGRect(x: 0, y: 0, width: 50, height: 60), chainEntry: Self.contentBounds)
    _ = try Self.render(renderer, into: target)
    #expect(renderer.cacheMissCounts.preFinishTexture == 2)
  }

  @Test func `Without a post-crop effect a moving frame requests no frame`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = EditingCanvasRenderer(canvasSize: Self.contentSize, device: device)
    let vignette = AnyImageEffect(VignetteFeature(value: 1))
    let frameA = CGRect(x: 0, y: 0, width: 40, height: 40)
    let frameB = CGRect(x: 10, y: 0, width: 40, height: 40)

    #expect(renderer.setPostCrop(effect: nil, frame: frameA, chainEntry: Self.contentBounds) == false)
    #expect(renderer.setPostCrop(effect: nil, frame: frameB, chainEntry: Self.contentBounds) == false)
    #expect(renderer.setPostCrop(effect: vignette, frame: frameB, chainEntry: Self.contentBounds))
    #expect(renderer.setPostCrop(effect: vignette, frame: frameB, chainEntry: Self.contentBounds) == false)
    #expect(renderer.setPostCrop(effect: vignette, frame: frameA, chainEntry: Self.contentBounds))
    #expect(
      renderer.setPostCrop(effect: AnyImageEffect(VignetteFeature(value: 2)), frame: frameA, chainEntry: Self.contentBounds)
    )
    #expect(renderer.setPostCrop(effect: nil, frame: frameA, chainEntry: Self.contentBounds))
    #expect(renderer.setPostCrop(effect: nil, frame: frameB, chainEntry: Self.contentBounds) == false)
  }

  // MARK: - Drawing after the composite

  /// The pass draws over the brush composite, while the export applies the
  /// vignette to the composite's crop output. Both are the same image because
  /// the vignette scales each pixel by a factor of its position alone, which
  /// commutes with the alpha blend.
  @Test(arguments: [1.0, 2.0, -1.0])
  func `The vignette of a blend is the blend of the vignettes`(value: Double) throws {
    let extent = CGRect(x: 0, y: 0, width: 96, height: 64)
    let base = Self.gradientContent().cropped(to: extent)
    let adjusted = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.1)).cropped(to: extent)
    let mask = CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(x: 30, y: 30),
        "inputRadius0": 5,
        "inputRadius1": 40,
        "inputColor0": CIColor.white,
        "inputColor1": CIColor.black,
      ]
    )!.outputImage!.cropped(to: extent)
    let vignette = VignetteFeature(value: value)

    func blend(_ foreground: CIImage, _ background: CIImage) -> CIImage {
      foreground.applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask]
      ).cropped(to: extent)
    }
    func vignetted(_ image: CIImage) -> CIImage {
      vignette.applyIgnoringFailure(to: image, chainEntryExtent: extent, renderScale: 1)
    }

    let vignetteOfBlend = vignetted(blend(adjusted, base))
    let blendOfVignettes = blend(vignetted(adjusted), vignetted(base))
    let context = CIContext(options: [
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
    ])
    let lhs = Self.rgba8(vignetteOfBlend, extent: extent, context: context)
    let rhs = Self.rgba8(blendOfVignettes, extent: extent, context: context)
    #expect(Self.maximumDifference(lhs, rhs) <= 1)
    #expect(Self.maximumDifference(lhs, Self.rgba8(blend(adjusted, base), extent: extent, context: context)) > 10)
  }

  // MARK: - Helpers

  /// A horizontal grey ramp over the content, in the canvas's y-down content
  /// space. It is bitmap-backed, as the canvas's images are, so Core Image
  /// samples its edges as it samples the canvas's.
  private static func gradientContent() -> CIImage {
    let ramp = CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: contentSize.width, y: 0),
        "inputColor0": CIColor(red: 0.3, green: 0.35, blue: 0.4),
        "inputColor1": CIColor(red: 0.8, green: 0.75, blue: 0.7),
      ]
    )!.outputImage!.cropped(to: contentBounds)
    let bitmap = CIContext().createCGImage(
      ramp,
      from: contentBounds,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )!
    return CIImage(cgImage: bitmap)
  }

  /// Crop then vignette in content space, composited over the content (the
  /// crop guide shows the uncropped picture around the frame), placed by the
  /// viewport and drawn as the renderer draws: y-flipped into the texture.
  private static func renderExpected(
    content: CIImage,
    frameInContent: CGRect?,
    vignette: Double,
    transform: CGAffineTransform,
    device: MTLDevice
  ) throws -> [UInt8] {
    var image = content
    if let frameInContent {
      let radius = max(frameInContent.width, frameInContent.height) * 0.5
      // Clamped, so a frame that reaches past the content keeps its size.
      image = content
        .clampedToExtent()
        .cropped(to: frameInContent)
        .applyingFilter("CIVignetteEffect", parameters: [
          kCIInputCenterKey: CIVector(x: frameInContent.midX, y: frameInContent.midY),
          kCIInputRadiusKey: radius,
          kCIInputIntensityKey: vignette,
          "inputFalloff": 0.5,
        ])
        .cropped(to: frameInContent)
        .composited(over: content)
    }
    let texture = try makeTarget(device: device)
    let renderBounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
    let textureScale = CGAffineTransform(
      scaleX: renderBounds.width / viewportSize.width,
      y: renderBounds.height / viewportSize.height
    )
    let drawable = image
      .transformed(by: transform.concatenating(textureScale))
      .cropped(to: renderBounds)
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: renderBounds.height))
      .cropped(to: renderBounds)
    let queue = try #require(device.makeCommandQueue())
    let context = CIContext(mtlCommandQueue: queue, options: [
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
    ])
    let commandBuffer = try #require(queue.makeCommandBuffer())
    context.render(
      drawable,
      to: texture,
      commandBuffer: commandBuffer,
      bounds: renderBounds,
      colorSpace: EditingCanvasImageProcessing.drawableColorSpace
    )
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return read(texture)
  }

  private static func makeTarget(device: MTLDevice) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: Int(viewportSize.width),
      height: Int(viewportSize.height),
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
  }

  private static func render(
    _ renderer: EditingCanvasRenderer,
    into texture: MTLTexture,
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
    try #require(submitted.status == .completed, "GPU submission failed: \(String(describing: submitted.error))")
    return read(texture)
  }

  private static func read(_ texture: MTLTexture) -> [UInt8] {
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

  private static func rgba8(_ image: CIImage, extent: CGRect, context: CIContext) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
    context.render(
      image,
      toBitmap: &pixels,
      rowBytes: Int(extent.width) * 4,
      bounds: extent,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
    return pixels
  }

  /// The texture pixel (x, row) with the largest channel difference.
  private static func worstPixel(_ lhs: [UInt8], _ rhs: [UInt8]) -> (x: Int, row: Int) {
    var worst = 0
    var index = 0
    for (offset, pair) in zip(lhs, rhs).enumerated() where abs(Int(pair.0) - Int(pair.1)) > worst {
      worst = abs(Int(pair.0) - Int(pair.1))
      index = offset / 4
    }
    let width = Int(viewportSize.width)
    return (index % width, index / width)
  }

  private static func pixel(_ pixels: [UInt8], _ location: (x: Int, row: Int)) -> [UInt8] {
    let offset = (location.row * Int(viewportSize.width) + location.x) * 4
    return Array(pixels[offset..<offset + 4])
  }

  private static func maximumDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
    zip(lhs, rhs).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
  }
}
