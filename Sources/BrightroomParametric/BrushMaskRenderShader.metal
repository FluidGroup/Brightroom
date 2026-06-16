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

// Metal render source for the in-flight brush stroke, rasterized into a mask
// texture for low-latency live painting feedback. This source and the Core Image
// brush-stamp kernel share brushStampAlpha from BrushStampFalloff.metalh.

#include "BrushStampFalloff.metalh"

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
