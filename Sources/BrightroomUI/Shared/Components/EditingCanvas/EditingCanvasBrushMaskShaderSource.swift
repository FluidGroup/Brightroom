import Metal

/// Metal source used only to rasterize brush stamps into a mask texture.
///
/// Image rendering and filter composition stay in Core Image. This shader draws
/// soft circular alpha stamps for local-adjustment masks.
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
    float distanceFromCenter = length(in.local);
    if (distanceFromCenter > 1.0) {
      return float4(0.0);
    }

    float alpha = 1.0;
    if (brush.hardness < 0.999) {
      float start = clamp(brush.hardness, 0.0, 0.998);
      alpha = 1.0 - smoothstep(start, 1.0, distanceFromCenter);
    }

    alpha *= brush.opacity;
    return float4(alpha, alpha, alpha, alpha);
  }

  """
}
