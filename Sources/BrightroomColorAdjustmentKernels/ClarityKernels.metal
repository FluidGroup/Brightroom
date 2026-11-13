// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include "ColorAdjustmentWorkingSpace.metalh"

using namespace metal;

namespace {

constant float3 luminanceWeights = float3(0.22897457f, 0.69173855f, 0.07928692f);

float encodeLuminance(float y) {
  return y <= 0.0031308f ? 12.92f * y : 1.055f * pow(y, 1.0f / 2.4f) - 0.055f;
}

float decodeLuminance(float code) {
  return code <= 0.04045f ? code / 12.92f : pow((code + 0.055f) / 1.055f, 2.4f);
}

// Gains at five luminances for the encoded brightness shift, and three for
// the change in chroma about the input luminance. Fit with Clarity/calibrate.py.
struct ClarityGains {
  float4 light[5];  // Detail, mean absolute detail, detail × saturation, mean signed detail.
  float2 color[3];  // Signed detail and mean absolute detail.
};

constant ClarityGains gains[] = {
  { // -100
    {
      float4(0.014948213f, -0.053152559f, 0.019993121f, 0.004815099f),
      float4(-0.195200501f, 0.094810379f, -0.035193803f, -0.103504898f),
      float4(-0.522004783f, 0.235233414f, -0.104213397f, -0.205532813f),
      float4(-0.512681871f, 0.018447548f, -0.103567425f, -0.296584579f),
      float4(-0.156875082f, -0.071207323f, -0.040021826f, -0.037386705f)
    },
    {
      float2(-0.198235750f, 0.078987265f),
      float2(-1.609219660f, 0.409370565f),
      float2(-0.353006516f, 0.275880221f)
    }
  },
  { // -50
    {
      float4(0.008909839f, -0.031399919f, 0.011947199f, 0.002815293f),
      float4(-0.115944155f, 0.055224717f, -0.021758072f, -0.061298611f),
      float4(-0.314227957f, 0.148170951f, -0.060191182f, -0.121331516f),
      float4(-0.283898167f, 0.010438603f, -0.052660057f, -0.169552932f),
      float4(-0.077555906f, -0.036437933f, -0.019560241f, -0.020997137f)
    },
    {
      float2(-0.121364176f, 0.041642552f),
      float2(-0.946999943f, 0.276847969f),
      float2(-0.152110350f, 0.220584673f)
    }
  },
  { // 4
    {
      float4(0.001994306f, -0.006130419f, 0.001022838f, 0.000000000f),
      float4(0.028709022f, 0.003942180f, 0.004805005f, 0.000000000f),
      float4(0.033765942f, -0.006268904f, 0.004771333f, 0.000000000f),
      float4(0.020602331f, -0.025921395f, 0.003302867f, 0.000000000f),
      float4(0.003971467f, 0.000288350f, 0.001010997f, 0.000000000f)
    },
    {
      float2(0.041331088f, -0.022731830f),
      float2(0.088152095f, -0.036797871f),
      float2(-0.011295982f, -0.030376234f)
    }
  },
  { // 50
    {
      float4(-0.003791309f, -0.074081461f, 0.005479339f, 0.000000000f),
      float4(0.330692378f, 0.055541219f, 0.075567425f, 0.000000000f),
      float4(0.426886101f, -0.091752728f, 0.056081897f, 0.000000000f),
      float4(0.253001580f, -0.326295315f, 0.039550173f, 0.000000000f),
      float4(0.038449043f, -0.000470412f, 0.009084788f, 0.000000000f)
    },
    {
      float2(0.460910206f, -0.259134620f),
      float2(1.012875653f, -0.490485215f),
      float2(-0.144141559f, -0.434672635f)
    }
  },
  { // 100
    {
      float4(-0.034085487f, -0.140504695f, 0.001306550f, 0.000000000f),
      float4(0.612022572f, 0.139508174f, 0.164054891f, 0.000000000f),
      float4(0.825977935f, -0.197954260f, 0.117009106f, 0.000000000f),
      float4(0.481960845f, -0.645527854f, 0.073809917f, 0.000000000f),
      float4(0.051451328f, -0.009504589f, 0.008827614f, 0.000000000f)
    },
    {
      float2(0.818955757f, -0.439397652f),
      float2(1.772754687f, -1.011017434f),
      float2(-0.229308876f, -0.968565334f)
    }
  }
};

float2 adjustment(int level, float4 detail, float code) {
  float lightPosition = 4.0f * code;
  float colorPosition = 2.0f * code;
  int i = min(int(lightPosition), 3), j = min(int(colorPosition), 1);
  float4 light = mix(gains[level].light[i], gains[level].light[i + 1], lightPosition - float(i));
  float2 color = mix(gains[level].color[j], gains[level].color[j + 1], colorPosition - float(j));
  return float2(dot(light, detail), dot(color, detail.xy));
}

// Interpolate through neutral and the two measured strengths on each side.
// Positive Clarity also has a measured +4 endpoint used by the A10 preset.
float2 signedAdjustment(float amount, float4 detail, float code) {
  if (amount < -50.0f) {
    return mix(adjustment(1, detail, code), adjustment(0, detail, code), (-amount - 50.0f) / 50.0f);
  }
  if (amount < 0.0f) return adjustment(1, detail, code) * (-amount / 50.0f);
  if (amount <= 4.0f) return adjustment(2, detail, code) * (amount / 4.0f);
  if (amount < 50.0f) {
    return mix(adjustment(2, detail, code), adjustment(3, detail, code), (amount - 4.0f) / 46.0f);
  }
  return mix(adjustment(3, detail, code), adjustment(4, detail, code), (amount - 50.0f) / 50.0f);
}

} // namespace

