// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include "ColorAdjustmentWorkingSpace.metalh"
using namespace metal;

// lowbias32 from https://github.com/skeeto/hash-prospector (public domain).
static uint grainHash(uint value) {
  value ^= value >> 16;
  value *= 0x7feb352du;
  value ^= value >> 15;
  value *= 0x846ca68bu;
  return value ^ (value >> 16);
}

static float grainUniform(uint value) {
  // The midpoint excludes zero, keeping Box-Muller's logarithm finite.
  return (float(grainHash(value) >> 9) + 0.5f) / 8388608.0f;
}

static float3 grainEncode(float3 value) {
  return select(1.055f * pow(max(value, 0.0f), float3(1.0f / 2.4f)) - 0.055f,
    12.92f * value, value <= 0.0031308f);
}

static float3 grainDecode(float3 value) {
  return select(pow(max((value + 0.055f) / 1.055f, 0.0f), float3(2.4f)),
    value / 12.92f, value <= 0.04045f);
}

extern "C" { namespace coreimage {
  float4 brightroomGrainNoise(float2 seedWords, destination dest) {
    const int2 pixel = int2(floor(dest.coord()));
    const uint seed = uint(seedWords.x) | (uint(seedWords.y) << 16);
    const uint key = grainHash(uint(pixel.x)) ^ grainHash(uint(pixel.y) + 0x9e3779b9u) ^ seed;
    const float magnitude = sqrt(-2.0f * log(grainUniform(key)));
    const float angle = 6.28318530718f * grainUniform(key ^ 0x68bc21ebu);
    // Independent normal fields: fine texture and its coarse strength envelope.
    return float4(magnitude * cos(angle), magnitude * sin(angle), 0.0f, 1.0f);
  }

  float4 brightroomGrain(sampler inputImage, sampler fine, sampler coarse,
    float amount, float roughness) {
    const float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0f) return source;
    const float3 encoded = grainEncode(unpremultiply(source).rgb);
    const float luminance = clamp(dot(encoded, float3(0.228974564f, 0.691738522f, 0.079286914f)), 0.0f, 1.0f);
    const float tonalWeight = 2.0f * sqrt(luminance * (1.0f - luminance));
    const float texture = sample(fine, samplerCoord(fine)).r;
    const float unevenness = sample(coarse, samplerCoord(coarse)).g;
    const float strength = max(0.15f, 1.0f + 0.65f * roughness * unevenness);
    const float delta = 0.06f * amount * tonalWeight * texture * strength;
    return premultiply(float4(grainDecode(encoded + delta), source.a));
  }

  float4 brightroomGrainEncodeROMM(sample_t source) {
    const float3 p3 = unpremultiply(source).rgb;
    const float3 romm = brightroom::linearP3ToROMM(p3);
    return premultiply(float4(grainEncode(romm), source.a));
  }

  float4 brightroomGrainShape(sample_t noise, float normalization, float exponent, float gain) {
    const float n = noise.r * normalization;
    return float4(gain * copysign(pow(abs(n), exponent), n), 0.0f, 0.0f, 1.0f);
  }

  float4 brightroomGrainBlendROMM(sample_t original, sample_t softened, sample_t texture) {
    if (original.a <= 0.0f) return original;
    const float3 encoded = unpremultiply(softened).rgb;
    const float3 bounded = clamp(encoded, 0.0f, 1.0f);
    // Plateau across the midrange, with a per-channel taper at black and white.
    const float3 weight = min(1.0f, 20.0f * min(bounded, 1.0f - bounded));
    const float3 diff = clamp(bounded + texture.r * weight, 0.0f, 1.0f) - bounded;
    const float3 romm = grainDecode(encoded + diff);
    const float3 p3 = brightroom::linearROMMToP3(romm);
    return premultiply(float4(p3, original.a));
  }
}}
#endif
