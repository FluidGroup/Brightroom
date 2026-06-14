import Metal

/// Metal render source for the **in-flight (active)** brush stroke, rasterized
/// into a mask texture for low-latency live painting feedback. This render
/// pipeline exists because re-rasterizing a growing active stroke
/// (hundreds–thousands of stamps) through the parametric `brushStamp` CIKernel
/// every frame would not hold frame rate.
///
/// The falloff is NOT duplicated here: `brushStampFragment` calls the shared
/// `brushStampAlpha` (`BrushStampSharedSource.falloffFunctionMSL`), which
/// `makeBrushMaskShaderLibrary` prepends to this source — the exact same
/// function the parametric `brushStamp` kernel uses. Stamp accumulation uses a
/// `.max` blend (`makeBrushMaskPipeline`), mirroring the kernel's
/// `CIBlendKernel.componentMax`. So the live stroke and the committed/export
/// mask converge by construction.
enum EditingCanvasBrushMaskShaderSource {
  static let source = """
  #include <metal_stdlib>
  using namespace metal;

  struct BrushStampUniforms {
    float2 canvasSize;
    float2 center;
    float radius;
    float hardness;
    float opacity;
    float padding;
  };

  struct BrushStampVertexOut {
    float4 position [[position]];
    float2 local;
  };

  vertex BrushStampVertexOut brushStampVertex(
    uint vertexID [[vertex_id]],
    constant BrushStampUniforms& brush [[buffer(0)]]
  ) {
    constexpr float2 corners[4] = {
      float2(-1.0, -1.0),
      float2( 1.0, -1.0),
      float2(-1.0,  1.0),
      float2( 1.0,  1.0)
    };

    float2 local = corners[vertexID];
    float2 pixel = brush.center + local * brush.radius;
    float2 position = float2(
      pixel.x / brush.canvasSize.x * 2.0 - 1.0,
      1.0 - pixel.y / brush.canvasSize.y * 2.0
    );

    BrushStampVertexOut out;
    out.position = float4(position, 0.0, 1.0);
    out.local = local;
    return out;
  }

  fragment float4 brushStampFragment(
    BrushStampVertexOut in [[stage_in]],
    constant BrushStampUniforms& brush [[buffer(0)]]
  ) {
    // `in.local` is the [-1, 1] quad coordinate, so its length is already the
    // normalized distance the shared falloff expects.
    float normalizedDistance = length(in.local);
    float alpha = brushStampAlpha(normalizedDistance, brush.hardness, brush.opacity);
    return float4(alpha, alpha, alpha, alpha);
  }

  """
}
