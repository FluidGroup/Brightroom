import CoreImage
import Foundation
import Metal
import Testing

@testable import BrightroomParametric

/// Pins the Core Image side of the shared brush rasterizer: the tile mapping
/// `BrushMaskImageProcessor` applies, the stamp layout the shader reads, and the
/// CPU fallback for contexts without Metal.
struct BrushMaskImageProcessorTests {

  private static let context = CIContext(options: [.workingColorSpace: NSNull()])

  @Test func `Stamp layout matches the shader struct`() {
    // `BrushStampInstance` in BrushMaskRenderShader.metal:
    // float2 center; float radius; float hardness; float opacity; float padding;
    #expect(MemoryLayout<BrushStampPipeline.Stamp>.size == 24)
    #expect(MemoryLayout<BrushStampPipeline.Stamp>.stride == 24)
    #expect(MemoryLayout<BrushStampPipeline.Stamp>.offset(of: \.radius) == 8)
    #expect(MemoryLayout<BrushStampPipeline.Stamp>.offset(of: \.hardness) == 12)
    #expect(MemoryLayout<BrushStampPipeline.Stamp>.offset(of: \.opacity) == 16)
  }

  /// Core Image may render the mask in any tiles. Uneven tiles that cut through
  /// asymmetric stamps must reproduce the single-pass render exactly; a wrong
  /// tile origin or flip moves alpha across the tile.
  @Test func `Tiles reproduce the single-pass mask`() throws {
    let extent = CGRect(x: 0, y: 0, width: 160, height: 120)
    let image = try FeatureGraphCompiler().renderMask(
      MaskTree(root: .brush(BrushMask(strokes: [
        BrushMaskStroke(
          stamps: [CGPoint(x: 30, y: 20), CGPoint(x: 70, y: 90), CGPoint(x: 120, y: 55)],
          brush: BrushMaskBrush(diameter: 50, hardness: 0.3, opacity: 1)
        ),
        BrushMaskStroke(
          stamps: [CGPoint(x: 150, y: 110)],
          brush: BrushMaskBrush(diameter: 30, hardness: 0.8, opacity: 0.6)
        ),
      ]))),
      extent: extent
    )

    let whole = try Self.alpha(of: image, in: extent)
    #expect(whole.value(x: 30, y: 20) > 250, "stamp missing at its authored position")
    #expect(whole.value(x: 30, y: 100) < 5, "stamp leaked to its vertical mirror")

    let tiles = [
      CGRect(x: 0, y: 0, width: 67, height: 51),
      CGRect(x: 67, y: 0, width: 93, height: 51),
      CGRect(x: 0, y: 51, width: 67, height: 69),
      CGRect(x: 67, y: 51, width: 93, height: 69),
    ]
    for tile in tiles {
      let part = try Self.alpha(of: image, in: tile)
      var mismatches = 0
      for y in Int(tile.minY)..<Int(tile.maxY) {
        for x in Int(tile.minX)..<Int(tile.maxX) where abs(Int(part.value(x: x, y: y)) - Int(whole.value(x: x, y: y))) > 1 {
          mismatches += 1
        }
      }
      #expect(mismatches == 0, "tile \(tile) differs from the single-pass render at \(mismatches) pixels")
    }
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func `CPU fallback matches the Metal pipeline`() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let width = 64
    let height = 48
    let stamps = [
      BrushStampPipeline.Stamp(center: SIMD2(20.3, 15.7), radius: 12, hardness: 0.2, opacity: 1),
      BrushStampPipeline.Stamp(center: SIMD2(40, 30), radius: 18.5, hardness: 0.72, opacity: 0.8),
      // Hard edge, partly outside the target.
      BrushStampPipeline.Stamp(center: SIMD2(62, 2), radius: 9, hardness: 1, opacity: 1),
    ]

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let commandBuffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
    encoder.setRenderPipelineState(
      try BrushStampPipeline.renderPipelineState(device: device, pixelFormat: .rgba16Float)
    )
    BrushStampPipeline.encode(stamps, targetSize: SIMD2(Float(width), Float(height)), into: encoder)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var gpu = [Float16](repeating: 0, count: width * height * 4)
    gpu.withUnsafeMutableBytes { bytes in
      texture.getBytes(
        bytes.baseAddress!,
        bytesPerRow: width * 4 * MemoryLayout<Float16>.stride,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0
      )
    }
    let cpu = BrushMaskImageProcessor.rasterizeAlpha(stamps, width: width, height: height)

    var maxDifference: Float = 0
    for index in 0..<(width * height) {
      maxDifference = max(maxDifference, abs(Float(gpu[index * 4 + 3]) - cpu[index]))
    }
    #expect(cpu.contains { $0 > 0.99 }, "CPU rasterizer drew nothing")
    #expect(maxDifference < 0.002, "CPU fallback deviates from the Metal pipeline by \(maxDifference)")
  }

  // MARK: - Helpers

  private struct AlphaPlane {
    let rect: CGRect
    let width: Int
    let pixels: [UInt8]

    /// Alpha of the pixel whose bottom-left corner is at working-space (x, y).
    func value(x: Int, y: Int) -> UInt8 {
      let column = x - Int(rect.minX)
      let row = Int(rect.maxY) - 1 - y
      return pixels[(row * width + column) * 4 + 3]
    }
  }

  private static func alpha(of image: CIImage, in rect: CGRect) throws -> AlphaPlane {
    let cgImage = try #require(context.createCGImage(image, from: rect))
    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let bitmap = try #require(CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ))
    bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return AlphaPlane(rect: rect, width: width, pixels: pixels)
  }
}
