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

import Foundation
import Metal
import simd

/// The brush-mask rasterizer shared by the live editing canvas and the
/// parametric export.
///
/// Stamps are drawn as instanced quads with the `brushStampAlpha` falloff and a
/// `.max` blend, so overlapping stamps never exceed the brush opacity. The live
/// canvas encodes into its viewport mask texture every frame, and
/// `FeatureGraphCompiler` encodes into the Core Image tiles that
/// `BrushMaskImageProcessor` is asked for. Both go through
/// ``encode(_:targetSize:into:)``, so preview and export share the shader, the
/// blend state, and the stamp encoding; they differ only in how stamp
/// coordinates map into their target.
public enum BrushStampPipeline {

  /// One soft circular stamp in target pixels.
  ///
  /// `center` is measured from the target's first column and first texture
  /// row. This layout is ABI against the MSL `BrushStampInstance` struct in
  /// `BrushMaskRenderShader.metal` (`float2 center; float radius; float
  /// hardness; float opacity; float padding;`).
  public struct Stamp: Equatable, Sendable {
    public var center: SIMD2<Float>
    public var radius: Float
    public var hardness: Float
    public var opacity: Float
    var padding: Float = 0

    public init(center: SIMD2<Float>, radius: Float, hardness: Float, opacity: Float) {
      self.center = center
      self.radius = radius
      self.hardness = hardness
      self.opacity = opacity
    }

    /// Whether any pixel of a `targetSize` target can receive this stamp.
    func touches(targetSize: SIMD2<Float>) -> Bool {
      radius > 0
        && opacity > 0
        && center.x + radius > 0
        && center.x - radius < targetSize.x
        && center.y + radius > 0
        && center.y - radius < targetSize.y
    }
  }

  /// Buffer indices matching `brushStampVertex` in `BrushMaskRenderShader.metal`.
  static let stampsBufferIndex = 0
  static let targetSizeBufferIndex = 1

  /// `setVertexBytes` accepts at most 4 KB; larger stamp lists use a buffer.
  private static let inlineBytesLimit = 4096

  private struct PipelineKey: Hashable {
    let registryID: UInt64
    let pixelFormat: UInt
  }

  private static let pipelineLock = NSLock()
  // Guarded by pipelineLock.
  private nonisolated(unsafe) static var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]

  /// Returns the brush-stamp render pipeline for `pixelFormat` on `device`.
  ///
  /// Pipelines are cached per device and pixel format: the live canvas draws
  /// into an 8-bit mask texture, while Core Image hands the export its working
  /// format.
  public static func renderPipelineState(
    device: MTLDevice,
    pixelFormat: MTLPixelFormat
  ) throws -> MTLRenderPipelineState {
    let key = PipelineKey(registryID: device.registryID, pixelFormat: pixelFormat.rawValue)

    pipelineLock.lock()
    defer { pipelineLock.unlock() }

    if let cached = pipelines[key] {
      return cached
    }

    let library = try device.makeLibrary(URL: BrushStampMetalLibrary.url())
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "brushStampVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "brushStampFragment")
    descriptor.colorAttachments[0].pixelFormat = pixelFormat
    descriptor.colorAttachments[0].isBlendingEnabled = true
    // Overlapping stamps keep the per-channel maximum. Metal ignores the blend
    // factors for `.max`, but they are set to `.one` for clarity.
    descriptor.colorAttachments[0].rgbBlendOperation = .max
    descriptor.colorAttachments[0].alphaBlendOperation = .max
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    pipelines[key] = pipeline
    return pipeline
  }

  /// Draws `stamps` into the encoder's render target as one instanced draw.
  ///
  /// Stamps that cannot reach any pixel of a `targetSize` target are skipped.
  /// The encoder's pipeline state must come from
  /// ``renderPipelineState(device:pixelFormat:)`` for the target's pixel format.
  public static func encode(
    _ stamps: [Stamp],
    targetSize: SIMD2<Float>,
    into encoder: MTLRenderCommandEncoder
  ) {
    let visibleStamps = stamps.filter { $0.touches(targetSize: targetSize) }
    guard visibleStamps.isEmpty == false else {
      return
    }

    let didBindStamps = visibleStamps.withUnsafeBytes { bytes -> Bool in
      guard let baseAddress = bytes.baseAddress else {
        return false
      }
      if bytes.count <= inlineBytesLimit {
        encoder.setVertexBytes(baseAddress, length: bytes.count, index: stampsBufferIndex)
        return true
      }
      guard let buffer = encoder.device.makeBuffer(
        bytes: baseAddress,
        length: bytes.count,
        options: .storageModeShared
      ) else {
        return false
      }
      encoder.setVertexBuffer(buffer, offset: 0, index: stampsBufferIndex)
      return true
    }
    guard didBindStamps else {
      return
    }

    var targetSize = targetSize
    encoder.setVertexBytes(
      &targetSize,
      length: MemoryLayout<SIMD2<Float>>.stride,
      index: targetSizeBufferIndex
    )
    encoder.drawPrimitives(
      type: .triangleStrip,
      vertexStart: 0,
      vertexCount: 4,
      instanceCount: visibleStamps.count
    )
  }
}
