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

import Foundation

/// The single source of truth for the brush-stamp falloff, shared by every brush
/// rasterizer so they cannot drift.
///
/// Both rasterizers are runtime-compiled Metal Shading Language strings — the
/// parametric `brushStamp` CIKernel (`ParametricKernels.metal`, via
/// `CIKernel.kernels(withMetalString:)`) and the BrightroomUI live render shader
/// (`EditingCanvasBrushMaskShaderSource`, via `device.makeLibrary(source:)`).
/// Each prepends `falloffFunctionMSL` to its source, so the falloff exists in
/// exactly one place. The function takes a NORMALIZED distance (0 at the stamp
/// center, 1 at the radius edge); the CIKernel normalizes by `distance / radius`,
/// the render shader by the `[-1, 1]` quad-local coordinate.
public enum BrushStampSharedSource {

  /// Pure MSL (self-contained, prependable to any source): the brush falloff
  /// `alpha = (1 - smoothstep(hardness, 1, normalizedDistance)) * opacity`.
  public static let falloffFunctionMSL = """
  #include <metal_stdlib>
  using namespace metal;

  // Shared brush falloff — the single rasterizer of record. Do not duplicate;
  // both the parametric CIKernel and the live render shader prepend this.
  float brushStampAlpha(float normalizedDistance, float hardness, float opacity) {
    if (normalizedDistance > 1.0) {
      return 0.0;
    }
    float alpha = 1.0;
    if (hardness < 0.999) {
      float start = clamp(hardness, 0.0, 0.998);
      alpha = 1.0 - smoothstep(start, 1.0, normalizedDistance);
    }
    return alpha * clamp(opacity, 0.0, 1.0);
  }
  """
}
