//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

// Scene-linear YRGB Tone Curve in extended-linear Display-P3.
//
// The first half of curveTable stores normalized Y/Red outputs in RG; the
// second half stores Green/Blue. The table includes flat plateaus between moved
// endpoints and normalized Input 0...1. Inputs beyond that domain continue from
// the table boundary with an effective derivative: zero for a moved endpoint,
// or its spline tangent when it remains at normalized Input 0 or 1.

// SwiftPM also runs its ordinary Metal resource pass. Only the plugin (or a
// host target configured with -fcikernel) emits these general Core Image kernels.
#if defined(__METAL_CIKERNEL__)

#include <CoreImage/CoreImage.h>
using namespace metal;

static float toneCurveLinearToNormalized(float linear) {
  constexpr float shift = -0.000157849851665374;
  constexpr float linearBreak = 0.0041318374739483946;
  constexpr float linearToeGain = 363.034608563;

  float stop;
  if (linear < linearBreak) {
    stop = linear * linearToeGain - 7.0;
  } else {
    stop = log2((linear + shift) / (0.18 + shift));
  }
  return (stop + 7.0) / 14.0;
}

static float toneCurveNormalizedToLinear(float normalized) {
  constexpr float shift = -0.000157849851665374;
  constexpr float linearToeGain = 363.034608563;

  const float stop = normalized * 14.0 - 7.0;
  if (stop < -5.5) {
    return (stop + 7.0) / linearToeGain;
  }
  return exp2(stop) * (0.18 + shift) - shift;
}

static float toneCurveNormalizedOutput(
  coreimage::sampler curveTable,
  float normalizedInput,
  float tableBase,
  float tableComponent,
  float lowerOutput,
  float upperOutput,
  float lowerTangent,
  float upperTangent
) {
  if (normalizedInput < 0.0) {
    return lowerOutput + lowerTangent * normalizedInput;
  }
  if (normalizedInput > 1.0) {
    return upperOutput + upperTangent * (normalizedInput - 1.0);
  }

  const float x = tableBase + 0.5 + normalizedInput * 4095.0;
  // Use Core Image's free-function sampler ABI. The equivalent member wrappers
  // have returned transparent black in physical-device Metal builds.
  const float2 sampled = coreimage::sample(
    curveTable,
    coreimage::samplerTransform(curveTable, float2(x, 0.5))
  ).rg;
  return mix(sampled.x, sampled.y, tableComponent);
}

static float toneCurveApply(
  float linear,
  coreimage::sampler curveTable,
  float tableBase,
  float tableComponent,
  float lowerOutput,
  float upperOutput,
  float lowerTangent,
  float upperTangent
) {
  const float normalizedInput = toneCurveLinearToNormalized(linear);
  const float normalizedOutput = toneCurveNormalizedOutput(
    curveTable,
    normalizedInput,
    tableBase,
    tableComponent,
    lowerOutput,
    upperOutput,
    lowerTangent,
    upperTangent
  );
  return toneCurveNormalizedToLinear(normalizedOutput);
}

extern "C" { namespace coreimage {

  /// Preserves original Display-P3 luminance through RGB curves, then applies Y.
  float4 brightroomToneCurve(
    sampler inputImage,
    sampler curveTable,
    float4 lowerOutputs,
    float4 upperOutputs,
    float4 lowerTangents,
    float4 upperTangents,
    float4 activeChannels
  ) {
    const float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0) {
      return source;
    }

    float4 straight = unpremultiply(source);
    constexpr float3 displayP3Luminance = float3(
      0.2289745641,
      0.6917385218,
      0.0792869141
    );
    const float inputY = dot(straight.rgb, displayP3Luminance);

    if (activeChannels.y > 0.5) {
      straight.r = toneCurveApply(
        straight.r,
        curveTable,
        0.0,
        1.0,
        lowerOutputs.y,
        upperOutputs.y,
        lowerTangents.y,
        upperTangents.y
      );
    }
    if (activeChannels.z > 0.5) {
      straight.g = toneCurveApply(
        straight.g,
        curveTable,
        4096.0,
        0.0,
        lowerOutputs.z,
        upperOutputs.z,
        lowerTangents.z,
        upperTangents.z
      );
    }
    if (activeChannels.w > 0.5) {
      straight.b = toneCurveApply(
        straight.b,
        curveTable,
        4096.0,
        1.0,
        lowerOutputs.w,
        upperOutputs.w,
        lowerTangents.w,
        upperTangents.w
      );
    }

    const float curvedY = dot(straight.rgb, displayP3Luminance);
    float outputY = inputY;
    if (activeChannels.x > 0.5) {
      outputY = toneCurveApply(
        inputY,
        curveTable,
        0.0,
        0.0,
        lowerOutputs.x,
        upperOutputs.x,
        lowerTangents.x,
        upperTangents.x
      );
    }
    straight.rgb += outputY - curvedY;

    return premultiply(straight);
  }

}}

#endif // __METAL_CIKERNEL__
