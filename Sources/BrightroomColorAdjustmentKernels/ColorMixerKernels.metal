//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

// Perceptual Color Mixer for unpremultiplied extended-linear Display-P3.
// SwiftPM also runs its ordinary Metal resource pass. Only the plugin (or a
// host target configured with -fcikernel) emits these general Core Image kernels.
#if defined(__METAL_CIKERNEL__)

#include <CoreImage/CoreImage.h>
using namespace metal;

static float cmCbrt(float value) {
  return copysign(pow(abs(value), 1.0 / 3.0), value);
}

static float3 cmP3ToXYZ(float3 rgb) {
  return float3(
    dot(float3(0.4865709486, 0.2656676932, 0.1982172852), rgb),
    dot(float3(0.2289745641, 0.6917385218, 0.0792869141), rgb),
    dot(float3(0.0, 0.04511338186, 1.043944369), rgb)
  );
}

static float3 cmXYZToP3(float3 xyz) {
  return float3(
    dot(float3(2.493496912, -0.9313836179, -0.4027107845), xyz),
    dot(float3(-0.8294889696, 1.76266406, 0.02362468584), xyz),
    dot(float3(0.03584583024, -0.07617238927, 0.956884524), xyz)
  );
}

static float3 cmXYZToOKLab(float3 xyz) {
  float3 lms = float3(
    dot(float3(0.819022438, 0.3619062601, -0.1288737815), xyz),
    dot(float3(0.03298365393, 0.9292868616, 0.03614466635), xyz),
    dot(float3(0.04817718936, 0.2642395318, 0.6335478285), xyz)
  );
  lms = float3(cmCbrt(lms.x), cmCbrt(lms.y), cmCbrt(lms.z));
  return float3(
    dot(float3(0.2104542683, 0.7936177747, -0.004072043012), lms),
    dot(float3(1.977998532, -2.428592242, 0.4505937096), lms),
    dot(float3(0.02590404247, 0.7827717125, -0.8086757549), lms)
  );
}

static float3 cmOKLabToXYZ(float3 lab) {
  float3 root = float3(
    lab.x + 0.3963377773761749 * lab.y + 0.2158037573099136 * lab.z,
    lab.x - 0.1055613458156586 * lab.y - 0.0638541728258133 * lab.z,
    lab.x - 0.0894841775298119 * lab.y - 1.2914855480194092 * lab.z
  );
  float3 lms = root * root * root;
  return float3(
    dot(float3(1.226879876, -0.5578149945, 0.2813910457), lms),
    dot(float3(-0.04057574521, 1.112286803, -0.07171105807), lms),
    dot(float3(-0.07637293667, -0.4214933324, 1.586924020), lms)
  );
}

static float cmParameter(int index, float4 first, float4 second) {
  return index < 4 ? first[index] : second[index - 4];
}

static float cmAnchor(int index) {
  constexpr float anchors[8] = {
    0.5054147614, 0.8929052686, 1.923873111, 2.541984014,
    3.370888561, 4.608577191, 5.174191934, 5.785145756
  };
  return anchors[index];
}

static float cmHueDelta(int index, float4 hue0, float4 hue1) {
  constexpr float twoPi = 6.28318530718;
  int previous = (index + 7) % 8;
  int next = (index + 1) % 8;
  float anchor = cmAnchor(index);
  float previousAnchor = index == 0 ? cmAnchor(7) - twoPi : cmAnchor(previous);
  float nextAnchor = index == 7 ? cmAnchor(0) + twoPi : cmAnchor(next);
  float value = cmParameter(index, hue0, hue1);
  return value < 0.0 ? value * (anchor - previousAnchor) : value * (nextAnchor - anchor);
}

extern "C" { namespace coreimage {

  /// Applies hue, chroma, then lightness using the original pixel's hue weights.
  float4 brightroomColorMixer(
    sampler inputImage,
    float4 hue0, float4 hue1,
    float4 saturation0, float4 saturation1,
    float4 luminance0, float4 luminance1
  ) {
    float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0) return source;
    float4 straight = unpremultiply(source);
    float3 lab = cmXYZToOKLab(cmP3ToXYZ(straight.rgb));
    float chroma = length(lab.yz);
    float gate = smoothstep(0.01, 0.04, chroma);
    if (gate <= 0.0) return source;

    constexpr float twoPi = 6.28318530718;
    float hue = atan2(lab.z, lab.y);
    if (hue < 0.0) hue += twoPi;
    float unwrapped = hue < cmAnchor(0) ? hue + twoPi : hue;
    int first = 7;
    int second = 0;
    float progress = 1.0;
    for (int index = 0; index < 8; ++index) {
      int candidate = (index + 1) % 8;
      float lower = cmAnchor(index);
      float upper = candidate == 0 ? cmAnchor(0) + twoPi : cmAnchor(candidate);
      if (unwrapped <= upper) {
        first = index;
        second = candidate;
        progress = (unwrapped - lower) / (upper - lower);
        break;
      }
    }
    float secondWeight = smoothstep(0.0, 1.0, progress);
    float firstWeight = 1.0 - secondWeight;
    float hueDelta = gate * (
      firstWeight * cmHueDelta(first, hue0, hue1)
      + secondWeight * cmHueDelta(second, hue0, hue1)
    );
    float saturation = gate * (
      firstWeight * cmParameter(first, saturation0, saturation1)
      + secondWeight * cmParameter(second, saturation0, saturation1)
    );
    float luminance = gate * (
      firstWeight * cmParameter(first, luminance0, luminance1)
      + secondWeight * cmParameter(second, luminance0, luminance1)
    );

    float outputHue = hue + hueDelta;
    float outputChroma = chroma * max(0.0, 1.0 + saturation);
    lab.x *= exp2(luminance);
    lab.yz = outputChroma * float2(cos(outputHue), sin(outputHue));
    straight.rgb = cmXYZToP3(cmOKLabToXYZ(lab));
    return premultiply(straight);
  }

}}

#endif // __METAL_CIKERNEL__
