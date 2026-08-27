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

import CoreImage
import BrightroomEngine
import BrightroomParametric
import Metal
import simd

/// A standalone, testable wrapper around the **live** Metal brush-mask render
/// pipeline used by `_EditingCanvasMTKView`.
///
/// `_EditingCanvasMTKView` builds and drives the same pipeline inline for live
/// painting, where the encoding is interleaved with viewport math, drawable
/// management, and stroke state. This type extracts only the rasterization
/// kernel — a single off-screen stamp pass — so the live rasterizer can be
/// exercised in isolation and proven, by test, to match the parametric Core
/// Image CIKernel rasterizer (`FeatureGraphCompiler.renderMask`) that the
/// shared falloff establishes as the contract.
///
/// The pipeline, the uniform layout, and the per-stamp encoding all come from
/// `BrushMaskPipeline`, the same construction the live view uses — so this is
/// not a replica of the live pipeline, it *is* the live pipeline, and the parity
/// test covers the live path's construction by construction.
struct BrushMaskMetalRasterizer {

  /// One soft circular stamp to rasterize. `center` and `pixelRadius` are in
  /// canvas pixels (the identity / no-viewport domain — see `rasterize`).
  struct Stamp {
    var center: CGPoint
    var pixelRadius: CGFloat
    var hardness: Float
    var opacity: Float

    init(center: CGPoint, pixelRadius: CGFloat, hardness: Float, opacity: Float) {
      self.center = center
      self.pixelRadius = pixelRadius
      self.hardness = hardness
      self.opacity = opacity
    }
  }

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState

  /// Builds the brush-mask pipeline on `device`. Returns `nil` if a command
  /// queue, the shader library, or the pipeline state cannot be created.
  init?(device: MTLDevice) {
    guard let commandQueue = device.makeCommandQueue() else {
      return nil
    }
    do {
      let pipeline = try BrushMaskPipeline.make(device: device)
      self.device = device
      self.commandQueue = commandQueue
      self.pipeline = pipeline
    } catch {
      return nil
    }
  }

  /// Rasterizes `stamps` into an `.rgba8Unorm` texture of `canvasPixelSize` and
  /// returns it as a `CIImage` cropped to that extent.
  ///
  /// Coordinates are the **identity (no-viewport)** domain: `center` is in
  /// canvas pixels and the vertex shader maps it to clip space. There is no
  /// content→view scale here, so this matches `FeatureGraphCompiler.renderMask`
  /// where the stamp center is given directly in the mask extent.
  ///
  /// ## Orientation — no extra flip is needed
  ///
  /// `brushStampVertex` maps the center to clip space with
  /// `clip.y = 1 - center.y / canvasSize.y * 2` (so `center.y = 0` → clip `+1` →
  /// top texture row: the stamp is stored y-down in the texture). `CIImage(mtlTexture:)`
  /// then applies its OWN vertical flip when wrapping (Metal top-left origin →
  /// Core Image bottom-left origin). Those two flips compose: a stamp passed with
  /// `center = (x, y)` lands at CI-y `y` in the wrapped image — exactly where the
  /// parametric kernel (`renderMask`, `dest.coord()` y-up) places the same `y`.
  /// So the wrapped texture is already in `renderMask`'s frame and is directly
  /// comparable to the export/preview mask without any added transform.
  /// (The live view's `renderDrawableImage` flip is a separate, drawable-only
  /// presentation step and does not belong here.)
  func rasterize(stamps: [Stamp], canvasPixelSize: CGSize) -> CIImage? {
    let width = Int(canvasPixelSize.width.rounded())
    let height = Int(canvasPixelSize.height.rounded())
    guard width > 0, height > 0 else {
      return nil
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead, .renderTarget]
    descriptor.storageMode = .shared

    guard
      let texture = device.makeTexture(descriptor: descriptor),
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return nil
    }

    let passDescriptor = MTLRenderPassDescriptor()
    passDescriptor.colorAttachments[0].texture = texture
    passDescriptor.colorAttachments[0].loadAction = .clear
    passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    passDescriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
      return nil
    }

    encoder.setRenderPipelineState(pipeline)

    let canvasSize = SIMD2(Float(width), Float(height))
    for stamp in stamps {
      BrushMaskPipeline.encodeStamp(
        .init(
          canvasSize: canvasSize,
          center: SIMD2(Float(stamp.center.x), Float(stamp.center.y)),
          radius: Float(stamp.pixelRadius),
          hardness: stamp.hardness,
          opacity: stamp.opacity
        ),
        into: encoder
      )
    }

    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let extent = CGRect(origin: .zero, size: CGSize(width: width, height: height))
    guard
      let textureImage = CIImage(
        mtlTexture: texture,
        options: [.colorSpace: EditingCanvasImageProcessing.maskColorSpace]
      )
    else {
      return nil
    }

    // No extra flip: `brushStampVertex` maps a y-down canvas stamp to clip space
    // via `1 - y/h*2`, and `CIImage(mtlTexture:)` applies its own vertical flip on
    // wrap; the two compose so the stamp lands at CI y-up = the input y — the
    // SAME coordinate the parametric `brushStamp` kernel uses (`dest.coord()`).
    // So the wrapped texture is already in `renderMask`'s frame.
    return textureImage.cropped(to: extent)
  }
}
