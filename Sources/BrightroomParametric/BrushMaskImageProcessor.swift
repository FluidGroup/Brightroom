//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Accelerate
import CoreImage
import Metal
import simd

/// Rasterizes a brush mask as a single Core Image node.
///
/// Core Image asks for tiles (`output.region`), and each tile is drawn with
/// `BrushStampPipeline`, the same instanced `.max` pass the live canvas draws
/// every frame. The graph therefore stays one node however many stamps the mask
/// holds, and the work follows the painted area instead of stamps × pixels.
///
/// The output is the mask's alpha field, premultiplied as `(a, a, a, a)`. Its
/// extent is the union of the stamp bounds, because the falloff is zero beyond
/// each stamp's radius.
final class BrushMaskImageProcessor: CIImageProcessorKernel {

  /// The stamps in Core Image working-space coordinates (bottom-left origin,
  /// y-up), packed as `BrushStampPipeline.Stamp` values.
  private static let stampsArgumentKey = "stamps"

  override class var outputFormat: CIFormat {
    .RGBAh
  }

  override class var synchronizeInputs: Bool {
    false
  }

  /// Returns the image of `mask` within `extent`.
  static func makeImage(_ mask: BrushMask, extent: CGRect) throws -> CIImage {
    var stamps: [BrushStampPipeline.Stamp] = []
    var coverage = CGRect.null

    for stroke in mask.strokes {
      let radius = max(stroke.brush.diameter / 2, 0)
      guard radius > 0, stroke.brush.opacity > 0 else {
        continue
      }
      for center in stroke.stamps {
        let bounds = CGRect(
          x: center.x - radius,
          y: center.y - radius,
          width: radius * 2,
          height: radius * 2
        )
        guard bounds.intersects(extent) else {
          continue
        }
        coverage = coverage.union(bounds)
        stamps.append(
          BrushStampPipeline.Stamp(
            center: SIMD2(Float(center.x), Float(center.y)),
            radius: Float(radius),
            hardness: Float(stroke.brush.hardness),
            opacity: Float(stroke.brush.opacity)
          )
        )
      }
    }

    let imageExtent = coverage.integral.intersection(extent)
    guard stamps.isEmpty == false, imageExtent.isEmpty == false else {
      return CIImage.parametricTransparent(extent: extent)
    }

    let payload = stamps.withUnsafeBytes { Data($0) }
    return try apply(
      withExtent: imageExtent,
      inputs: nil,
      arguments: [stampsArgumentKey: payload]
    )
  }

  override class func process(
    with inputs: [any CIImageProcessorInput]?,
    arguments: [String: Any]?,
    output: any CIImageProcessorOutput
  ) throws {
    guard let payload = arguments?[stampsArgumentKey] as? Data else {
      throw BrushMaskImageProcessorError.missingStamps
    }

    // Core Image hands over the tile with its first row at the top
    // (`region.maxY`), so a working-space center (y-up) moves into the tile
    // with a vertical flip.
    let region = output.region
    let stamps = decodeStamps(payload).map { stamp in
      var stamp = stamp
      stamp.center = SIMD2(
        stamp.center.x - Float(region.minX),
        Float(region.maxY) - stamp.center.y
      )
      return stamp
    }

    if let commandBuffer = output.metalCommandBuffer, let texture = output.metalTexture {
      try draw(stamps, into: texture, commandBuffer: commandBuffer)
    } else {
      try rasterizeOnCPU(
        stamps,
        width: Int(region.width),
        height: Int(region.height),
        output: output
      )
    }
  }

  private static func decodeStamps(_ payload: Data) -> [BrushStampPipeline.Stamp] {
    let count = payload.count / MemoryLayout<BrushStampPipeline.Stamp>.stride
    var stamps = [BrushStampPipeline.Stamp](
      repeating: .init(center: .zero, radius: 0, hardness: 0, opacity: 0),
      count: count
    )
    stamps.withUnsafeMutableBytes { destination in
      _ = payload.copyBytes(to: destination)
    }
    return stamps
  }

  private static func draw(
    _ stamps: [BrushStampPipeline.Stamp],
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) throws {
    let device = commandBuffer.device

    // Draw straight into the tile when Core Image allows it; otherwise draw into
    // a scratch target and copy.
    let target: MTLTexture
    let needsCopy = texture.usage.contains(.renderTarget) == false
    if needsCopy {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: texture.pixelFormat,
        width: texture.width,
        height: texture.height,
        mipmapped: false
      )
      descriptor.usage = [.renderTarget]
      descriptor.storageMode = .private
      guard let scratch = device.makeTexture(descriptor: descriptor) else {
        throw BrushMaskImageProcessorError.failedToCreateRenderTarget
      }
      target = scratch
    } else {
      target = texture
    }

