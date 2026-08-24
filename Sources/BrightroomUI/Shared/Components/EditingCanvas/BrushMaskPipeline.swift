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

import BrightroomParametric
import Metal
import simd

/// The single construction site for the brush-mask Metal render pipeline, its
/// uniform layout, and its per-stamp encoding.
///
/// Two paths rasterize brush stamps with this shader family:
///
/// - `_EditingCanvasMTKView` draws the committed and in-flight strokes live,
///   every frame, into the viewport mask texture.
/// - `BrushMaskMetalRasterizer` draws a stamp list off-screen so
///   `BrushMaskRasterizerParityTests` can prove that live rasterization matches
///   the parametric Core Image kernel (`FeatureGraphCompiler.renderMask`).
///
/// Those two paths **must** evolve together. The parity test only means anything
/// if the pipeline it exercises is the pipeline the live view drives, and
/// `StampUniforms` is ABI against the MSL struct in
/// `BrushMaskRenderShader.metal`. Both previously built their own copy of this
/// construction, kept equal only by doc comments asserting they were identical;
/// they now share this one definition, so a change to the blend state, the pixel
/// format, the uniform layout, or the buffer index reaches both paths — and the
/// parity test covers the live path's construction by construction.
enum BrushMaskPipeline {

  /// Buffer index the stamp uniforms are bound at, matching `[[buffer(0)]]` on
  /// both `brushStampVertex` and `brushStampFragment`.
  static let stampUniformsBufferIndex = 0

  /// Uniform values for drawing one soft circular brush stamp into a mask
  /// texture.
  ///
  /// This layout is ABI against the MSL `BrushStampUniforms` struct in
  /// `BrushMaskRenderShader.metal` (`float2 canvasSize; float2 center; float
  /// radius; float hardness; float opacity; float padding;`). Changing a field
  /// here without changing the shader silently reinterprets the bytes.
  struct StampUniforms {
    var canvasSize: SIMD2<Float>
    var center: SIMD2<Float>
    var radius: Float
    var hardness: Float
    var opacity: Float
    var _padding: Float = 0
  }

  /// Loads the compiled brush-stamp shader library.
  ///
  /// The compiled library lives in BrightroomParametric so the live shader and
  /// the parametric export kernel are built as one brush-mask rasterization
  /// family.
  static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
    return try device.makeLibrary(URL: BrushStampMetalLibrary.url())
  }

  /// Builds the brush-stamp render pipeline state on `device`.
  static func make(
    device: MTLDevice,
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "brushStampVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "brushStampFragment")
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    // Overlapping stamps take the per-channel maximum, matching the parametric
    // mask's `CIBlendKernel.componentMax` accumulation
    // (`FeatureGraphCompiler.render(_:BrushMask)`). Metal ignores the blend
    // factors for `.max`, but they are set to `.one` for clarity.
    descriptor.colorAttachments[0].rgbBlendOperation = .max
    descriptor.colorAttachments[0].alphaBlendOperation = .max
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  /// Loads the shader library and builds the pipeline state in one step.
  static func make(device: MTLDevice) throws -> MTLRenderPipelineState {
    return try make(device: device, library: makeLibrary(device: device))
  }

  /// Binds `uniforms` to both stages and draws the stamp quad.
  ///
  /// The quad is the four-vertex triangle strip `brushStampVertex` expands from
  /// `vertex_id`; there is no vertex buffer. The caller is responsible for
  /// having set `encoder`'s pipeline state to one built by `make(device:...)`.
  static func encodeStamp(
    _ uniforms: StampUniforms,
    into encoder: MTLRenderCommandEncoder
  ) {
    var uniforms = uniforms
    encoder.setVertexBytes(
      &uniforms,
      length: MemoryLayout<StampUniforms>.stride,
      index: stampUniformsBufferIndex
    )
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<StampUniforms>.stride,
      index: stampUniformsBufferIndex
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
  }
}
