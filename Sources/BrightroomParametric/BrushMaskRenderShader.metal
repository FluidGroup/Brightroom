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

// The brush-mask rasterizer. The live editing canvas (its viewport mask texture)
// and the parametric export (a Core Image processor tile) both draw stamps with
// these functions through `BrushStampPipeline`, so preview and export share the
// shader, the `.max` accumulation, and the stamp encoding.
//
// Each instance is one soft circular stamp. `center` and `radius` are in target
// pixels with row 0 at the first texture row. The vertex function expands the
// stamp's bounding square, so only pixels the stamp can touch are shaded.

#include "BrushStampFalloff.metalh"

struct BrushStampInstance {
  float2 center;
  float radius;
  float hardness;
  float opacity;
  float padding;
};

struct BrushStampVertexOut {
  float4 position [[position]];
  float2 local;
  float hardness [[flat]];
  float opacity [[flat]];
};

vertex BrushStampVertexOut brushStampVertex(
  uint vertexID [[vertex_id]],
  uint instanceID [[instance_id]],
  constant BrushStampInstance* stamps [[buffer(0)]],
  constant float2& targetSize [[buffer(1)]]
) {
  constexpr float2 corners[4] = {
    float2(-1.0, -1.0),
    float2( 1.0, -1.0),
    float2(-1.0,  1.0),
    float2( 1.0,  1.0)
  };

  BrushStampInstance stamp = stamps[instanceID];
  float2 local = corners[vertexID];
  float2 pixel = stamp.center + local * stamp.radius;
  float2 position = float2(
    pixel.x / targetSize.x * 2.0 - 1.0,
    1.0 - pixel.y / targetSize.y * 2.0
  );

  BrushStampVertexOut out;
  out.position = float4(position, 0.0, 1.0);
  out.local = local;
  out.hardness = stamp.hardness;
  out.opacity = stamp.opacity;
  return out;
}

fragment float4 brushStampFragment(BrushStampVertexOut in [[stage_in]]) {
  // `in.local` is the [-1, 1] quad coordinate, so its length is already the
  // normalized distance the shared falloff expects.
  float normalizedDistance = length(in.local);
  float alpha = brushStampAlpha(normalizedDistance, in.hardness, in.opacity);
  return float4(alpha, alpha, alpha, alpha);
}