    let pipeline = try BrushStampPipeline.renderPipelineState(
      device: device,
      pixelFormat: target.pixelFormat
    )
    let passDescriptor = MTLRenderPassDescriptor()
    passDescriptor.colorAttachments[0].texture = target
    passDescriptor.colorAttachments[0].loadAction = .clear
    passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    passDescriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
      throw BrushMaskImageProcessorError.failedToCreateEncoder
    }
    encoder.setRenderPipelineState(pipeline)
    BrushStampPipeline.encode(
      stamps,
      targetSize: SIMD2(Float(target.width), Float(target.height)),
      into: encoder
    )
    encoder.endEncoding()

    if needsCopy {
      guard let blit = commandBuffer.makeBlitCommandEncoder() else {
        throw BrushMaskImageProcessorError.failedToCreateEncoder
      }
      blit.copy(from: target, to: texture)
      blit.endEncoding()
    }
  }
}

// MARK: - CPU fallback

extension BrushMaskImageProcessor {

  /// Mirrors `brushStampAlpha` in `BrushStampFalloff.metalh` for Core Image
  /// contexts that hand the processor CPU memory instead of a Metal texture.
  static func brushStampAlpha(normalizedDistance: Float, hardness: Float, opacity: Float) -> Float {
    if normalizedDistance > 1 {
      return 0
    }
    var alpha: Float = 1
    if hardness < 0.999 {
      let start = min(max(hardness, 0), 0.998)
      let t = min(max((normalizedDistance - start) / (1 - start), 0), 1)
      alpha = 1 - t * t * (3 - 2 * t)
    }
    return alpha * min(max(opacity, 0), 1)
  }

  /// Rasterizes `stamps` (target pixels, row 0 first) into a `width` × `height`
  /// alpha plane, shading the same pixel centers as `brushStampFragment`.
  static func rasterizeAlpha(
    _ stamps: [BrushStampPipeline.Stamp],
    width: Int,
    height: Int
  ) -> [Float] {
    var alpha = [Float](repeating: 0, count: width * height)
    let targetSize = SIMD2(Float(width), Float(height))

    for stamp in stamps where stamp.touches(targetSize: targetSize) {
      let minX = max(Int((stamp.center.x - stamp.radius).rounded(.down)), 0)
      let maxX = min(Int((stamp.center.x + stamp.radius).rounded(.up)), width)
      let minY = max(Int((stamp.center.y - stamp.radius).rounded(.down)), 0)
      let maxY = min(Int((stamp.center.y + stamp.radius).rounded(.up)), height)
      guard minX < maxX, minY < maxY else {
        continue
      }

      for y in minY..<maxY {
        let dy = Float(y) + 0.5 - stamp.center.y
        for x in minX..<maxX {
          let dx = Float(x) + 0.5 - stamp.center.x
          let value = brushStampAlpha(
            normalizedDistance: (dx * dx + dy * dy).squareRoot() / stamp.radius,
            hardness: stamp.hardness,
            opacity: stamp.opacity
          )
          let index = y * width + x
          if value > alpha[index] {
            alpha[index] = value
          }
        }
      }
    }

    return alpha
  }

  private static func rasterizeOnCPU(
    _ stamps: [BrushStampPipeline.Stamp],
    width: Int,
    height: Int,
    output: any CIImageProcessorOutput
  ) throws {
    let alpha = rasterizeAlpha(stamps, width: width, height: height)
    let baseAddress = output.baseAddress
    let bytesPerRow = output.bytesPerRow

    switch output.format {
    case .RGBAh:
      var row = [Float](repeating: 0, count: width * 4)
      for y in 0..<height {
        for x in 0..<width {
          let value = alpha[y * width + x]
          row[x * 4] = value
          row[x * 4 + 1] = value
          row[x * 4 + 2] = value
          row[x * 4 + 3] = value
        }
        row.withUnsafeMutableBytes { source in
          var sourceBuffer = vImage_Buffer(
            data: source.baseAddress,
            height: 1,
            width: vImagePixelCount(width * 4),
            rowBytes: width * 4 * MemoryLayout<Float>.stride
          )
          var destinationBuffer = vImage_Buffer(
            data: baseAddress + y * bytesPerRow,
            height: 1,
            width: vImagePixelCount(width * 4),
            rowBytes: bytesPerRow
          )
          vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
        }
      }

    case .RGBAf:
      for y in 0..<height {
        let row = (baseAddress + y * bytesPerRow).assumingMemoryBound(to: Float.self)
        for x in 0..<width {
          let value = alpha[y * width + x]
          row[x * 4] = value
          row[x * 4 + 1] = value
          row[x * 4 + 2] = value
          row[x * 4 + 3] = value
        }
      }

    case .RGBA8, .BGRA8:
      for y in 0..<height {
        let row = (baseAddress + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
          let value = UInt8(min(max(alpha[y * width + x] * 255, 0), 255).rounded())
          row[x * 4] = value
          row[x * 4 + 1] = value
          row[x * 4 + 2] = value
          row[x * 4 + 3] = value
        }
      }

    default:
      throw BrushMaskImageProcessorError.unsupportedOutputFormat(output.format)
    }
  }
}

/// Errors thrown while Core Image renders a brush mask tile.
enum BrushMaskImageProcessorError: Error {
  case missingStamps
  case failedToCreateRenderTarget
  case failedToCreateEncoder
  case unsupportedOutputFormat(CIFormat)
}