extern "C" { namespace coreimage {

  float4 brightroomClarityLuminance(sample_t pixel) {
    float3 rgb = clamp(unpremultiply(pixel).rgb, 0.0f, 1.0f);
    float code = encodeLuminance(dot(rgb, luminanceWeights));
    return float4(float3(code), 1.0f) * pixel.a;
  }

  float4 brightroomClarityDeviation(sample_t value, sample_t mean) {
    if (value.a <= 0.0f || mean.a <= 1e-7f) return float4(0.0f);
    float difference = value.r / value.a - mean.r / mean.a;
    // Store two nonnegative quantities so an integer working format can
    // carry the sign through the blur: mean(d) = 2 × mean(max(d, 0)) − mean(|d|).
    return float4(abs(difference), max(difference, 0.0f), 0.0f, 1.0f) * value.a;
  }

  float4 brightroomClarity(sampler image, sampler mean, sampler energy,
    float3 geometry, float amount, destination dest) {
    float4 pixel = sample(image, samplerCoord(image));
    if (pixel.a <= 0.0f) return pixel;
    float3 original = unpremultiply(pixel).rgb;
    float3 rgb = clamp(original, 0.0f, 1.0f);
    float y = dot(rgb, luminanceWeights);
    float code = clamp(encodeLuminance(y), 0.0f, 1.0f);
    float2 p = (dest.coord() - geometry.xy) * geometry.z;
    float4 neighborhood = sample(mean, samplerTransform(mean, p));
    float difference = neighborhood.a > 1e-7f ? code - neighborhood.r / neighborhood.a : 0.0f;
    float4 averaged = sample(energy, samplerTransform(energy, p));
    float2 local = averaged.a > 1e-7f ? averaged.rg / averaged.a : float2(0.0f);
    float contrast = max(0.0f, local.x);
    float3 romm = brightroom::linearP3ToROMM(rgb);
    float low = min(romm.r, min(romm.g, romm.b)), high = max(romm.r, max(romm.g, romm.b));
    float saturation = (high - low) / (high + 0.05f);
    float meanDifference = 2.0f * local.y - contrast;
    float2 delta = signedAdjustment(amount, float4(difference, contrast, difference * saturation, meanDifference), code);
    float target = decodeLuminance(clamp(code + delta.x, 0.0f, 1.0f));
    // Bound the change along the input hue line in ProPhoto RGB. Keep the
    // source's existing extended-range offset when applying the measured SDR delta.
    float lowerLimit = (target - min(low, 0.0f)) / max(y - low, 1e-7f);
    float upperLimit = (max(high, 1.0f) - target) / max(high - y, 1e-7f);
    float gain = max(0.0f, min(1.0f + delta.y, min(lowerLimit, upperLimit)));
    return premultiply(float4(original - rgb + target + (rgb - y) * gain, pixel.a));
  }

}} // extern "C" namespace coreimage
#endif
