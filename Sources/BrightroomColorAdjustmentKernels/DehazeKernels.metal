// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include <metal_stdlib>
#include "ColorAdjustmentWorkingSpace.metalh"

using namespace metal;

namespace {
  constant float3 lumaWeights(0.22897457f, 0.69173855f, 0.07928692f);

  // Luminance and chroma responses at each measured XMP setting. Their basis
  // is shared by every input. Local and scene darkness select the response.
  struct Response {
    float4 light;
    float3 lightByLuminance;
    float4 chroma;
    float3 chromaByLuminance;
  };

  constant Response responses[] = {
    // -100
    {float4(0.7731438f, 0.5229033f, 0.7820714f, 0.1788821f), float3(0.4974429f, 0.1684097f, 0.2435823f),
     float4(-0.1548459f, -0.4797386f, -0.5366888f, -0.0406718f), float3(-0.5741438f, -0.0646757f, -0.4241026f)},
    // -50
    {float4(0.3920485f, 0.2396688f, 0.3112127f, 0.1418412f), float3(0.2824177f, 0.1519128f, 0.1597500f),
     float4(-0.1243895f, -0.1048241f, -0.0027228f, -0.0616724f), float3(-0.3134517f, -0.1228240f, -0.2272718f)},
    // +0
    {float4(0.0000000f, 0.0000000f, 0.0000000f, 0.0000000f), float3(0.0000000f, 0.0000000f, 0.0000000f),
     float4(0.0000000f, 0.0000000f, 0.0000000f, 0.0000000f), float3(0.0000000f, 0.0000000f, 0.0000000f)},
    // +9
    {float4(-0.0263659f, -0.0276120f, -0.0041003f, -0.0349869f), float3(-0.0137087f, -0.0303620f, -0.0192138f),
     float4(0.0108669f, 0.0142826f, -0.0031821f, 0.0140021f), float3(0.0159571f, 0.0152383f, 0.0194794f)},
    // +50
    {float4(-0.1490037f, -0.1539911f, -0.0071962f, -0.2197876f), float3(-0.0754922f, -0.1944127f, -0.1131835f),
     float4(0.0693693f, 0.0144243f, -0.0373629f, 0.0644661f), float3(0.0964932f, 0.0853126f, 0.0801391f)},
    // +100
    {float4(-0.2853688f, -0.3024719f, 0.0207184f, -0.4864704f), float3(-0.1543624f, -0.4460050f, -0.2445546f),
     float4(0.0887638f, -0.0264841f, -0.1071323f, 0.0862528f), float3(0.2196828f, 0.1453118f, 0.1602442f)},
  };

  static inline float2 adjustment(int index, float4 guides, float3 byLuminance,
                                  float relativeLumaRoot, float pivotDistance) {
    const Response r = responses[index];
    // The −100 export lifts black. This term fades between −100 and −50.
    float root = relativeLumaRoot + (index == 0 ? 0.16f : 0.0f);
    float falloff = root / (0.35f + root);
    return float2((dot(r.light, guides) + dot(r.lightByLuminance, byLuminance)) * falloff * pivotDistance,
                  max(-1.0f, dot(r.chroma, guides) + dot(r.chromaByLuminance, byLuminance)));
  }
}

extern "C" { namespace coreimage {
  // Pack scalar fields into an opaque image so Core Image filtering preserves
  // the coverage denominator as well as the two alpha-weighted numerators.
  float4 brightroomDehazeGuides(sample_t pixel) {
    float3 rgb = unpremultiply(pixel).rgb;
    float3 romm = brightroom::linearP3ToROMM(rgb);
    float dark = saturate(min(romm.r, min(romm.g, romm.b)));
    float y = saturate(dot(rgb, lumaWeights));
    return float4(dark * pixel.a, y * pixel.a, pixel.a, 1.0f);
  }

  float4 brightroomDehazeDarkChannel(sample_t guide) {
    // Exclude fully transparent pixels from the neighborhood minimum.
    float dark = guide.b > 0.0f ? saturate(guide.r / guide.b) : 1.0f;
    return float4(float3(dark), 1.0f);
  }

  float4 brightroomDehazeNormalize(sample_t blurred) {
    float2 mean = blurred.b > 0.0f ? saturate(blurred.rg / blurred.b) : float2(0.0f);
    return float4(mean, 0.0f, 1.0f);
  }

  float4 brightroomDehazeCoverage(sample_t local, sample_t guide) {
    return float4(local.r * guide.b, guide.b, 0.0f, 1.0f);
  }

  float4 brightroomDehaze(sampler input, sampler local, sampler broad, sampler mean, sampler peak,
                          float3 geometry, float amount, destination dest) {
    float4 source = sample(input, samplerCoord(input));
    float3 rgb = unpremultiply(source).rgb;
    float3 romm = brightroom::linearP3ToROMM(rgb);
    float3 bounded = saturate(romm);
    float3 base = brightroom::linearROMMToP3(bounded);
    float y = dot(base, lumaWeights);
    float2 position = (dest.coord() - geometry.xy) * geometry.z;
    float air = clamp(sample(peak, samplerTransform(peak, float2(0.5f))).g, 1.0f / 255.0f, 1.0f);
    float2 weights = sample(mean, samplerTransform(mean, float2(0.5f))).rg;
    float sceneDark = sqrt(saturate(weights.r / max(0.000001f, weights.g)) / air);
    float nearDark = sqrt(saturate(sample(local, samplerTransform(local, position)).r / air));
    float broadDark = sqrt(saturate(sample(broad, samplerTransform(broad, position)).r / air));
    float root = sqrt(clamp(y / air, 0.0f, 3.0f));
    float4 guides(nearDark, broadDark * sceneDark, sceneDark, nearDark * broadDark);
    float3 byLuminance = float3(sceneDark, nearDark, broadDark * sceneDark) * root;

    constexpr float knots[] = {-100.0f, -50.0f, 0.0f, 9.0f, 50.0f, 100.0f};
    int i = amount <= -50.0f ? 0 : amount <= 0.0f ? 1 : amount <= 9.0f ? 2 : amount <= 50.0f ? 3 : 4;
    float fraction = (amount - knots[i]) / (knots[i + 1] - knots[i]);
    float2 response = mix(adjustment(i, guides, byLuminance, root, air - y),
                          adjustment(i + 1, guides, byLuminance, root, air - y), fraction);
    float3 delta = brightroom::linearP3ToROMM(response.x + response.y * (base - y));
    // Extend the boundary adjustment into HDR while retaining input headroom.
    float3 corrected = rgb + brightroom::linearROMMToP3(saturate(bounded + delta) - bounded);
    return float4(corrected * source.a, source.a);
  }
}}
#endif
