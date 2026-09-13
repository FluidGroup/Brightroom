import CoreGraphics
import CoreImage
import Metal
import Testing

@testable import BrightroomParametric
@testable import BrightroomUI

/// Exercises the canvas's actual GPU submission path without a view or drawable.
/// Pixel checks cover image replacement, orientation, and stroke/cache lifetimes
/// across successive frames, rather than duplicating the renderer's cache keys.
@MainActor
struct EditingCanvasRendererTests {

  private let contentBounds = CGRect(x: 0, y: 0, width: 80, height: 60)
  private let viewportSize = CGSize(width: 80, height: 80)

  @Test func `Same-sized source replacement and an empty viewport discard stale pixels`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = EditingCanvasRenderer(canvasSize: contentBounds.size, device: device)
    let target = try makeTarget(device: device)
    renderer.setViewport(.init(visibleContentRect: contentBounds, contentToCanvasTransform: .identity))

    let empty = try render(renderer, into: target)
    #expect(empty.allSatisfy { $0 == 0 })

    renderer.setRenderImages(images(source: solid(.init(red: 1, green: 0, blue: 0))))
    let red = try render(renderer, into: target)
    let cachedRed = try render(renderer, into: target)
    #expect(red == cachedRed)
    #expect(pixel(red, in: target, x: 20, y: 10)[2] > 180)

    renderer.setRenderImages(images(source: solid(.init(red: 0, green: 0, blue: 1))))
    let blue = try render(renderer, into: target)
    let sample = pixel(blue, in: target, x: 20, y: 10)
    #expect(sample[0] > 180)
    #expect(sample[2] < 80)

    renderer.setViewport(.init(
      visibleContentRect: contentBounds.offsetBy(dx: 120, dy: 0),
      contentToCanvasTransform: .init(translationX: -120, y: 0)
    ))
    let cleared = try render(renderer, into: target)
    #expect(cleared.allSatisfy { $0 == 0 })

