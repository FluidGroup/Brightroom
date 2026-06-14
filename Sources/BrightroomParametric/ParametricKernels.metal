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
// This `brushStamp` kernel is one of the brush-mask rasterizers; the live
// in-flight-stroke render shader (EditingCanvasBrushMaskShaderSource) is the
// other. Both now share ONE falloff — `brushStampAlpha`, defined in
// `BrushStampSharedSource.falloffFunctionMSL` and prepended to this source at
// runtime by `ParametricKernelRegistry` — so the falloff cannot drift.
//
// `brushStampAlpha` is injected, NOT defined here. If this file is ever switched
// from a `.copy` resource to build-time metallib compilation, inline the shared
// function (or the build will fail on the undefined symbol).

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
    if (radius <= 0.0) {
      return float4(0.0);
    }

    float normalizedDistance = length(dest.coord() - center) / radius;
    float alpha = brushStampAlpha(normalizedDistance, hardness, opacity);
    return float4(alpha, alpha, alpha, alpha);
  }

  [[ stitchable ]] float4 maskSubtract(sample_t removing, sample_t base) {
    float alpha = max(base.a - removing.a, 0.0);
    return float4(alpha, alpha, alpha, alpha);
  }
}}
