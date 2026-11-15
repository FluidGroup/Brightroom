#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" { namespace coreimage {

  float4 brightroomStandardTonalPoint(sample_t source, float whites, float blacks) {
    if (source.a <= 0.0f) return source;
    const float3 rgb = unpremultiply(source).rgb;
    const float t = clamp(dot(rgb, float3(0.228974564f, 0.691738522f, 0.079286914f)), 0.0f, 1.0f);
    const float gain = exp2(whites * t * t);
    const float lift = 0.25f * blacks * (1.0f - t) * (1.0f - t);
    return premultiply(float4(rgb * gain + lift, source.a));
  }

  float4 brightroomStandardColorGrading(sample_t source, float4 shadows, float4 midtones,
    float4 highlights, float4 global, float blending, float balance) {
    if (source.a <= 0.0f) return source;
    const float3 rgb = unpremultiply(source).rgb;
    const float tone = clamp(dot(rgb, float3(0.228974564f, 0.691738522f, 0.079286914f)), 0.0f, 1.0f);
    const float t = clamp(tone + 0.25f * balance, 0.0f, 1.0f);
    float3 weights = float3(
      1.0f - smoothstep(0.0f, 0.5f + 0.5f * blending, t),
      4.0f * t * (1.0f - t),
      smoothstep(0.5f - 0.5f * blending, 1.0f, t));
    weights /= max(dot(weights, float3(1.0f)), 1e-6f);
    const float4 correction = shadows * weights.x + midtones * weights.y + highlights * weights.z + global;
    return premultiply(float4(rgb * exp2(correction.w) + correction.xyz * (4.0f * tone * (1.0f - tone)), source.a));
  }

  float4 brightroomStandardDetail(sample_t source, sample_t neighborhood, float amount) {
    if (source.a <= 0.0f) return source;
    const float3 rgb = unpremultiply(source).rgb;
    const float3 guide = unpremultiply(neighborhood).rgb;
    return premultiply(float4(rgb + amount * (rgb - guide), source.a));
  }

}}
#endif
