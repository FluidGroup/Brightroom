#include <metal_stdlib>
using namespace metal;

struct BrushUniforms {
  float2 canvasSize;
  float2 center;
  float radius;
  float hardness;
  float opacity;
  float padding;
};

struct LiveOverlayUniforms {
  float2 viewportOrigin;
  float2 viewportSize;
  float2 drawableSize;
};

struct BrushVertexOut {
  float4 position [[position]];
  float2 local;
};

struct DisplayVertexOut {
  float4 position [[position]];
  float2 uv;
};

vertex BrushVertexOut brushVertex(
  uint vertexID [[vertex_id]],
  constant BrushUniforms& brush [[buffer(0)]]
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

  BrushVertexOut out;
  out.position = float4(position, 0.0, 1.0);
  out.local = local;
  return out;
}

fragment float4 brushFragment(
  BrushVertexOut in [[stage_in]],
  constant BrushUniforms& brush [[buffer(0)]]
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

vertex DisplayVertexOut displayVertex(uint vertexID [[vertex_id]]) {
  constexpr float2 positions[4] = {
    float2(-1.0, -1.0),
    float2( 1.0, -1.0),
    float2(-1.0,  1.0),
    float2( 1.0,  1.0)
  };
  constexpr float2 uvs[4] = {
    float2(0.0, 1.0),
    float2(1.0, 1.0),
    float2(0.0, 0.0),
    float2(1.0, 0.0)
  };

  DisplayVertexOut out;
  out.position = float4(positions[vertexID], 0.0, 1.0);
  out.uv = uvs[vertexID];
  return out;
}

fragment float4 liveOverlayFragment(
  DisplayVertexOut in [[stage_in]],
  constant LiveOverlayUniforms& overlay [[buffer(0)]],
  texture2d<float> liveStrokeTexture [[texture(0)]],
  texture2d<float> adjustedImageTexture [[texture(1)]]
) {
  constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

  float liveAlpha = clamp(liveStrokeTexture.sample(textureSampler, in.uv).a, 0.0, 1.0);
  float2 drawablePixel = in.uv * overlay.drawableSize;
  float2 viewportSize = max(overlay.viewportSize, float2(1.0));
  float2 viewportPosition = (drawablePixel - overlay.viewportOrigin) / viewportSize;
  if (any(viewportPosition < float2(0.0)) || any(viewportPosition > float2(1.0))) {
    return float4(0.0);
  }
  float3 adjustedColor = adjustedImageTexture.sample(textureSampler, viewportPosition).rgb;

  return float4(adjustedColor * liveAlpha, liveAlpha);
}
