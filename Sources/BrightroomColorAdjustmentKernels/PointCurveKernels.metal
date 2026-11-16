// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include "ColorAdjustmentWorkingSpace.metalh"
using namespace metal;

static float3 pointCurveEncode(float3 value) {
  return select(1.055f * pow(max(value, 0.0f), float3(1.0f / 2.4f)) - 0.055f,
    12.92f * value, value <= 0.0031308f);
}

static float3 pointCurveDecode(float3 value) {
  return select(pow(max((value + 0.055f) / 1.055f, 0.0f), float3(2.4f)),
    value / 12.92f, value <= 0.04045f);
}

static float pointCurveSample(coreimage::sampler table, float value, float channel) {
  const float base = channel >= 2.0f ? 4096.0f : 0.0f;
  const float2 pair = coreimage::sample(table, coreimage::samplerTransform(table,
    float2(base + clamp(value, 0.0f, 1.0f) * 4095.0f + 0.5f, 0.5f))).rg;
  return clamp(value, 0.0f, 1.0f) + (channel == 0.0f || channel == 2.0f ? pair.r : pair.g);
}

// Fit a line to the master curve in encoded ROMM. The middle channel
// determines how far to move the two samples inward from the RGB extrema.
static float3 pointCurveMaster(coreimage::sampler table, float3 rgb, float refine) {
  const float low = min(rgb.r, min(rgb.g, rgb.b));
  const float high = max(rgb.r, max(rgb.g, rgb.b));
  const float span = high - low;
  if (span <= 1e-7f) return float3(pointCurveSample(table, low, 0.0f));

  const float3 position = (rgb - low) / span;
  const float middle = clamp(position.b, min(position.r, position.g), max(position.r, position.g));
  const float inset = 0.5f * middle * (1.0f - middle);
  const float lowerInset = inset * (1.0f - middle);
  const float upperInset = inset * middle;
  const float lowerSample = pointCurveSample(table, low + span * lowerInset, 0.0f);
  const float upperSample = pointCurveSample(table, high - span * upperInset, 0.0f);
  const float slope = (upperSample - lowerSample) / (1.0f - inset);

  // Bound the ends before restoring the middle channel. This retains its
  // relative position even when a saturated color reaches black or white.
  const float mappedLow = saturate(lowerSample - lowerInset * slope);
  const float mappedHigh = saturate(upperSample + upperInset * slope);
  const float3 full = mix(mappedLow, mappedHigh, position);
  if (refine >= 1.0f) return full;

  // At zero refinement the encoded RGB differences are retained around
  // the luma of the individually mapped channels, within the SDR gamut.
  const float3 weights = float3(0.30f, 0.59f, 0.11f);
  const float inputLuma = dot(rgb, weights);
  const float targetLuma = saturate(dot(float3(pointCurveSample(table, rgb.r, 0.0f),
    pointCurveSample(table, rgb.g, 0.0f), pointCurveSample(table, rgb.b, 0.0f)), weights));
  float chromaScale = 1.0f;
  if (targetLuma < inputLuma - low) chromaScale = targetLuma / (inputLuma - low);
  else if (1.0f - targetLuma < high - inputLuma) chromaScale = (1.0f - targetLuma) / (high - inputLuma);
  const float3 retained = targetLuma + (rgb - inputLuma) * chromaScale;
  return mix(retained, full, refine);
}

extern "C" { namespace coreimage {
  float4 brightroomPointCurve(sampler inputImage, sampler table, float hasMaster, float refine) {
    const float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0f) return source;
    const float3 p3 = unpremultiply(source).rgb;
    const float3 linear = brightroom::linearP3ToROMM(p3);
    const float3 bounded = clamp(linear, 0.0f, 1.0f);
    float3 rgb = pointCurveEncode(bounded);
    if (hasMaster != 0.0f) rgb = pointCurveMaster(table, rgb, refine);
    rgb = float3(pointCurveSample(table, rgb.r, 1.0f),
      pointCurveSample(table, rgb.g, 2.0f), pointCurveSample(table, rgb.b, 3.0f));
    rgb = pointCurveDecode(rgb) + linear - bounded;
    const float3 result = brightroom::linearROMMToP3(rgb);
    return premultiply(float4(result, source.a));
  }
}}
#endif
