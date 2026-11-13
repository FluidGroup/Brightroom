// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include "ColorAdjustmentWorkingSpace.metalh"
using namespace metal;

namespace {

// The empirical detail calculation uses ROMM primaries with a Display P3 transfer curve.
float3 textureCode(float3 rgb) {
  rgb = clamp(rgb, 0.0f, 1.0f);
  return select(1.055f * pow(rgb, float3(1.0f / 2.4f)) - 0.055f, 12.92f * rgb, rgb <= 0.0031308f);
}
float3 textureLinear(float3 code) {
  return select(pow((code + 0.055f) / 1.055f, float3(2.4f)), code / 12.92f, code <= 0.04045f);
}

// RGB holds gains at codes 0, 0.5 and 1. W is the largest absolute contrast
// change measured on the frequency chart. Regenerate with Texture/calibrate.py.
float4 textureGains(float amount) {
  constexpr float4 minus100(-0.770311697f, -2.462614368f, -0.908639973f, 0.686695065f);
  constexpr float4 minus50(-0.452646881f, -1.512933929f, -0.525873935f, 0.417032942f);
  constexpr float4 plus4(0.032258062f, 0.197307051f, 0.056768647f, 0.051497088f);
  constexpr float4 plus50(0.274888586f, 1.930014698f, 0.449260236f, 0.505952088f);
  constexpr float4 plus100(0.415445309f, 3.004036266f, 0.671227863f, 0.796918890f);
  if (amount < -50.0f) return mix(minus50, minus100, (-amount - 50.0f) / 50.0f);
  if (amount < 0.0f) return minus50 * (-amount / 50.0f);
  if (amount <= 4.0f) return plus4 * (amount / 4.0f);
  if (amount <= 50.0f) return mix(plus4, plus50, (amount - 4.0f) / 46.0f);
  return mix(plus50, plus100, (amount - 50.0f) / 50.0f);
}

} // namespace

extern "C" { namespace coreimage {

  float4 brightroomTextureCode(sample_t source) {
    float3 rgb = brightroom::linearP3ToROMM(unpremultiply(source).rgb);
    return premultiply(float4(textureCode(rgb), source.a));
  }

  float4 brightroomTextureSquare(sample_t guide) {
    float3 code = unpremultiply(guide).rgb;
    return premultiply(float4(code * code, guide.a));
  }

  float4 brightroomTexture(sample_t source, sample_t mean, sample_t secondMoment, float amount) {
    if (source.a <= 0.0f || min(mean.a, secondMoment.a) <= 1e-7f) return source;
    float3 input = unpremultiply(source).rgb;
    float3 romm = clamp(brightroom::linearP3ToROMM(input), 0.0f, 1.0f);
    float3 code = textureCode(romm);
    float3 average = mean.rgb / mean.a;
    float3 deviation = sqrt(max(secondMoment.rgb / secondMoment.a - average * average, 0.0f));
    float4 k = textureGains(amount);
    float3 gain = mix(mix(float3(k.x), float3(k.y), min(2.0f * code, 1.0f)),
                      float3(k.z), max(2.0f * code - 1.0f, 0.0f));
    // Low-contrast patches reach a bounded gain. In particular, negative
    // Texture can soften a narrow stripe without reversing its polarity.
    gain = clamp(gain / (1.0f + 48.0f * deviation), -k.w, k.w);
    float3 target = textureLinear(clamp(code + (code - average) * gain, 0.0f, 1.0f));
    // Carry the source's extended-range offset through the measured SDR change.
    return premultiply(float4(input + brightroom::linearROMMToP3(target - romm), source.a));
  }

}} // extern "C" namespace coreimage
#endif
