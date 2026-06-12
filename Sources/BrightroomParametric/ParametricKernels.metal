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

// Core Image kernels used by the parametric feature graph compiler.
//
// This file ships as a bundle resource and is compiled at runtime through
// `CIKernel.kernels(withMetalString:)`. SwiftPM cannot pass the Metal linker
// flags `[[stitchable]]` kernels need for build-time metallib compilation
// (`-framework CoreImage`); when the build pipeline gains that capability the
// loader can switch to `CIColorKernel(functionName:fromMetalLibraryData:)`
// without touching this source.
//
// The brushStamp falloff is a shared contract:
//   alpha = (1 - smoothstep(hardness, 1, normalizedDistance)) * opacity
// It must stay in sync with the interactive Metal brush
// (EditingCanvasBrushMaskShaderSource) and the CPU raster
// (LocalAdjustmentRendering.makeSoftStampGradient).

#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" { namespace coreimage {
  [[ stitchable ]] float4 brushStamp(
    float2 center,
    float radius,
    float hardness,
    float opacity,
    destination dest
  ) {
    if (radius <= 0.0 || opacity <= 0.0) {
      return float4(0.0);
    }

    float distanceFromCenter = length(dest.coord() - center);
    if (distanceFromCenter > radius) {
      return float4(0.0);
    }

    float normalizedDistance = distanceFromCenter / radius;
    float alpha = 1.0;
    if (hardness < 0.999) {
      float start = clamp(hardness, 0.0, 0.998);
      alpha = 1.0 - smoothstep(start, 1.0, normalizedDistance);
    }

    alpha *= clamp(opacity, 0.0, 1.0);
    return float4(alpha, alpha, alpha, alpha);
  }

  [[ stitchable ]] float4 maskSubtract(sample_t removing, sample_t base) {
    float alpha = max(base.a - removing.a, 0.0);
    return float4(alpha, alpha, alpha, alpha);
  }
}}
