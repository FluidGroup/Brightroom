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
// This file is build-compiled into the package target's `default.metallib` and
// loaded with `CIColorKernel(functionName:fromMetalLibraryData:)`.
//
// Brush stamps are not a Core Image kernel: `BrushMaskImageProcessor` draws them
// with the render shader in `BrushMaskRenderShader.metal`, the same one the live
// canvas uses.

#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {
  [[ stitchable ]] float4 maskSubtract(sample_t removing, sample_t base) {
    float alpha = max(base.a - removing.a, 0.0);
    return float4(alpha, alpha, alpha, alpha);
  }
}}