    renderer.setViewport(.init(visibleContentRect: contentBounds, contentToCanvasTransform: .identity))
    let restored = try render(renderer, into: target)
    #expect(restored == blue)
  }

  @Test func `Global effect output follows the content through a rotated viewport`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = EditingCanvasRenderer(canvasSize: contentBounds.size, device: device)
    let target = try makeTarget(device: device)
    let source = CIImage(color: .init(red: 0.2, green: 0.2, blue: 0.2))
      .cropped(to: CGRect(x: 6, y: 10, width: 12, height: 16))
      .composited(over: solid(.clear))
      .cropped(to: contentBounds)
    let effects = EffectPipeline(effects: [ExposureFeature(value: 3)])
    renderer.setRenderImages(images(source: source, effects: effects))
    renderer.setViewport(.init(visibleContentRect: contentBounds, contentToCanvasTransform: .identity))
    let unrotated = try render(renderer, into: target)
    let originalSample = pixel(unrotated, in: target, x: 10, y: 16)
    #expect(originalSample[0] > 100)
    #expect(originalSample[3] == 255)

    // A quarter turn maps the patch to x:54...70, y:6...18. These probes are
    // deliberately asymmetric so a missing or doubled final y-flip is visible.
    renderer.setViewport(.init(
      visibleContentRect: contentBounds,
      contentToCanvasTransform: .init(a: 0, b: 1, c: -1, d: 0, tx: 80, ty: 0)
    ))
    let rotated = try render(renderer, into: target)
    #expect(pixel(rotated, in: target, x: 60, y: 10) == originalSample)
    #expect(pixel(rotated, in: target, x: 10, y: 60)[3] == 0)

    // Returning to the source-cache route must replace the effected output.
    renderer.setRenderImages(images(source: source))
    let unadjusted = try render(renderer, into: target)
    #expect(Int(pixel(unadjusted, in: target, x: 60, y: 10)[0]) + 60 < Int(originalSample[0]))
  }

  @Test func `Live and committed strokes agree through rotation and drawable resizing`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = EditingCanvasRenderer(canvasSize: contentBounds.size, device: device)
    let target = try makeTarget(device: device)
    let source = solid(.init(red: 0.2, green: 0.2, blue: 0.2))
    let effect = EffectPipeline(effects: [ExposureFeature(value: 3)])
    renderer.setRenderImages(images(source: source, localEffect: effect))
    renderer.setViewport(.init(visibleContentRect: contentBounds, contentToCanvasTransform: .identity))

    let brush = EditingCanvasBrush(size: 16, hardness: 0.7, opacity: 0.8)
    let stamps = [CGPoint(x: 20, y: 14)]
    let base = try render(renderer, into: target)
    let live = try render(renderer, into: target, activeStroke: .init(brush: brush, stamps: stamps))
    #expect(Int(pixel(live, in: target, x: 20, y: 14)[0]) > Int(pixel(base, in: target, x: 20, y: 14)[0]) + 60)
    #expect(pixel(live, in: target, x: 60, y: 45) == pixel(base, in: target, x: 60, y: 45))

    // An active stroke belongs only to the frame that supplied it.
    let cancelled = try render(renderer, into: target)
    #expect(cancelled == base)
    renderer.setCommittedStrokes([.init(stamps: stamps, brush: brush)])
    let committed = try render(renderer, into: target)
    #expect(committed == live)

    renderer.setViewport(.init(
      visibleContentRect: contentBounds,
      contentToCanvasTransform: .init(a: 0, b: 1, c: -1, d: 0, tx: 80, ty: 0)
    ))
    let rotated = try render(renderer, into: target)
    #expect(Int(pixel(rotated, in: target, x: 66, y: 20)[0]) > Int(pixel(rotated, in: target, x: 50, y: 50)[0]) + 60)

    let largerTarget = try makeTarget(device: device, pixelSize: 160)
    renderer.drawableSizeDidChange()
    let resized = try render(renderer, into: largerTarget)
    #expect(Int(pixel(resized, in: largerTarget, x: 132, y: 40)[0]) > Int(pixel(resized, in: largerTarget, x: 100, y: 100)[0]) + 60)

    // Replacing images at the same extent invalidates the retained local-effect
    // bake as well as the viewport layers; the new source is fully black.
    renderer.setRenderImages(images(source: solid(.black), localEffect: effect))
    let replaced = try render(renderer, into: largerTarget)
    #expect(pixel(replaced, in: largerTarget, x: 132, y: 40)[0] == 0)
    #expect(pixel(replaced, in: largerTarget, x: 132, y: 40)[3] == 255)
  }

  private func solid(_ color: CIColor) -> CIImage {
    CIImage(color: color).cropped(to: contentBounds)
  }

  private func images(
    source: CIImage,
    effects: EffectPipeline = .init(),
    localEffect: EffectPipeline = .init()
  ) -> EditingCanvasRenderImages {
    let base = effects.applyIgnoringFailure(to: source, radiusReferenceExtent: contentBounds)
    let adjusted = localEffect.applyIgnoringFailure(to: base, radiusReferenceExtent: contentBounds)
    return .init(
      source: source,
      effects: effects,
      base: base,
      adjusted: adjusted,
      localEffect: localEffect,
      usesPreparedBaseImage: localEffect.hasEnabledEffects
    )
  }

  private func makeTarget(device: MTLDevice, pixelSize: Int = 80) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: pixelSize,
      height: pixelSize,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
  }

  /// Reads raw BGRA storage after GPU completion, before any compositor display.
  private func render(
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

  /// Samples a y-down viewport landmark after the renderer's final vertical
  /// flip into the Core Image destination. Raw texture storage is read directly;
  /// it has not gone through the CIImage-to-CGImage display conversion.
  private func pixel(_ pixels: [UInt8], in texture: MTLTexture, x: Int, y: Int) -> [UInt8] {
    let row = texture.height - 1 - y
    let offset = (row * texture.width + x) * 4
    return Array(pixels[offset..<offset + 4])
  }
}
