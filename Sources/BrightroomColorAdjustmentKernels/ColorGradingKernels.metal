// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include "ColorAdjustmentWorkingSpace.metalh"
using namespace metal;

static float gradingChannel(float value, coreimage::sampler table, float base) {
  const float x = clamp(value, 0.0f, 1.0f);
  const float shaped = x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
  const float output = coreimage::sample(table,
    coreimage::samplerTransform(table, float2(base + 0.5f + shaped * 2048.0f, 0.5f))).r;
  // The calibration covers SDR. Preserve extended headroom with unit-slope
  // continuation at each boundary, rather than extrapolating a rational pole.
  return output + value - x;
}

extern "C" { namespace coreimage {
  float4 brightroomColorGrading(sampler inputImage, sampler curveTable,
    float hasLocalCorrection, float3 globalTint, float globalLuminance) {
    const float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0f) return source;
    const float3 p3 = unpremultiply(source).rgb;
    float3 rgb = brightroom::linearP3ToROMM(p3);
    if (hasLocalCorrection != 0.0f) {
      rgb = float3(gradingChannel(rgb.r, curveTable, 0.0f),
        gradingChannel(rgb.g, curveTable, 2049.0f),
        gradingChannel(rgb.b, curveTable, 4098.0f));
    }
    // Global saturation and luminance are sequential rational transforms.
    // Evaluate them analytically to avoid a sampled-curve precision floor.
    float3 bounded = clamp(rgb, 0.0f, 1.0f);
    rgb = bounded * (1.0f + globalTint) / (1.0f + globalTint * (2.0f * bounded - 1.0f)) + rgb - bounded;
    bounded = clamp(rgb, 0.0f, 1.0f);
    rgb = bounded * (1.0f + globalLuminance) / (1.0f + globalLuminance * (2.0f * bounded - 1.0f)) + rgb - bounded;
    const float3 result = brightroom::linearROMMToP3(rgb);
    return premultiply(float4(result, source.a));
  }
}}
#endif
