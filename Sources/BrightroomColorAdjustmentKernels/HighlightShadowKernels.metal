// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include "ColorAdjustmentWorkingSpace.metalh"
using namespace metal;

static float3 toneEncode(float3 x) {
  return select(1.055f * pow(max(x, 0.0f), float3(1.0f / 2.4f)) - 0.055f,
    x * 12.92f, x <= 0.0031308f);
}

// Inverse twice the squared bandwidth in encoded P3, fitted at −50.
static float toneNeighborFalloff(float control) {
  return control == 0.0f ? 32.0f : 128.0f;
}

static float2 toneDecode(float2 x) {
  return select(pow((x + 0.055f) / 1.055f, float2(2.4f)), x / 12.92f, x <= 0.04045f);
}

static float3 toneTable(coreimage::sampler table, float column, float row) {
  return coreimage::sample(table, coreimage::samplerTransform(table,
    float2(column + 0.5f, row + 0.5f))).rgb;
}

// The response runs at input resolution. Read the four Gaussian guides in
// their own pixel coordinates so full-guide ROIs stay small on a tiled export.
static float3 toneGuideAt(coreimage::sampler image, float2 position) {
  float4 value = coreimage::sample(image, coreimage::samplerTransform(image, position));
  return value.rgb / max(value.a, 1e-8f);
}

// Mean signed −50 luminance loss and the proportion of scene samples at an encoded P3 tone.
static float2 sceneToneLossAtCode(coreimage::sampler table, float code) {
  float3 bin = toneGuideAt(table, float2(clamp(code * 128.0f, 0.5f, 127.5f), 0.5f));
  return float2(bin.x / max(bin.y, 1e-8f), bin.y / max(bin.z, 1e-8f));
}

// Limits measured on the linear ProPhoto lattice for negative Highlights.
constant float highlightBlackRoom = 0.03281635f;
constant float highlightWhiteLimit = 1.21244557f;

// A common odds multiplier darkens different input tones by different linear amounts.
// Express the neighboring bin's −50 loss at the pixel's original luminance.
static float transferHighlightLoss(float luminance, float binLuminance, float binLoss) {
  float span = highlightWhiteLimit + highlightBlackRoom;
  float drop = clamp(binLoss * span / ((binLuminance + highlightBlackRoom)
    * (highlightWhiteLimit - binLuminance + binLoss)), 0.0f, 1.0f);
  float fromBlack = luminance + highlightBlackRoom;
  return fromBlack * (highlightWhiteLimit - luminance) * drop / (span - fromBlack * drop);
}

// Changes to the −50 loss inferred from the two neighboring histogram bins.
struct HighlightToneNeighborhood {
  float lossDifference;    // Difference in linear luminance at the center tone.
  float retainedFraction;  // Fraction of the remaining local loss to give back.
};

static HighlightToneNeighborhood neighboringHighlightLoss(coreimage::sampler table, float y, float code,
  float2 scene, float detailFraction) {
  float2 codes = clamp(code + float2(-0.09f, 0.09f), 0.5f / 128.0f, 127.5f / 128.0f);
  float2 lower = sceneToneLossAtCode(table, codes.x);
  float2 upper = sceneToneLossAtCode(table, codes.y);
  float2 mass = float2(lower.y, upper.y);
  float2 input = toneDecode(codes);
  float2 loss = float2(transferHighlightLoss(y, input.x, lower.x),
    transferHighlightLoss(y, input.y, upper.x));
  float2 support = smoothstep(0.0f, 0.014f, min(float2(scene.y), mass));
  float2 difference = clamp(scene.x - loss, -0.10f, 0.10f) * support;
  float confidence = max(1.0f - smoothstep(0.0f, 0.14f, detailFraction),
    smoothstep(0.0f, 0.4f, scene.y - upper.y));
  float lossDifference = confidence * dot(difference, mass) / max(mass.x + mass.y, 0.01f);
  // A populated tone can have few darker neighbors, few brighter neighbors, or both.
  // The −50 reference pairs give a different response on each side of that peak.
  // Require samples on the side being compared. An empty bin beyond the end
  // of a limited-range ramp would otherwise look like a peak in the scene.
  float2 excess = max(scene.y - mass, 0.0f) * support;  // darker bin, brighter bin
  float headroom = 1.0f - code;
  float retained = headroom * headroom * dot(excess, float2(5.84886032f, -1.97729384f));
  return { lossDifference, clamp(retained, -0.42f, 0.42f) };
}

// At the same input tone, a spatial estimate can darken bright areas near edges
// by different amounts. Move its −50 loss partway toward the scene's estimate.
// Smooth regions retain more of their local darkening when the scene would lift them.
static void shareHighlightLoss(coreimage::sampler table, float3 rgb, float2 bounds, float amount,
  float detailFraction, float gamutWeight, float2 nearGuide, float2 regionGuide, float sceneDeviation,
  thread float2 &adjusted, thread float2 &at50) {
  float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
  float position = clamp((y - bounds.x) / max(bounds.y - bounds.x, 1e-7f), 0.0f, 1.0f);
  float localLoss = y - mix(at50.x, at50.y, position);
  float code = toneEncode(float3(y)).r;
  float logY = log(max(y, 1e-4f)) / 9.3f + 1.0f;
  float2 scene = sceneToneLossAtCode(table, code);
  float difference = localLoss - scene.x;
  float detail = difference > 0.0f
    ? smoothstep(0.10f, 0.25f, detailFraction) : smoothstep(0.0f, 0.05f, detailFraction);
  if (difference < 0.0f) {
    // The bright side of a dark edge retains more of its local response.
    detail *= 1.0f - 0.5f * smoothstep(0.0f, sceneDeviation, logY - nearGuide.x);
  }
  float support = smoothstep(0.0f, 2.0f / 2048.0f, scene.y);
  float shift = difference * 0.525f * detail * support * (1.0f - gamutWeight);
  // A luminance bin represents all three channels most closely near neutral.
  float neutralRatio = bounds.x / max(bounds.y, 1e-7f);
  HighlightToneNeighborhood neighboring = neighboringHighlightLoss(table, y, code, scene, detailFraction);
  shift += 0.25f * smoothstep(0.40f, 0.75f, code) * (1.0f - gamutWeight) * sqrt(neutralRatio)
    * neighboring.lossDifference;
  shift += neighboring.retainedFraction * max(localLoss - shift, 0.0f) * (1.0f - gamutWeight);

  // The last column gives the 95th percentile, upper spread and midtone protection.
  // A high-contrast edge is less representative of the pixel's own lighting.
  float3 sceneRange = toneGuideAt(table, float2(128.5f, 0.5f));
  float2 means = float2(nearGuide.x, regionGuide.x);
  float2 variance = max(float2(nearGuide.y, regionGuide.y) - means * means, 0.0f);
  float2 contrast = (logY - means) * (0.0064f / (variance + 0.0064f));
  float4 metering = float4(sceneRange.x - 0.88f, sceneRange.y - 0.18f, contrast);
  float gain = dot(metering, float4(-0.166803642f, -0.064958137f, 0.608069489f, 0.393992554f));
  shift += clamp(gain, -0.75f, 0.75f) * max(localLoss - shift, 0.0f) * (1.0f - gamutWeight);

  // In detailed scenes with a broad range of occupied tones, retain more
  // midtone light. Scale the remaining loss so the correction stops at the source.
  float midtone = 4.0f * code * (1.0f - code);
  float retained = sceneRange.z * smoothstep(0.0f, 0.125f, detailFraction);
  shift += retained * midtone * (1.0f - gamutWeight) * max(localLoss - shift, 0.0f);

  // At −50 a lift moves each endpoint toward its source, a drop toward
  // black. Their luminance-weighted shift matches the metered correction
  // until the endpoints run out of room. A channel at black can stay there
  // while a brighter channel continues to darken.
  float2 loss = max(bounds - at50, 0.0f);
  float2 room = shift > 0.0f ? loss : max(at50, 0.0f);
  float available = mix(room.x, room.y, position);
  float2 correction = room * clamp(shift / max(available, 1e-7f), -1.0f, 1.0f);
  float2 fraction = float2(1.0f);
  if (amount < 50.0f) {
    fraction = select(float2(amount / 50.0f),
      clamp((bounds - adjusted) / max(loss, 1e-8f), 0.0f, 1.0f), loss > 1e-7f);
  }
  adjusted = clamp(adjusted + correction * fraction, 0.0f, bounds);
  at50 += correction;
}

// Change RGB distance from gray at fixed output luminance. Both axes of the
// negative controls were measured on colored inputs at five encoded P3 levels.
static float2 toneNegativeColor(float3 rgb, float2 bounds, float inputY, float outputY,
  float2 adjusted, bool highlights) {
  float slope = (adjusted.y - adjusted.x) / (bounds.y - bounds.x);
  float codeY = toneEncode(float3(inputY)).r;
  float3 code = toneEncode(rgb);
  float position = clamp(codeY, 0.0f, 1.0f) * 4.0f;
  int lower = min(int(position), 3);

  // Rebuild these rows with Light/fit-negative-tone-color.py.
  const float2 highlightColor[5] = {
    float2(-0.153160510f, -0.024848108f), float2(0.225179306f, 0.082316105f),
    float2(0.195592141f, 0.423580253f), float2(-0.033774987f, 0.183691517f),
    float2(-0.816098788f, -0.249015982f),
  };
  const float3 shadowColor[5] = {
    float3(1.370475412f, 0.020082072f, -0.223235956f),
    float3(0.444059141f, 2.701338458f, 0.599952550f),
    float3(0.220959332f, -0.850605362f, -1.807877737f),
    float3(-0.554768238f, 1.079742486f, 0.944189628f),
    float3(-0.644875918f, 0.049489005f, -0.468994130f),
  };
  float response;
  if (highlights) {
    float span = max(code.r, max(code.g, code.b)) - min(code.r, min(code.g, code.b));
    float2 coefficients = mix(highlightColor[lower], highlightColor[lower + 1], position - lower);
    response = dot(coefficients, float2(1.0f, span));
  } else {
    float3 coefficients = mix(shadowColor[lower], shadowColor[lower + 1], position - lower);
    response = dot(coefficients, float3(1.0f, code.r - codeY, code.b - codeY));
  }
  float change = response * (outputY - inputY) / (inputY + 0.003f);
  // Limit the new RGB span to the first channel reaching black or white.
  float limit = min(outputY / max(inputY - bounds.x, 1e-7f),
    (1.0f - outputY) / max(bounds.y - inputY, 1e-7f));
  float newSlope = clamp(slope + change, 0.0f, max(slope, limit));
  return (newSlope - slope) * (bounds - inputY);
}

// The change at -50 also depends on how log luminance varies with distance.
// Five encoded luminance knots interpolate the measured response to these bands.
static float toneNeighborhoodOffset(float inputY, float4 surround, float mean, bool highlights) {
  float pixel = log(max(inputY, 1e-4f)) / 9.3f + 1.0f;
  float position = clamp(toneEncode(float3(inputY)).r, 0.0f, 1.0f) * 4.0f;
  int lower = min(int(position), 3);
  float fraction = position - lower;
  if (!highlights) {
    const float shadow[5] = { 0.0004785f, 0.0023582f, -0.0035582f, -0.0016227f, 0.0002978f };
    return (pixel - mean) * mix(shadow[lower], shadow[lower + 1], fraction);
  }
  const float4 local[5] = {
    float4(0.0010724f, -0.0003669f, -0.0001080f, 0.0004484f),
    float4(0.0005241f, 0.0102895f, -0.0034282f, 0.0104173f),
    float4(0.0436222f, 0.1044085f, 0.0360097f, 0.0258919f),
    float4(0.0197427f, 0.0827888f, 0.0339535f, 0.0174288f),
    float4(0.0056523f, -0.0006482f, -0.0028162f, -0.0014748f),
  };
  const float outer[5] = { 0.0002570f, 0.0075279f, 0.0069727f, 0.0003916f, -0.0064410f };
  float4 bands = surround - float4(pixel, surround.xyz);
  return dot(bands, mix(local[lower], local[lower + 1], fraction))
    + (mean - surround.w) * mix(outer[lower], outer[lower + 1], fraction);
}

// Monotone strength coordinates fitted to paired neutral, -10, -25 and -50
// exports of a gray ramp and a color chart. Rebuild with fit-negative-tone-strength.py.
constant float2 negativeStrengthKnots[33] = {
  float2(0.00000000f, 0.00000000f), float2(0.03504045f, 0.03595431f),
  float2(0.07038418f, 0.07193096f), float2(0.10640343f, 0.10796933f),
  float2(0.14319364f, 0.14418368f), float2(0.18037213f, 0.18086213f),
  float2(0.21833910f, 0.21784229f), float2(0.25691088f, 0.25510452f),
  float2(0.29563227f, 0.29082121f), float2(0.33343787f, 0.32377090f),
  float2(0.36984880f, 0.35533324f), float2(0.40573411f, 0.38713587f),
  float2(0.44118152f, 0.41920938f), float2(0.47595118f, 0.45078688f),
  float2(0.51004433f, 0.48113860f), float2(0.54349154f, 0.51170426f),
  float2(0.57634966f, 0.54230180f), float2(0.60870849f, 0.57207278f),
  float2(0.64062139f, 0.60007020f), float2(0.67205393f, 0.62552054f),
  float2(0.70292445f, 0.64720234f), float2(0.73316358f, 0.66403671f),
  float2(0.76270220f, 0.68083624f), float2(0.79146872f, 0.70391626f),
  float2(0.81941408f, 0.73158791f), float2(0.84638349f, 0.76223739f),
  float2(0.87240859f, 0.79464866f), float2(0.89735890f, 0.82802889f),
  float2(0.92100075f, 0.86197542f), float2(0.94263747f, 0.89625753f),
  float2(0.96198059f, 0.93074015f), float2(0.98068162f, 0.96533920f),
  float2(1.00000000f, 1.00000000f),
};

static float negativeStrengthKnot(int index, bool highlights) {
  return highlights ? negativeStrengthKnots[index].x : negativeStrengthKnots[index].y;
}

// Each coordinate is nearly proportional to the signed slider change for a
// given channel. The knots correct the residual in the angular or log-odds scale.
static float negativeStrengthCoordinate(float value, bool highlights) {
  const float twiceLog10001 = 18.42088073f;
  float base = highlights ? asin(sqrt(value)) * (2.0f / M_PI_F)
    : 0.5f + log((value + 0.0001f) / (1.0001f - value)) / twiceLog10001;
  float position = clamp(base * 32.0f, 0.0f, 32.0f);
  int lower = min(int(position), 31);
  return mix(negativeStrengthKnot(lower, highlights), negativeStrengthKnot(lower + 1, highlights),
             position - float(lower));
}

static float negativeStrengthLinearValue(float coordinate, bool highlights) {
  int lower = 0;
  for (int step = 16; step >= 1; step /= 2) {
    if (negativeStrengthKnot(lower + step, highlights) <= coordinate) lower += step;
  }
  float start = negativeStrengthKnot(lower, highlights);
  float end = negativeStrengthKnot(lower + 1, highlights);
  float base = (float(lower) + clamp((coordinate - start) / (end - start), 0.0f, 1.0f)) / 32.0f;
  if (highlights) {
    float root = sin(base * (M_PI_F / 2.0f));
    return root * root;
  }
  return clamp(1.0002f / (1.0f + exp((0.5f - base) * 18.42088073f)) - 0.0001f, 0.0f, 1.0f);
}

// In linear ProPhoto RGB, follow each source extremum toward its -50 endpoint.
// Apply the fraction to the P3 change. An outlying P3 channel inherits the
// nearest measured fraction, so increasing the amount keeps darkening it.
static float2 negativeStrengthBounds(float3 rgb, float2 bounds, float2 end, float amount, bool highlights) {
  float3 channels = clamp(brightroom::linearP3ToROMM(rgb), 0.0f, 1.0f);
  float2 source = float2(min(channels.r, min(channels.g, channels.b)), max(channels.r, max(channels.g, channels.b)));
  float slope = (end.y - end.x) / max(bounds.y - bounds.x, 1e-6f);
  float2 target = clamp(end.x + (source - bounds.x) * slope, 0.0f, 1.0f);
  float t = amount / 50.0f;
  float2 fraction;
  for (int i = 0; i < 2; ++i) {
    float span = source[i] - target[i];
    if (span > 1e-7f) {
      float startCoordinate = negativeStrengthCoordinate(source[i], highlights);
      float endCoordinate = negativeStrengthCoordinate(target[i], highlights);
      float value = negativeStrengthLinearValue(mix(startCoordinate, endCoordinate, t), highlights);
      fraction[i] = (source[i] - value) / span;
    } else {
      fraction[i] = t;
    }
  }
  float2 position = clamp((bounds - source.x) / max(source.y - source.x, 1e-6f), 0.0f, 1.0f);
  float2 result = mix(bounds, end, mix(fraction.x, fraction.y, position));
  return t < 1.0f ? clamp(result, end, bounds) : clamp(result, 0.0f, end);
}

// The blue guide channel integrates the distance below the encoded midpoint for negative
// Highlights and the coverage below the brightest third for negative Shadows.
static float toneRangeSample(float code, bool highlights) {
  return highlights ? max(0.5f - code, 0.0f) : clamp(3.0f - 3.0f * code, 0.0f, 1.0f);
}

// At the same pixel brightness, changing the surrounding luminance distribution
// changes the measured -50 endpoint. The four guide samples share the log-luma
// blurs and area average already evaluated for the spatial response.
static float2 toneRangeEndpoint(float2 start, float2 end, float inputY,
  float outputY, float4 range, float sceneDeviation, bool highlights) {
  float code = clamp(toneEncode(float3(inputY)).r, 0.0f, 1.0f);
  float position = code * 4.0f;
  int i = min(int(position), 3);
  float f = position - i;
  // Reproduce the two signed fits with Light/fit-tone-range.py.
  const float4 highlightRange[5] = {
    float4(0.000258622f, -0.000002922f, 0.000000280f, -0.000001660f),
    float4(-0.000722207f, -0.000238809f, 0.000037474f, 0.000134209f),
    float4(-0.000152823f, -0.006417701f, -0.008166690f, -0.010014405f),
    float4(-0.000358418f, -0.008414776f, -0.010939611f, -0.012854336f),
    float4(0.000611797f, -0.000074241f, 0.001103640f, 0.001677411f),
  };
  const float3 highlightRangeScene[5] = {
    float3(-0.000019235f, 0.000014789f, -0.000035984f),
    float3(0.000019251f, -0.000244827f, -0.001479512f),
    float3(-0.010306522f, -0.004135440f, -0.006276282f),
    float3(-0.012866615f, -0.005434371f, -0.002557702f),
    float3(0.002454194f, 0.001766146f, -0.000766036f),
  };
  const float4 shadowRange[5] = {
    float4(-0.000659580f, 0.000072919f, 0.000123803f, 0.000139142f),
    float4(-0.000479560f, 0.001091810f, 0.002113411f, 0.002566060f),
    float4(-0.000090725f, 0.003297710f, 0.006335945f, 0.008745739f),
    float4(-0.000097513f, 0.003443422f, 0.003478197f, 0.002840930f),
    float4(0.000189545f, 0.003916645f, 0.000875345f, 0.000153119f),
  };
  const float3 shadowRangeScene[5] = {
    float3(0.000108815f, -0.000081740f, 0.000015599f),
    float3(0.001988264f, -0.000887847f, 0.000181427f),
    float3(0.008461287f, -0.006738048f, 0.000471185f),
    float3(-0.000593795f, -0.007920489f, -0.000118892f),
    float3(0.000120539f, -0.001251182f, -0.000487050f),
  };
  float4 difference = range - toneRangeSample(code, highlights);
  float signedResponse = (outputY - inputY) / (outputY + 0.05f);
  float4 local = highlights ? mix(highlightRange[i], highlightRange[i + 1], f)
    : mix(shadowRange[i], shadowRange[i + 1], f);
  float3 scene = highlights ? mix(highlightRangeScene[i], highlightRangeScene[i + 1], f)
    : mix(shadowRangeScene[i], shadowRangeScene[i + 1], f);
  float change = dot(local, float4(1.0f, difference.xyz))
    + dot(scene, float3(difference.w, sceneDeviation - 0.1f, signedResponse));
  // Both extrema share a gain. Limit it by the first channel reaching its
  // brighter anchor so increasing the negative slider keeps every channel darkening.
  float2 limits = select(float2(1e8f), start / max(end, 1e-8f), end > 1e-8f);
  float gain = clamp(1.0f + min(sceneDeviation / 0.015f, 1.0f) * change / (outputY + 0.045f),
    0.0f, min(limits.x, limits.y));
  return min(start, end * gain);
}

// The -50 color response is smooth in the source luminance and in the loss already
// predicted by the spatial model. Evaluate the scene-dependent surface once on a
// 33-by-33 grid. Fit these centers and weights with Light/fit-highlight-color-gain.py.
static float toneHighlightGainAt(float codeY, float normalizedLoss, float2 scene) {
  float4 position = clamp(float4((codeY - 0.54f) / 0.28f, normalizedLoss,
    (scene - float2(0.73f, 0.12f)) / float2(0.14f, 0.07f)), -3.0f, 3.0f);
  const float4 centers[32] = {
    float4(0.920507908f, -0.933368802f, 0.448485076f, 1.796786904f),
    float4(-1.146991730f, 1.399578333f, -0.180588514f, -0.771152496f),
    float4(-0.451190978f, -0.092264608f, 1.548680544f, 0.490338802f),
    float4(0.329008490f, 0.502319813f, -0.864907026f, -0.009840256f),
    float4(0.178667635f, -0.493135065f, -0.482831240f, -0.369815022f),
    float4(-0.315736920f, 0.080443732f, 0.171656325f, 0.214978024f),
    float4(-1.443914890f, -1.368083596f, -1.649425864f, -1.198231578f),
    float4(1.177153111f, 0.920447648f, 0.849131286f, 0.936368346f),
    float4(2.129246712f, -0.225965798f, -1.411093712f, 0.038059518f),
    float4(-1.770335913f, 0.474514484f, 0.973484278f, -0.519687593f),
    float4(-0.053157002f, -0.838545024f, -0.574599802f, 0.743463933f),
    float4(0.088103443f, 1.707573295f, 0.094246604f, -1.690931559f),
    float4(0.624411285f, -1.743476033f, 1.332226992f, -0.912064254f),
    float4(-0.559472978f, 0.855413198f, -0.987669349f, 1.161676884f),
    float4(-0.737726033f, -0.488080919f, 0.541822433f, -0.228794008f),
    float4(0.784367502f, 0.234612957f, -0.105204210f, 0.381741732f),
    float4(0.734604061f, -0.357469141f, 1.070950866f, -1.459638476f),
    float4(-0.794513702f, 0.277022302f, -1.263832211f, 1.088645101f),
    float4(-0.603640378f, -1.972371101f, 0.075793818f, -0.435488373f),
    float4(0.573742568f, 0.694284558f, -0.599352241f, 0.259666502f),
    float4(0.045890514f, -0.683994710f, -1.021936774f, 0.672419429f),
    float4(-0.090628348f, 1.895972729f, 1.289180398f, -0.146849602f),
    float4(-2.023048878f, -0.264480948f, -0.045236275f, 1.940220237f),
    float4(1.858819485f, 0.348519832f, 0.609507859f, -0.781863391f),
    float4(1.451084375f, -1.278421760f, -0.282154530f, -0.245822713f),
    float4(-1.162764430f, 1.114590406f, 0.344172597f, 0.423557967f),
    float4(-0.196038276f, -0.628525794f, -0.678533852f, -1.117918849f),
    float4(0.302807629f, 0.043077137f, 2.481880188f, 1.515432358f),
    float4(0.459432155f, -0.051189035f, 0.311797529f, 0.810512841f),
    float4(-0.326496184f, 0.642948627f, -0.332273126f, -2.123721361f),
    float4(-0.939234376f, -1.137366056f, 0.717467070f, 0.118470825f),
    float4(1.114393711f, 1.297724485f, -2.329537153f, -0.640650153f)
  };
  const float weights[32] = {
    -0.011590541f, 0.050929509f, -0.011423419f, -0.030818085f,
    0.003297259f, 0.059241901f, -0.026168301f, 0.007844040f,
    -0.149670719f, -0.030160228f, 0.003488527f, 0.067315250f,
    -0.024822842f, 0.071594340f, 0.012389874f, -0.022279075f,
    0.059927337f, 0.007925906f, -0.039436775f, -0.014941263f,
    -0.036509200f, 0.084808623f, -0.004260288f, -0.047733079f,
    -0.064733959f, 0.068525438f, -0.007547739f, -0.049762630f,
    0.018131083f, 0.024857425f, -0.034110654f, -0.052913781f,
  };
  float change = 0.0f;
  for (int i = 0; i < 32; ++i) {
    float4 d = position - centers[i];
    change += weights[i] * exp(-dot(d, d) / 4.5f);
  }
  return change;
}

static float2 toneHighlightColorEndpoint(coreimage::sampler gains, float3 rgb,
  float inputY, float outputY, float2 start, float2 end, float deviation) {
  float3 code = toneEncode(rgb);
  float chroma = max(code.r, max(code.g, code.b)) - min(code.r, min(code.g, code.b));
  if (chroma <= 1e-6f) return end;
  float codeY = toneEncode(float3(inputY)).r;
  float loss = (codeY - toneEncode(float3(outputY)).r) / max(0.1f, 2.0f * codeY * (1.0f - codeY));
  float lossPosition = clamp(((loss - 0.13f) / 0.15f + 3.0f) / 6.0f, 0.0f, 1.0f);
  float2 value = toneTable(gains, codeY * 32.0f, lossPosition * 32.0f).rg;
  float change = (value.x - value.y) * chroma / (chroma + 0.08f) * min(deviation / 0.015f, 1.0f);
  // A saturated color's low channel carries less of the luminance change.
  // The square-root taper retains more of the change as the two channels converge.
  float ratio = end.x / max(end.y, 1e-7f);
  float2 direction = float2(end.x * sqrt(ratio), end.y);
  float2 delta = change * direction / (outputY + 0.045f);
  // Both endpoints must stay ordered, within black and their brighter anchors.
  float scale = 1.0f;
  for (int i = 0; i < 2; ++i) {
    if (delta[i] > 0.0f) scale = min(scale, max(0.0f, start[i] - end[i]) / delta[i]);
    if (delta[i] < 0.0f) scale = min(scale, -end[i] / delta[i]);
  }
  if (delta.x > delta.y) scale = min(scale, (end.y - end.x) / (delta.x - delta.y));
  return end + scale * delta;
}

// Each scene contributes two multipliers at the encoded luminance knots.
// The first rows weight the spatial loss, the remaining rows weight the original color.
// Rebuild the centers and coefficients with Light/fit-shadow-color-response.py.
constant float2 shadowSceneCenters[5] = {
  float2(-1.969467521f, 1.713817528f),
  float2(-1.221421778f, 0.501674375f),
  float2(0.188161512f, 0.423102096f),
  float2(0.899702077f, 0.219995269f),
  float2(0.909028903f, -1.356166773f)
};
constant float4 shadowLossCoefficients[5][8] = {
  {
    float4(0.006647509f, -0.000575639f, 0.001958072f, 0.009259190f),
    float4(-0.105905906f, -0.024696673f, 0.014894813f, -0.082915241f),
    float4(-0.269113797f, -0.006756608f, 0.013987870f, -0.129862950f),
    float4(-0.067460630f, 0.001377066f, 0.003737857f, -0.018218387f),
    float4(0.044176264f, 0.003480220f, 0.004185306f, 0.041035138f),
    float4(0.022603732f, 0.067339998f, 0.018976167f, -0.139986529f),
    float4(-0.027304512f, 0.113004424f, -0.044233708f, -0.209744646f),
    float4(0.016590615f, 0.008133896f, -0.001234801f, -0.025857571f),
  },
  {
    float4(0.003829824f, 0.007437821f, -0.002435890f, 0.017043699f),
    float4(-0.113629261f, -0.008438748f, 0.037212355f, -0.012371726f),
    float4(-0.385400142f, -0.044663971f, 0.070598770f, -0.103240242f),
    float4(-0.106076916f, -0.006077976f, 0.010746826f, -0.018436209f),
    float4(-0.003895433f, 0.042803990f, 0.000497061f, 0.051612390f),
    float4(0.082263423f, 0.072196279f, 0.123953588f, -0.174696618f),
    float4(0.169601095f, -0.002913003f, 0.126070306f, -0.298979603f),
    float4(-0.002521552f, -0.016788143f, 0.019331321f, -0.039763504f),
  },
  {
    float4(0.014285728f, -0.009052105f, 0.017133608f, 0.004833130f),
    float4(-0.114948309f, 0.048657911f, -0.039513122f, -0.075438337f),
    float4(-0.338518399f, -0.007668094f, -0.039478292f, -0.084974616f),
    float4(0.010396666f, -0.004136318f, 0.001898727f, 0.008560741f),
    float4(0.107079085f, -0.043398337f, 0.044055609f, 0.029553363f),
    float4(0.118547535f, -0.078474555f, 0.153989809f, -0.205959421f),
    float4(-0.084572615f, 0.094573695f, -0.090230076f, -0.255264474f),
    float4(0.041475767f, 0.018631836f, 0.001455875f, 0.004478591f),
  },
  {
    float4(0.023705253f, -0.004345103f, 0.032946166f, 0.001570644f),
    float4(0.011782863f, 0.202716146f, -0.142862464f, -0.015282247f),
    float4(0.085576799f, 0.002624672f, -0.102714798f, 0.065316947f),
    float4(0.168457147f, -0.001701521f, -0.005326465f, 0.048935185f),
    float4(0.065311235f, -0.014942021f, 0.080698454f, -0.014557179f),
    float4(0.287011975f, 0.258957342f, 0.074448857f, -0.048721987f),
    float4(0.681917544f, 0.121389706f, -0.122985362f, 0.080733026f),
    float4(0.376099334f, 0.039901992f, -0.002673319f, 0.079203628f),
  },
  {
    float4(-0.001671005f, -0.000714998f, 0.000897293f, -0.002022357f),
    float4(-0.077473594f, 0.002966269f, -0.106547658f, 0.014884134f),
    float4(-0.438489404f, -0.084620615f, -0.062942749f, 0.008606335f),
    float4(0.000736445f, -0.000029256f, -0.000036114f, 0.000095207f),
    float4(-0.007356797f, -0.003208673f, 0.003028685f, -0.009119452f),
    float4(0.089171994f, -0.025795622f, -0.110200651f, 0.107217487f),
    float4(-0.041270673f, -0.015199497f, -0.031137012f, -0.203262172f),
    float4(0.117514364f, 0.023587426f, -0.022661690f, 0.000397787f),
  },
};

// Fit the -50 loss in color and scene coordinates once. The original signed
// interpolation and wider-gamut continuation both use this corrected endpoint.
static float2 toneShadowColorEndpoint(coreimage::sampler gains, float3 rgb,
  float2 bounds, float inputY, float2 end, float deviation) {
  if (bounds.y - bounds.x <= 1e-6f) return end;
  float3 code = toneEncode(rgb);
  float chroma = max(code.r, max(code.g, code.b)) - min(code.r, min(code.g, code.b));
  float codeY = toneEncode(float3(inputY)).r;
  float2 loss = bounds - end;
  float peak = bounds.y + 0.035f;
  float relativeLoss = clamp(max(loss.x, loss.y) * 5.0f / (bounds.y + 0.025f), 0.0f, 3.0f);
  float4 terms = float4(1.0f, (rgb.r - inputY) / peak, (rgb.b - inputY) / peak, relativeLoss);
  float2 response = float2(0.0f);
  for (int term = 0; term < 4; ++term) {
    float3 pair = toneTable(gains, codeY * 3.0f, float(term));
    response += terms[term] * (pair.rg - pair.b);
  }
  float2 scale = bounds * (0.15f * (1.0f - 0.65f * codeY) / peak);
  float weight = chroma / (chroma + 0.06f) * min(deviation / 0.015f, 1.0f);
  float2 gain = clamp(1.0f + weight * (loss * response.x + scale * response.y) / max(loss, 0.00015f), 0.0f, 4.0f);
  float2 corrected = clamp(bounds - gain * loss, 0.0f, bounds);
  return float2(min(corrected.x, corrected.y), corrected.y);
}

// Scene-wide and local changes to the negative Shadows endpoint at −50.
struct ShadowTone {
  float sceneLuminance;
  float sceneWeight;
  float localLoss;
};

// Limits of the log-odds response calibrated on the linear ProPhoto color lattice.
constant float shadowBlackRoom = 0.000228f;
constant float shadowWhiteLimit = 1.17866f;

// Interpolate each channel through its remaining measured loss from −10 to −50.
static float2 highlightFromFirstStep(float2 spatial, float weight, float2 at10, float2 at50,
  float2 from10, float2 fromAmount, float amount) {
  float2 interval = from10 - at50;
  float2 progress = select(float2((amount - 10.0f) / 40.0f),
    (from10 - fromAmount) / max(interval, 1e-8f), interval > 1e-7f);
  return mix(spatial, mix(at10, at50, clamp(progress, 0.0f, 1.0f)), weight);
}

// Correct the -50 endpoint, then keep each intermediate color between its anchors.
static float2 toneBetweenAnchors(float3 rgb, float2 bounds, float2 adjusted,
  float2 start, float2 end, float4 surround, float2 scene, float4 range, coreimage::sampler colorGains,
  bool highlights, float2 firstStep, ShadowTone shadowTone,
  float amountProgress, float sliderAmount, bool measureWeakAnchor, thread float2 &calibratedEnd,
  thread float2 &weakLossFraction) {
  float inputY = dot(rgb, float3(0.22897456f, 0.69173852f, 0.07928692f));
  float fraction = clamp((inputY - bounds.x) / max(bounds.y - bounds.x, 1e-6f), 0.0f, 1.0f);
  float2 luminance = float2(1.0f - fraction, fraction);
  float2 corrected = end;
  if (bounds.y - bounds.x > 1e-6f) {
    float2 change = toneNegativeColor(rgb, bounds, inputY, dot(end, luminance), end, highlights);
    // Reduce the color change as a pair if either channel would brighten at -50.
    float2 room = max(start - end, 0.0f) / max(change, 1e-8f);
    float limit = min(change.x > 0.0f ? room.x : 1.0f, change.y > 0.0f ? room.y : 1.0f);
    corrected += min(limit, 1.0f) * change;
  }
  float offset = toneNeighborhoodOffset(inputY, surround, scene.x, highlights) * min(scene.y / 0.015f, 1.0f);
  corrected = min(start, toneDecode(clamp(toneEncode(float3(corrected, 0.0f)).rg + offset, 0.0f, 1.0f)));
  corrected = toneRangeEndpoint(start, corrected, inputY, dot(corrected, luminance), range, scene.y, highlights);
  if (!highlights) {
    corrected = toneShadowColorEndpoint(colorGains, rgb, bounds, inputY, corrected, scene.y);
    // Move both extrema by the same luminance difference. Preserve hue and
    // keep the −50 endpoint between black and the original channel values.
    float shift = (shadowTone.sceneLuminance - dot(corrected, luminance)) * shadowTone.sceneWeight;
    corrected += clamp(shift, -corrected.x, min(start.x - corrected.x, start.y - corrected.y));
    // Scale the −50 loss along its existing color direction. A small neutral
    // component also lets a dark pixel respond when its current loss is zero.
    float2 loss = max(start - corrected, 0.0f);
    float2 direction = loss + 0.003f;
    float scale = shadowTone.localLoss / dot(direction, luminance);
    float2 blackLimit = corrected / direction;
    float2 sourceLimit = loss / direction;
    float upper = min(blackLimit.x, blackLimit.y);
    // Keep the original ordering when the brighter channel would darken faster.
    if (loss.y > loss.x) upper = min(upper, (corrected.y - corrected.x) / (loss.y - loss.x));
    corrected -= clamp(scale, -min(sourceLimit.x, sourceLimit.y), upper) * direction;
  }
  // Retain the −25 spatial estimate alongside the color-corrected −50 endpoint.
  float2 priorEnd = corrected;
  float2 weakEnd = start;
  float2 channelWeight = bounds / max(bounds.y, 1e-7f);
  bool coloredHighlight = highlights && bounds.y - bounds.x > 1e-6f;
  if (coloredHighlight) {
    weakEnd = mix(start, negativeStrengthBounds(rgb, bounds, priorEnd, 25.0f, true), channelWeight);
    corrected = toneHighlightColorEndpoint(colorGains, rgb, inputY, dot(priorEnd, luminance),
      min(start, weakEnd), priorEnd, scene.y);
    corrected = min(weakEnd, corrected);
  }
  calibratedEnd = corrected;
  if (amountProgress > 1.0f && !highlights) return corrected;
  float2 result;
  if (coloredHighlight && sliderAmount > 25.0f) {
    // The spatial path interpolates between its separate −25 and −50 colors.
    result = mix(weakEnd, corrected, clamp(amountProgress, 0.0f, 1.0f));
  } else {
    float span = dot(start - end, luminance);
    float progress = span < 1e-7f ? amountProgress : clamp(dot(start - adjusted, luminance) / span, 0.0f, 1.0f);
    if (!highlights && sliderAmount < 50.0f) {
      // Only the local portion of the −50 loss has a measured spatial strength curve.
      // Apply any extra loss from the corrected endpoint in proportion to the slider.
      float correctedLoss = dot(start - priorEnd, luminance);
      float localShare = clamp(span / max(correctedLoss, 1e-7f), 0.0f, 1.0f);
      progress = mix(sliderAmount / 50.0f, progress, localShare);
    }
    result = amountProgress <= 0.0f ? adjusted : mix(start, priorEnd, progress);
    if (highlights && sliderAmount < 50.0f) {
      result = mix(result, negativeStrengthBounds(rgb, bounds, priorEnd, sliderAmount, true), channelWeight);
    }
  }
  bool needsAnchor = measureWeakAnchor && sliderAmount > 25.0f;
  if (highlights && sliderAmount > 10.0f && (needsAnchor || sliderAmount < 50.0f)) {
    float2 at25 = weakEnd;
    if (coloredHighlight) {
      // The same disagreement at the fixed −50 endpoint weights both the
      // requested strength and the −25 anchor used for the dark-surround loss.
      float spatialPeak = min(weakEnd.y, priorEnd.y);
      float disagreement = abs(corrected.y - spatialPeak) / max(bounds.y - corrected.y, 0.008f);
      float weight = 1.0f - smoothstep(0.0f, 1.0f, disagreement);
      float2 at10 = mix(firstStep, negativeStrengthBounds(rgb, bounds, priorEnd, 10.0f, true), channelWeight);
      float2 from10 = negativeStrengthBounds(rgb, bounds, corrected, 10.0f, true);
      if (needsAnchor) {
        float2 from25 = negativeStrengthBounds(rgb, bounds, corrected, 25.0f, true);
        at25 = highlightFromFirstStep(weakEnd, weight, at10, corrected, from10, from25, 25.0f);
      }
      if (sliderAmount < 50.0f) {
        float2 fromAmount = negativeStrengthBounds(rgb, bounds, corrected, sliderAmount, true);
        result = highlightFromFirstStep(result, weight, at10, corrected, from10, fromAmount, sliderAmount);
      }
    } else if (needsAnchor) {
      at25 = mix(start, negativeStrengthBounds(rgb, bounds, priorEnd, 25.0f, true), channelWeight);
    }
    if (needsAnchor) {
      weakLossFraction = clamp((bounds - at25) / max(bounds - corrected, 1e-8f), 0.0f, 1.0f);
    }
  }
  if (amountProgress > 1.0f) return clamp(corrected + (adjusted - end), 0.0f, 1.0f);
  return result;
}

// The extra Highlights loss depends on the fixed −50 color and the spatial
// estimate for −100. Each row fits the two source extrema at a linear ROMM level.
// Reproduce the coefficient order with Light/fit-strong-highlights.py.
constant float2 strongHighlightLossWeights[7][6] = {
  { float2(-0.67318463f, -0.43616798f), float2(0.08792526f, 0.31582510f), float2(0.97031745f, 0.38026775f),
    float2(-0.63124815f, 0.19888311f), float2(-0.45589349f, -0.06995725f), float2(0.02343564f, 0.11330771f) },
  { float2(-0.86610208f, -0.88459751f), float2(0.49365258f, 0.52222853f), float2(0.50350494f, 0.46210714f),
    float2(-0.01625029f, 0.57148263f), float2(1.12548756f, -0.18539789f), float2(-0.07658574f, -0.04272732f) },
  { float2(-0.66940375f, -0.65118822f), float2(0.55187890f, 0.53456142f), float2(0.52621507f, 0.50644907f),
    float2(0.19525696f, -0.13128346f), float2(-0.33160117f, 0.32747504f), float2(-0.11029094f, -0.09424357f) },
  { float2(-0.50067385f, -0.52384715f), float2(0.32795292f, 0.32436906f), float2(0.21809871f, 0.27696154f),
    float2(-0.06537560f, -0.16388562f), float2(-0.38414524f, 0.48136589f), float2(0.00563658f, -0.00102092f) },
  { float2(-0.65051148f, -0.61348241f), float2(0.18252677f, 0.14402802f), float2(0.21828369f, 0.21500225f),
    float2(-0.01173295f, -0.35967469f), float2(-0.07968171f, 0.65187319f), float2(0.07756794f, 0.08093389f) },
  { float2(-1.35923836f, -1.23722474f), float2(0.17713283f, 0.05946587f), float2(0.23836535f, 0.25530445f),
    float2(-0.06260976f, -0.51199929f), float2(-0.06165211f, 1.24654499f), float2(0.38485630f, 0.37437488f) },
  { float2(-1.01224324f, -1.00192635f), float2(-0.05325270f, -0.03364134f), float2(-0.02871046f, -0.03997467f),
    float2(-0.00083629f, 0.40248549f), float2(-0.00118813f, 0.57052182f), float2(0.35092573f, 0.33965744f) },
};

// Recover the separation of the ProPhoto extrema after spatial metering.
// The common odds multiplier is calibrated by fit-highlight-color-separation.py.
static float3 separatedHighlightColor(float3 rgb, float3 adjusted, float p3Span, float gamutWeight) {
  const float3 luminance = float3(0.2289746f, 0.6917385f, 0.0792869f);
  const float blackRoom = 0.00017968f;
  const float whiteLimit = 1.15264127f;
  float3 romm = clamp(brightroom::linearP3ToROMM(rgb), 0.0f, 1.0f);
  float low = min(romm.r, min(romm.g, romm.b));
  float high = max(romm.r, max(romm.g, romm.b));
  float y = dot(rgb, luminance);
  float target = dot(adjusted, luminance);
  float position = clamp((y - low) / max(high - low, 1e-7f), 0.0f, 1.0f);
  float extent = whiteLimit + blackRoom;
  float2 bounds = (float2(low, high) + blackRoom) / extent;
  float span = bounds.y - bounds.x;
  float level = clamp((target + blackRoom) / extent, 0.0f, 1.0f);
  // At fixed luminance the common channel odds give a quadratic in the RGB slope.
  float lower = span * level * (1.0f - position);
  float upper = span * (1.0f - level) * position;
  float room = bounds.x * (1.0f - bounds.y);
  float sum = lower + upper;
  float difference = lower - upper;
  float root = sqrt(difference * difference + room * (room + 2.0f * sum));
  float slope = 2.0f * level * (1.0f - level) / max(room + sum + root, 1e-8f);
  float3 projected = target + (rgb - y) * slope;

  if (gamutWeight > 0.0f) {
    // Near P3 black, the measured peak is a better constraint than luminance.
    // Apply the upper channel's change in odds to the original lower channel.
    // Adding the change to the bounded source gives exactly its original peak
    // at zero loss, including P3 colors just outside the ProPhoto boundary.
    float3 change = brightroom::linearP3ToROMM(adjusted - rgb);
    float3 output = romm + change;
    float peak = max(output.r, max(output.g, output.b));
    float fromBlack = (low + blackRoom) * max(peak + blackRoom, 0.0f) * (whiteLimit - high);
    float toWhite = (whiteLimit - low) * (high + blackRoom) * max(whiteLimit - peak, 0.0f);
    float minimum = (whiteLimit * fromBlack - blackRoom * toWhite) / max(fromBlack + toWhite, 1e-8f);
    float3 onHueLine = (rgb - low) / max(high - low, 1e-7f);
    projected = mix(projected, minimum + (peak - minimum) * onHueLine, gamutWeight);
  }

  // Share small differences between the spatial color and the projection.
  // Beyond 1% of the input span, retain at most half that uncertainty.
  float3 correction = projected - adjusted;
  float distance = max(abs(correction.r), max(abs(correction.g), abs(correction.b)));
  float weight = 0.5f + 0.5f * max(1.0f - 0.01f * p3Span / max(distance, 1e-8f), 0.0f);
  return adjusted + correction * weight;
}

// Estimate the pixel's position in each of the four Gaussian neighborhoods.
// Their first two log-luminance moments already exist on the spatial guide.
static float3 highlightLossByToneRank(float3 rgb, float3 adjusted, float4 means,
  float4 secondMoments, float detailFraction, float luminanceWeight) {
  float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
  float code = toneEncode(float3(y)).r;
  float logY = 1.0f + log(max(y, 1e-4f)) / 9.3f;
  // A five-percent encoded-luminance width stabilizes the rank on flat tones.
  float width = 0.05f / max((code + 0.055f) * (9.3f / 2.4f), 0.05f);
  float4 variance = max(secondMoments - means * means, 0.0f);
  float4 z = (logY - means) * rsqrt(variance + width * width);
  float4 ranks = 1.0f / (1.0f + exp(-1.7f * z)) - 0.5f;

  // The −50 reference pairs give one fine-detail weight, one 4-to-16-pixel
  // weight and three tone-dependent weights for the 64-to-256-pixel change.
  float regional = mix(mix(0.778241063f, 0.310433335f, saturate(2.0f * code)),
    -0.046310170f, saturate(2.0f * code - 1.0f));
  float retained = 0.640500503f * saturate(detailFraction) * ranks.x
    + 0.054283926f * (ranks.x - ranks.y) + regional * (ranks.z - ranks.w);
  // The existing peak-channel estimate describes saturated cyan more closely.
  // Apply the rank estimate in proportion to the luminance estimate's weight.
  float3 shift = brightroom::linearP3ToROMM(rgb - adjusted) * (clamp(retained, -0.65f, 0.75f) * luminanceWeight);
  // Bound any additional loss at ProPhoto black, including colors outside P3.
  float3 room = max(brightroom::linearP3ToROMM(adjusted), 0.0f);
  return adjusted + brightroom::linearROMMToP3(max(shift, -room));
}

// Correct the loss at −50 using the pixel's local and regional contrast. Each
// ProPhoto channel takes its own fraction of that fixed correction until −50,
// then changes with its separately measured slope. Both slopes stay positive.
static float3 highlightLossInSurround(float3 rgb, float3 adjusted, float3 halfway,
  float p3Span, float nearLogMean, float regionLogMean, float sceneLogMean) {
  const float3 luminance = float3(0.2289746f, 0.6917385f, 0.0792869f);
  float3 source = clamp(brightroom::linearP3ToROMM(rgb), 0.0f, 1.0f);
  float low = min(source.r, min(source.g, source.b));
  float high = max(source.r, max(source.g, source.b));
  float y = dot(rgb, luminance);
  float3 levels = toneEncode(exp((float3(nearLogMean, regionLogMean, sceneLogMean) - 1.0f) * 9.3f));
  float2 contrast = levels.xy - float2(toneEncode(float3(y)).r, levels.z);
  contrast *= (high - low) / (high + 0.025f);
  // Fit both intervals together using the paired −50 and −100 reference exports.
  float halfGain = dot(contrast, float2(0.744363695f, 0.935574348f));
  float extraGain = dot(contrast, float2(1.635052640f, 0.037972304f));

  float3 halfColor = brightroom::linearP3ToROMM(halfway);
  float3 halfLoss = max(source - halfColor, 0.0f);
  float shift = halfGain * max(y - dot(halfway, luminance), 0.0f);
  float3 halfShift = clamp(float3(shift), -0.9f * halfLoss, max(halfColor, 0.0f));

  float3 output = brightroom::linearP3ToROMM(adjusted);
  float3 loss = max(source - output, 0.0f);
  float3 fraction = min(loss / max(halfLoss, 1e-7f), 1.0f);
  extraGain = clamp(extraGain, -0.9f, 1.5f);
  extraGain = sign(extraGain) * max(abs(extraGain) - 0.05f, 0.0f);
  float3 weakChange = halfShift * fraction;
  // Apply the measured color uncertainty at the requested strength.
  weakChange = sign(weakChange) * max(abs(weakChange) - 0.01f * p3Span, 0.0f);
  float3 change = weakChange + extraGain * max(loss - halfLoss, 0.0f);
  return adjusted - brightroom::linearROMMToP3(clamp(change, -loss, max(output, 0.0f)));
}

// Move along the source hue line from −50 toward a bounded strong endpoint.
// The odds-coordinate step was measured on neutral, −10, −25 and −50 exports.
static float2 strongHighlightBounds(float3 rgb, float2 bounds, float2 halfway, float2 spatialLoss,
  float amount, float detailFraction, float intervalGain) {
  const float level[7] = { 0.0f, 0.4f, 0.7f, 0.85f, 0.95f, 0.99f, 1.0f };
  float3 channels = brightroom::linearP3ToROMM(rgb);
  float2 romm = float2(min(channels.r, min(channels.g, channels.b)), max(channels.r, max(channels.g, channels.b)));
  float span = bounds.y - bounds.x;
  float2 position = (bounds - romm.x) / max(romm.y - romm.x, 1e-7f);
  float2 location = (romm - bounds.x) / max(span, 1e-7f);
  float2 anchor = mix(halfway.x, halfway.y, location);
  float2 black = max(anchor + highlightBlackRoom, 1e-8f);
  float2 white = max(highlightWhiteLimit - anchor, 1e-8f);
  float2 odds = clamp(black / max(romm + highlightBlackRoom, 1e-8f) * ((highlightWhiteLimit - romm) / white), 0.0f, 1.0f);
  float2 rommLoss = black * white * (1.0f - odds) / (white + black * odds);
  float2 extrapolated = max(mix(rommLoss.x, rommLoss.y, position), 0.0f);
  float2 derivative = max(halfway + highlightBlackRoom, 0.0f) * max(highlightWhiteLimit - halfway, 0.0f) / (highlightWhiteLimit + highlightBlackRoom);
  float2 cross = extrapolated.yx * clamp(derivative / (derivative.yx + 0.025f), 0.0f, 8.0f);
  float chroma = span / (bounds.y + 0.05f);
  float2 speed = clamp(((bounds - halfway) / (derivative + 0.025f) - 0.35f) / 0.5f, -2.0f, 2.0f);
  float2 terms[6] = { spatialLoss, extrapolated, cross, chroma * extrapolated,
                      chroma * spatialLoss, derivative * speed * speed };
  float2 loss = spatialLoss;
  for (int c = 0; c < 2; ++c) {
    int lower = 0;
    while (lower < 5 && romm[c] > level[lower + 1]) ++lower;
    float fraction = clamp((romm[c] - level[lower]) / (level[lower + 1] - level[lower]), 0.0f, 1.0f);
    for (int i = 0; i < 6; ++i) {
      float weight = mix(strongHighlightLossWeights[lower][i][c], strongHighlightLossWeights[lower + 1][i][c], fraction);
      loss[c] += terms[i][c] * weight;
    }
  }
  // Set the full endpoint once. Its minimum can extend below P3 black until
  // the lowest ROMM channel reaches black. Keep its two P3 channels ordered.
  loss = max(loss, 0.0f) * intervalGain;
  // Where fine detail contributes to the scene variance, the weak settings
  // predict a further equal luminance step in log-odds. This relation was
  // measured on near-neutral colors and tapers as the RGB extrema separate.
  float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
  float yPosition = clamp((y - bounds.x) / max(span, 1e-7f), 0.0f, 1.0f);
  float atHalf = mix(halfway.x, halfway.y, yPosition);
  float currentLoss = mix(loss.x, loss.y, yPosition);
  if (currentLoss > 1e-7f) {
    float black = max(atHalf + highlightBlackRoom, 0.0f);
    float white = max(highlightWhiteLimit - atHalf, 1e-8f);
    float odds = clamp(black / max(y + highlightBlackRoom, 1e-8f) * (highlightWhiteLimit - y) / white, 0.0f, 1.0f);
    float expectedLoss = black * white * (1.0f - odds) / max(white + black * odds, 1e-8f);
    float gray = 1.0f - chroma;
    float texture = clamp(detailFraction * 10.0f, 0.0f, 1.0f);
    float weight = gray * gray * texture * texture * texture;
    loss *= mix(1.0f, clamp(expectedLoss / currentLoss, 0.0f, 10.0f), weight);
  }
  float lowPosition = clamp(location.x, 0.0f, 1.0f);
  float room = max(mix(halfway.x, halfway.y, lowPosition), 0.0f);
  if (lowPosition > 1e-6f) loss.y = min(loss.y, room / lowPosition);
  loss.x = min(loss.x, max(room - lowPosition * loss.y, 0.0f) / max(1.0f - lowPosition, 1e-6f));
  loss.y = min(loss.y, loss.x + max(halfway.y - halfway.x, 0.0f));
  if (span < 1e-6f) loss = float2(loss.x);
  float progress = (amount - 50.0f) / 50.0f;
  if (progress >= 1.0f) return halfway - loss;
  // Intermediate strengths interpolate the two final ROMM extrema in log-odds.
  float2 fullLoss = max(mix(loss.x, loss.y, location), 0.0f);
  float2 ratio = clamp(max(black - fullLoss, 0.0f) / black * (white / (white + fullLoss)), 0.0f, 1.0f);
  float2 partial = pow(ratio, float2(progress));
  float2 moved = black * white * (1.0f - partial) / (white + black * partial);
  float2 fraction = select(float2(progress), clamp(moved / max(fullLoss, 1e-8f), 0.0f, 1.0f), fullLoss > 1e-7f);
  return halfway - loss * mix(fraction.x, fraction.y, clamp(position, 0.0f, 1.0f));
}

// Beyond −50, the registered weak intervals determine the two measured RGB extrema.
// Each luminance knot holds low-primary, low-secondary, high-primary and high-secondary
// responses. Refit the table and ROMM range with Light/fit-strong-shadows.py.
constant float3 strongShadowHueGain[3][4] = {
  {
    float3(-0.032337725f, -0.033729547f, -0.091167140f),
    float3(-0.275241578f, -0.048475951f, 0.001211591f),
    float3(1.815934780f, 0.325281139f, 0.627507335f),
    float3(0.691202357f, 0.338261548f, -0.252576544f),
  },
  {
    float3(0.346766169f, -0.620245642f, 0.804351563f),
    float3(-0.945645619f, -0.074793030f, -0.296831794f),
    float3(-0.039517298f, -0.362466062f, -0.867643475f),
    float3(0.014996388f, -0.037935226f, -0.942458631f),
  },
  {
    float3(0.358657913f, 0.385380336f, 0.723078757f),
    float3(0.993600979f, 0.431901877f, 0.065741239f),
    float3(-1.344565895f, -0.232409923f, -1.113508478f),
    float3(-0.127463098f, -2.016115834f, 1.164390528f),
  },
};

// Continue from the same signed −50 color for every amount. Finite white headroom
// prevents a small measured loss near white from becoming a large loss at −100.
static float2 strongShadowBounds(float3 rgb, float2 bounds, float2 halfway, float amount) {
  float span = bounds.y - bounds.x;
  float3 channels = brightroom::linearP3ToROMM(rgb);
  float2 romm = float2(min(channels.r, min(channels.g, channels.b)), max(channels.r, max(channels.g, channels.b)));
  float2 anchor = halfway.x + (romm - bounds.x) * ((halfway.y - halfway.x) / max(span, 1e-6f));
  float2 fromBlack = max(anchor + shadowBlackRoom, 1e-8f);
  float2 fromWhite = max(shadowWhiteLimit - anchor, 1e-8f);
  float2 oddsRatio = clamp((fromBlack / max(romm + shadowBlackRoom, 1e-8f))
    * ((shadowWhiteLimit - romm) / fromWhite), 0.0f, 1.0f);
  // The odds of each ROMM channel change by a constant factor per unit slider.
  float progress = (amount - 50.0f) / 50.0f;
  float2 partial = pow(oddsRatio, float2(progress));
  float2 fullLoss = fromBlack * fromWhite * (1.0f - oddsRatio) / (fromWhite + fromBlack * oddsRatio);
  float2 loss = fromBlack * fromWhite * (1.0f - partial) / (fromWhite + fromBlack * partial);
  float2 fraction = select(float2(progress), loss / max(fullLoss, 1e-8f), fullLoss > 1e-8f);
  float2 position = (bounds - romm.x) / max(romm.y - romm.x, 1e-6f);
  float2 change = max(mix(fullLoss.x, fullLoss.y, position), 0.0f);
  if (span > 1e-6f) {
    float3 hue = (rgb - bounds.x) / (span + 0.025f);
    float3 primary = max(hue - max(hue.gbr, hue.brg), 0.0f);
    float3 secondary = min(hue.gbr, hue.brg);
    float y = dot(rgb, float3(0.22897456f, 0.69173852f, 0.07928692f));
    float knot = clamp(toneEncode(float3(y)).r, 0.0f, 1.0f) * 2.0f;
    int lower = min(int(knot), 1);
    float2 gain;
    for (int bound = 0; bound < 2; ++bound) {
      int index = bound * 2;
      float3 primaryGain = mix(strongShadowHueGain[lower][index], strongShadowHueGain[lower + 1][index], knot - lower);
      float3 secondaryGain = mix(strongShadowHueGain[lower][index + 1], strongShadowHueGain[lower + 1][index + 1], knot - lower);
      gain[bound] = dot(primaryGain, primary) + dot(secondaryGain, secondary);
    }
    // The −100 color lattice loses more at both extrema as the source's RGB
    // span increases. This scales only the loss beyond the fixed −50 color.
    gain += 0.258084395f * span;
    change *= clamp(1.0f + gain * (span / (bounds.y + 0.05f)), 0.1f, 3.0f);
    // Allow the P3 minimum below zero until its ROMM counterpart reaches black.
    // Bound the full interval once so output-profile clipping cannot brighten P3
    // as its other channels continue darkening.
    float minPosition = (romm.x - bounds.x) / span;
    if (minPosition > 0.0f && minPosition < 1.0f) {
      float room = max(anchor.x, 0.0f);
      change.y = min(change.y, room / minPosition);
      change.x = min(change.x, max(room - minPosition * change.y, 0.0f) / (1.0f - minPosition));
    }
  }
  // Extending the final loss into P3 keeps the source hue. Each fixed endpoint
  // takes the nearest measured fraction, so every intermediate channel darkens.
  return halfway - change * mix(fraction.x, fraction.y, clamp(position, 0.0f, 1.0f));
}

// Relative to the +50 response, measured on the same gray ramp at +10 and +25.
// The darker end responds more slowly to small positive Shadows adjustments.
static float weakShadowStrength(float encoded, float amount) {
  const float2 gains[9] = {
    float2(.1419112f, .4027110f), float2(.1623261f, .4400954f), float2(.1803785f, .4686682f),
    float2(.1875834f, .4802433f), float2(.1954587f, .4933873f), float2(.2011609f, .5018626f),
    float2(.2021028f, .5033011f), float2(.2021975f, .5034392f), float2(.2020864f, .5029868f)
  };
  float position = clamp(encoded, 0.0f, 1.0f) * 8.0f;
  int lower = min(int(position), 7);
  float2 anchors = mix(gains[lower], gains[lower + 1], position - float(lower));
  if (amount <= 10.0f) return anchors.x * (amount / 10.0f);
  if (amount <= 25.0f) return mix(anchors.x, anchors.y, (amount - 10.0f) / 15.0f);
  return mix(anchors.y, 1.0f, (amount - 25.0f) / 25.0f);
}

// Positive and negative Shadows on photographs closely follow opposite steps in
// linear ProPhoto log odds. Interpolate the chart and photographic rates across
// their measured contrast ranges. Both extrema then use the same per-pixel step.
static float sceneShadowRate(float luminance, float contrast, float relativeBrightness, float sceneBrightness) {
  const float3 rates[4] = {
    float3(0.05431629f, 0.74107971f, -1.54934797f),
    float3(-0.02048850f, 1.52541127f, -1.45856439f),
    float3(0.00345127f, 0.88298061f, -0.19859621f),
    float3(0.01895589f, -0.07851047f, 0.07643509f)
  };
  // Each row holds intercept, contrast, relative regional brightness and scene brightness.
  // Refit with fit-positive-shadow-lift.py using its --photographs argument.
  const float4 signedRates[4] = {
    float4(0.239543336f, 0.154533027f, -0.382872434f, 0.539996727f),
    float4(-0.337812676f, 2.171466433f, -0.978191624f, 0.754318974f),
    float4(-0.374315608f, 1.924022469f, 0.000864675f, 0.559117075f),
    float4(-0.170032101f, 0.372344523f, 0.115529560f, 0.237713354f)
  };
  float position = clamp(toneEncode(float3(luminance)).r, 0.0f, 1.0f) * 3.0f;
  int lower = min(int(position), 2);
  float knotWeight = position - float(lower);
  float3 signals = float3(1.0f, contrast, relativeBrightness);
  float chartRate = dot(mix(rates[lower], rates[lower + 1], knotWeight), signals);
  float signedRate = dot(mix(signedRates[lower], signedRates[lower + 1], knotWeight), float4(signals, sceneBrightness));
  float weight = smoothstep(0.029100908f, 0.109270319f, contrast);
  return mix(max(chartRate, 0.0f), max(signedRate, 0.0f), weight);
}

// Common limits fitted on the positive ramp and color-lattice intervals.
constant float shadowLiftBlackRoom = 0.00144708f;
constant float shadowLiftWhiteLimit = 1.16660833f;

// The positive dose lifts both measured ProPhoto endpoints before restoring hue in P3.
static float2 positiveShadowSceneBounds(float2 bounds, float2 p3Bounds, float rate, float amount) {
  // These bounds were measured between +10, +25 and +50. An equal slider
  // increment multiplies the ratio of distances to black and white.
  float2 fromBlack = bounds + shadowLiftBlackRoom;
  float2 toWhite = shadowLiftWhiteLimit - bounds;
  float ratio = exp(min(rate * amount / 50.0f, 12.0f)) - 1.0f;
  float2 lift = min(fromBlack * toWhite * ratio / (shadowLiftWhiteLimit + shadowLiftBlackRoom + fromBlack * ratio), 1.0f - bounds);
  float2 fraction = (p3Bounds - bounds.x) / (bounds.y - bounds.x);
  return p3Bounds + max(mix(lift.x, lift.y, fraction), 0.0f);
}

// A signed dose moves the two ProPhoto extrema toward black. Project their full
// loss onto the original hue once. Each outlying P3 channel follows the nearest
// extremum's fraction of that loss throughout the slider, including at clipping.
static float3 sceneShadowLoss(float3 rgb, float2 romm, float rate, float amount) {
  float2 fromBlack = romm + shadowLiftBlackRoom;
  float span = shadowLiftWhiteLimit + shadowLiftBlackRoom;
  float2 room = fromBlack * (shadowLiftWhiteLimit - romm);
  float2 exposure = 1.0f - exp(-rate * float2(2.0f, amount / 50.0f));
  float2 fullLoss = min(romm, room * exposure.x / (span - fromBlack * exposure.x));
  float2 partial = min(romm, room * exposure.y / (span - fromBlack * exposure.y));
  float2 progress = select(float2(amount / 100.0f), partial / max(fullLoss, 1e-8f), fullLoss > 1e-7f);
  float3 position = (rgb - romm.x) / max(romm.y - romm.x, 1e-7f);
  return max(mix(fullLoss.x, fullLoss.y, position), 0.0f) * mix(progress.x, progress.y, clamp(position, 0.0f, 1.0f));
}

// The +50 chroma change was fitted on a color cube and four colored layouts.
static float2 positiveShadowBounds(float3 rgb, float2 p3Bounds, float2 bounds,
  float2 adjusted, float2 end, bool beyondEnd) {
  const float3 coefficients = float3(0.3045109f, -0.5129123f, 0.5796594f);
  float y = dot(rgb, float3(.2289746f, .6917385f, .0792869f));
  float span = bounds.y - bounds.x;
  float relativeY = (y - bounds.x) / span;
  float2 lift = max(end - bounds, 0.0f);
  float luminanceLift = mix(lift.x, lift.y, relativeY);
  float2 p3Position = (p3Bounds - bounds.x) / span;
  if (luminanceLift <= 1e-7f) {
    float2 currentLift = max(adjusted - bounds, 0.0f);
    return p3Bounds + mix(currentLift.x, currentLift.y, clamp(p3Position, 0.0f, 1.0f));
  }
  float3 response = float3(luminanceLift / (y + .01f), (lift.y - lift.x) / span,
                           max(lift.x, lift.y) / (bounds.y + .01f));
  // A shared change of RGB span leaves luminance and hue intact. Bound both extrema
  // together so a positive Shadows adjustment continues to lift every component.
  float spanChange = max(dot(coefficients, response), -(end.y - end.x) / span);
  float2 change = (bounds - y) * spanChange;
  float2 room = select(1.0f - end, lift, change < 0.0f);
  float2 limit = room / max(abs(change), 1e-9f);
  float2 correctedEnd = end + min(1.0f, min(limit.x, limit.y)) * change;
  correctedEnd.y = max(correctedEnd.x, correctedEnd.y);
  // Preserve hue by moving both P3 extrema. A common RGB slope and gray
  // offset commute with the linear conversion between ROMM and P3.
  float2 p3Lift = max(mix(correctedEnd.x, correctedEnd.y, p3Position) - p3Bounds, 0.0f);
  if (beyondEnd) {
    // Beyond the +50 calibration, extend the nearest measured increment to
    // outlying P3 channels. Extrapolating its slope can reverse a channel's lift.
    float2 increment = max(adjusted - end, 0.0f);
    return p3Bounds + p3Lift + mix(increment.x, increment.y, clamp(p3Position, 0.0f, 1.0f));
  }
  float2 currentLift = max(adjusted - bounds, 0.0f);
  float progress = clamp(mix(currentLift.x, currentLift.y, relativeY) / luminanceLift, 0.0f, 1.0f);
  return p3Bounds + p3Lift * progress;
}

// The −50 measurements distinguish brighter and darker neighboring peak channels.
// Two distance bands contribute separately, with weights interpolated in source luminance.
static float2 toneHighlightSurroundResponse(float encodedY, float4 coverage) {
  const float4 light[3] = {
    float4(0.01247639f, 0.01894382f, 0.00210942f, -0.01948474f),
    float4(-0.02651141f, -0.04015499f, 0.00260472f, 0.02810989f),
    float4(0.00442627f, -0.05631761f, 0.00002182f, -0.04972393f)
  };
  const float4 chroma[3] = {
    float4(0.00615479f, 0.00149242f, 0.01397578f, -0.03720251f),
    float4(0.04646940f, 0.00430229f, -0.00313148f, -0.00237232f),
    float4(0.01615819f, 0.00292097f, 0.00389136f, 0.00973246f)
  };
  float position = clamp(encodedY, 0.0f, 1.0f) * 2.0f;
  int i = min(int(position), 1);
  float f = position - float(i);
  return float2(dot(mix(light[i], light[i + 1], f), coverage),
                dot(mix(chroma[i], chroma[i + 1], f), coverage));
}

extern "C" { namespace coreimage {
  float4 brightroomToneLuminance(sample_t source, float control) {
    float3 rgb = clamp(unpremultiply(source).rgb, 0.0f, 1.0f);
    float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
    float x = log(max(y, 1e-4f)) / 9.3f + 1.0f;
    float range = control == 0.0f || control == 2.0f ? toneRangeSample(toneEncode(float3(y)).r, control == 0.0f) : 0.0f;
    return float4(x, x * x, range, 1.0f) * source.a;
  }

  float4 brightroomToneDeviations(sampler guide, sampler blurred, sampler meanImage) {
    float4 source = sample(guide, samplerCoord(guide));
    float4 average = sample(meanImage, samplerTransform(meanImage, float2(0.5f)));
    float mean = average.r / max(average.a, 1e-8f);
    float difference = source.r / max(source.a, 1e-8f) - mean;
    float4 smoothed = sample(blurred, samplerCoord(blurred));
    float smoothDifference = smoothed.r / max(smoothed.a, 1e-8f) - mean;
    return float4(mean, difference * difference, smoothDifference * smoothDifference, 1.0f) * source.a;
  }

  float4 brightroomHighlightColorGains(sampler statistics, destination dest) {
    float3 stats = toneGuideAt(statistics, float2(0.5f));
    float2 grid = (dest.coord() - 0.5f) / 32.0f;
    float change = toneHighlightGainAt(grid.x, grid.y * 6.0f - 3.0f, float2(stats.r, sqrt(max(stats.g, 0.0f))));
    // Separate signs preserve small values when the intermediate is rendered at half precision.
    return float4(max(change, 0.0f), max(-change, 0.0f), 0.0f, 1.0f);
  }

  // One 4-by-4 image per render. Columns are encoded luminance knots, rows
  // are the intercept, two chroma coordinates and the relative -50 loss.
  float4 brightroomShadowColorGains(sampler statistics, destination dest) {
    float3 stats = toneGuideAt(statistics, float2(0.5f));
    float2 scene = float2(stats.r, sqrt(max(stats.g, 0.0f)));
    float2 distribution = clamp((scene - float2(0.74f, 0.12f)) / float2(0.12f, 0.07f), -3.0f, 3.0f);
    int2 index = clamp(int2(dest.coord()), int2(0), int2(3));
    float2 gains = float2(0.0f);
    for (int i = 0; i < 5; ++i) {
      float2 d = distribution - shadowSceneCenters[i];
      float weight = exp(-dot(d, d) / 0.605f);
      gains += weight * float2(shadowLossCoefficients[i][index.x][index.y],
                               shadowLossCoefficients[i][index.x + 4][index.y]);
    }
    // The shared offset keeps both signed coefficients in an opaque RGB texel.
    // Subtracting blue after interpolation recovers their signed values.
    float offset = max(0.0f, -min(gains.x, gains.y));
    return float4(gains + offset, offset, 1.0f);
  }

  float4 brightroomSpatialTone(sampler inputImage, sampler blur4, sampler blur16,
    sampler blur64, sampler blur256, sampler statistics, sampler table, sampler toneTableImage, sampler meanImage, sampler colorGains,
    sampler neighborColors, sampler neighborResponse, sampler sceneTone, float guideScale, float control, float strength, float sliderAmount, float4 negativeInterval,
    float count, float inverseWidthSquared, float neighborScale,
    destination dest) {
    float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0f) return source;
    float4 rawStats = sample(statistics, samplerTransform(statistics, float2(0.5f)));
    float3 stats = rawStats.rgb / max(rawStats.a, 1e-8f);
    float activity = sqrt(max(stats.b, 0.0f));
    // Ignore round-off in constant fields, including half-float previews.
    if (activity < 0.001f) return source;
    float2 position = dest.coord() * guideScale;
    float3 b16 = toneGuideAt(blur16, position);
    float3 b64 = toneGuideAt(blur64, position);
    float3 b4 = toneGuideAt(blur4, position);
    float3 first = float3(0.0f, b4.r, b16.r);
    float3 b256 = toneGuideAt(blur256, position);
    float3 second = float3(b64.r, b256.r, sqrt(max(b16.g - b16.r * b16.r, 0.0f)));
    float4 surround = float4(first.yz, second.xy);
    float4 range = float4(b16.b, b64.b, b256.b, toneGuideAt(meanImage, float2(0.5f)).b);
    float3 third = float3(sqrt(max(b64.g - b64.r * b64.r, 0.0f)), stats.r, sqrt(max(stats.g, 0.0f)));
    float3 mean0 = toneTable(table, 0, 0);
    float3 scale0 = toneTable(table, 0, 1);
    first = (first - mean0) * scale0;
    second = (second - toneTable(table, 1, 0)) * toneTable(table, 1, 1);
    third = (third - toneTable(table, 2, 0)) * toneTable(table, 2, 1);
    float3 original = unpremultiply(source).rgb;
    float3 rgb = clamp(original, 0.0f, 1.0f);
    float2 p3Bounds = float2(min(rgb.r, min(rgb.g, rgb.b)), max(rgb.r, max(rgb.g, rgb.b)));
    // Negative Light and positive Shadows can take a P3 color beyond its
    // original gamut. The spatial guides retain their P3 luminance meaning.
    float2 romm = p3Bounds;
    float2 bounds = p3Bounds;
    float gamutWeight = 0.0f;
    float belowBlackRatio = 0.0f;
    if (control != 1.0f && p3Bounds.y - p3Bounds.x > 1e-6f) {
      float3 channels = clamp(brightroom::linearP3ToROMM(rgb), 0.0f, 1.0f);
      romm = float2(min(channels.r, min(channels.g, channels.b)), max(channels.r, max(channels.g, channels.b)));
      if (control == 3.0f) {
        bounds = romm;
      } else {
        // For 95% of the -50 lattice colors below -0.005 in P3, the source
        // minimum is within 0.38 (Highlights) or 0.24 (Shadows) of this gap.
        float margin = 0.4f * (romm.x - p3Bounds.x);
        if (margin > p3Bounds.x) {
          gamutWeight = 1.0f - smoothstep(0.0f, margin, p3Bounds.x);
          // On the source hue line, this much P3 minimum can go below zero
          // per unit of P3 peak before the lowest ProPhoto channel reaches zero.
          belowBlackRatio = (romm.x - p3Bounds.x) / max(p3Bounds.y - romm.x, 1e-7f);
        }
      }
    }
    // Negative Shadows measures one encoded adjustment at the pixel's luminance.
    // Sharing it across the two extrema keeps saturated colors on the measured tone response.
    float2 toneInput = bounds;
    if (control == 2.0f && bounds.y - bounds.x > 1e-6f) {
      toneInput = float2(dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f)));
    }
    float2 coordinate = ((log(max(toneInput, 1e-4f)) / 9.3f + 1.0f) - mean0.r) * scale0.r;
    float2 delta = float2(0.0f);
    for (int i = 0; i < int(count); ++i) {
      float3 c0 = toneTable(table, 0, float(i) + 2.0f);
      float3 d0 = first - c0;
      float3 d1 = second - toneTable(table, 1, float(i) + 2.0f);
      float3 d2 = third - toneTable(table, 2, float(i) + 2.0f);
      float contextDistance = dot(d0.gb, d0.gb) + dot(d1, d1) + dot(d2, d2);
      float2 d = coordinate - c0.r;
      float3 weights = toneTable(table, 3, float(i) + 2.0f);
      float weight = control < 2.5f ? weights[int(control)] : toneTable(table, 4, float(i) + 2.0f).r;
      delta += weight * exp(-(d * d + contextDistance) * inverseWidthSquared);
    }
    if (neighborScale > 0.0f) {
      // Lift the fixed −50 measurement to the source pixel before evaluating
      // its slider curve. Color agreement prevents an edge on the guide grid
      // from imposing a neighboring color's adjustment on full-resolution detail.
      float2 p = dest.coord() * neighborScale - 0.5f;
      float2 origin = floor(p) + 0.5f;
      float2 fraction = fract(p);
      float3 code = toneEncode(rgb);
      float correction = 0.0f;
      float coverage = 0.0f;
      float spanCorrection = 0.0f;
      for (int i = 0; i < 4; ++i) {
        float2 offset = float2(i % 2, i / 2);
        float2 samplePoint = origin + offset;
        float4 color = sample(neighborColors, samplerTransform(neighborColors, samplePoint));
        float2 w = mix(1.0f - fraction, fraction, offset);
        float area = w.x * w.y * color.a;
        float3 distance = code - color.rgb / max(color.a, 1e-8f);
        float3 change = toneGuideAt(neighborResponse, samplePoint);
        float weight = area * exp(-dot(distance, distance) * toneNeighborFalloff(control));
        correction += weight * (change.r - change.g);
        if (control == 0.0f) spanCorrection += weight * (change.b - 0.125f);
        coverage += area;
      }
      // Convert the luminance adjustment into an encoded change at each RGB
      // extremum using x times the local derivative of the transfer function.
      // Shadows already evaluates its signed response at the pixel's luminance.
      float2 responseScale = float2(1.0f);
      if (control == 0.0f) {
        float3 linear = float3(bounds, dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f)));
        float3 encoded = toneEncode(linear);
        float3 scale = select((encoded + 0.055f) / 2.4f, encoded, linear <= 0.0031308f);
        responseScale = scale.xy / max(scale.z, 1e-7f);
        // The color correction changes the two extrema about the source luminance.
        delta += responseScale * (bounds - linear.z) / (bounds.y - bounds.x + 0.05f)
          * (spanCorrection / (max(coverage, 1e-8f) * negativeInterval.y));
      }
      delta += responseScale * 1.5f * correction / (max(coverage, 1e-8f) * negativeInterval.y);
    }
    float direction = (control == 0.0f || control == 2.0f) ? -1.0f : 1.0f;
    float2 encoded = toneEncode(float3(bounds, 0.0f)).rg;
    // The strong Highlights interval uses a fixed spatial endpoint at −100.
    if (control == 0.0f && sliderAmount > 50.0f) strength = negativeInterval.z;
    float2 gain = float2(strength);
    if (control == 3.0f && sliderAmount < 50.0f) {
      gain = float2(weakShadowStrength(encoded.x, sliderAmount), weakShadowStrength(encoded.y, sliderAmount));
    }
    float2 unitResponse = direction * max(direction * delta, 0.0f);
    float activityWeight = min(activity / 0.015f, 1.0f);
    delta = unitResponse * gain * activityWeight;
    float2 adjusted = toneDecode(clamp(encoded + delta, 0.0f, 1.0f));
    float2 neighborhoodScene = float2(stats.r, sqrt(max(stats.g, 0.0f)));
    float2 at50 = bounds;
    float2 at100 = bounds;
    float2 weakLossFraction = 0.0f;
    if (control == 0.0f) {
      float2 scene = clamp(float2(stats.r, activity), 0.0f, float2(1.0f, 0.5f));
      float gain = sample(toneTableImage, samplerTransform(toneTableImage, scene * 64.0f + 0.5f)).r;
      // The scene-dependent gain calibrates the -50 endpoint from the base
      // model's -25 to -50 increment. A tiny slider amount can round to zero.
      bool belowEnd = sliderAmount < 50.0f;
      float2 unitDelta = belowEnd ? unitResponse * activityWeight : delta / strength;
      float2 start = toneDecode(clamp(encoded + unitDelta * negativeInterval.x, 0.0f, 1.0f));
      float2 end = toneDecode(clamp(encoded + unitDelta * negativeInterval.y, 0.0f, 1.0f));
      bool beyondEnd = strength > negativeInterval.y;
      if (strength > negativeInterval.x) {
        adjusted = clamp(adjusted + (gain - 1.0f) * ((beyondEnd ? end : adjusted) - start), 0.0f, 1.0f);
      }
      if (gamutWeight > 0.0f) {
        at100 = clamp(toneDecode(clamp(encoded + unitDelta * negativeInterval.z, 0.0f, 1.0f))
          + (gain - 1.0f) * (end - start), 0.0f, 1.0f);
      }
      end = clamp(start + gain * (end - start), 0.0f, 1.0f);
      start.y = max(start.y, start.x);
      end.y = max(end.y, end.x);
      adjusted.y = max(adjusted.y, adjusted.x);
      float progress = (strength - negativeInterval.x) / (negativeInterval.y - negativeInterval.x);
      float2 firstStep = toneDecode(clamp(encoded + unitDelta * negativeInterval.w, 0.0f, 1.0f));
      firstStep.y = max(firstStep.x, firstStep.y);
      adjusted = toneBetweenAnchors(rgb, bounds, adjusted, start, end,
        surround, neighborhoodScene, range, colorGains, true, firstStep, ShadowTone{}, progress, sliderAmount, neighborScale > 0.0f, at50, weakLossFraction);
      if (neighborScale > 0.0f) {
        float detailFraction = 1.0f - stats.b / max(stats.g, 1e-8f);
        shareHighlightLoss(sceneTone, rgb, bounds, sliderAmount, detailFraction, gamutWeight,
          b4.rg, b64.rg, max(sqrt(max(stats.g, 0.0f)), 0.04f), adjusted, at50);
        // Dark neighbors reduce the measured loss more for colorful pixels.
        // Neutral pixels retain part of that protection in predominantly dark scenes.
        float chroma = min(8.0f * (bounds.y - bounds.x), 1.0f);
        float darkScene = smoothstep(0.0f, 0.125f, range.w);
        float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
        float surroundingDark = clamp(b4.b - toneRangeSample(toneEncode(float3(y)).r, true), 0.0f, 0.5f);
        float retained = surroundingDark * mix(0.2f * darkScene, 1.0f, chroma) * (1.0f - gamutWeight);
        // Scene sharing scales each channel's weak loss by its −50 loss.
        // Contract only the additional loss beyond that channel's −25 anchor.
        float2 laterShare = 1.0f - weakLossFraction;
        float2 correction = min(float2(retained), laterShare);
        if (sliderAmount > 25.0f && sliderAmount < 50.0f) {
          float2 weak = mix(bounds, at50, weakLossFraction);
          adjusted += max(weak - adjusted, 0.0f) * (correction / max(laterShare, 1e-8f));
        } else if (sliderAmount >= 50.0f) {
          adjusted = mix(adjusted, bounds, correction);
        }
        at50 = mix(at50, bounds, correction);
      }
      if (gamutWeight > 0.0f) at100 = clamp(at50 + (at100 - end), 0.0f, 1.0f);
    } else if (control == 2.0f && strength > 0.0f) {
      float2 end = toneDecode(clamp(encoded + (delta / strength) * negativeInterval.y, 0.0f, 1.0f));
      ShadowTone shadowTone{};
      if (neighborScale > 0.0f) {
        float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
        float code = toneEncode(float3(y)).r;
        float2 scene = sceneToneLossAtCode(sceneTone, code);
        // Smooth gradients retain the local response. In detailed images the
        // same source tone at distant locations often has the same measured loss.
        float detail = 1.0f - stats.b / max(stats.g, 1e-8f);
        float confidence = smoothstep(0.0f, 0.05f, detail) * smoothstep(0.0f, 2.0f / 2048.0f, scene.y);
        // Equal source colors can still differ in darker regions. Strengthen
        // the shared loss in a dark neighborhood in proportion to its and the
        // scene's shadow coverage. Broad dark regions retain the local endpoint.
        float sigma = max(sqrt(max(stats.g, 0.0f)), 0.04f);
        float localShade = smoothstep(0.0f, sigma, stats.r - b16.r);
        float regionalShade = smoothstep(0.0f, sigma, stats.r - b256.r);
        // At −50 the measured loss extends across midtones. Share a quarter of
        // the loss at the scene's geometric mean, fading toward bright, distant
        // tones and when too few scene samples support that mean.
        float middleCode = toneEncode(float3(exp((stats.r - 1.0f) * 9.3f))).r;
        float2 middle = sceneToneLossAtCode(sceneTone, middleCode);
        float middleWeight = 0.25f * smoothstep(0.0f, 2.0f / 2048.0f, middle.y)
          * (1.0f - smoothstep(0.0f, 1.0f, code - middleCode));
        // A broad field already supplies its own loss. Fade out borrowing as
        // an eighth to half of the scene contributes to this pixel's tone.
        middleWeight *= 1.0f - smoothstep(0.125f, 0.5f, scene.y);
        float loss = mix(scene.x, middle.x, middleWeight)
          * (1.0f + 0.3f * localShade * clamp(range.x * range.w, 0.0f, 1.0f));
        confidence *= 1.0f - regionalShade;
        shadowTone.sceneLuminance = y - loss;
        shadowTone.sceneWeight = confidence * (1.0f - gamutWeight);

        // Equal dark tones retain more light when their immediate surroundings
        // are brighter. Evaluate the same contrast at every slider position.
        float logY = 1.0f + log(max(y, 1e-4f)) / 9.3f;
        float dark = 1.0f - smoothstep(0.18f, 0.45f, code);
        float variance = max(b4.g - b4.r * b4.r, 0.0f);
        float lowVariance = 0.0064f / (variance + 0.0064f);
        // Convert the change in log odds to linear luminance at this input tone.
        float room = (y + shadowBlackRoom) * (shadowWhiteLimit - y) / (shadowWhiteLimit + shadowBlackRoom);
        float contrast = (logY - b4.r) * (0.377153054f * dark + 0.241945202f * lowVariance);
        shadowTone.localLoss = contrast * room * dark * smoothstep(0.001f, 0.013f, activity) * (1.0f - gamutWeight);
      }
      adjusted = toneBetweenAnchors(rgb, bounds, adjusted, bounds, end, surround, neighborhoodScene, range, colorGains, false, float2(0.0f), shadowTone,
        strength / negativeInterval.y, sliderAmount, false, at50, weakLossFraction);
      if (gamutWeight > 0.0f) at100 = negativeStrengthBounds(rgb, bounds, at50, 100.0f, false);
    } else if (control == 3.0f && bounds.y - bounds.x > 1e-6f) {
      float2 end = toneDecode(clamp(encoded + unitResponse * activityWeight, 0.0f, 1.0f));
      end.y = max(end.x, end.y);
      adjusted.y = max(adjusted.x, adjusted.y);
      adjusted = positiveShadowBounds(rgb, p3Bounds, bounds, adjusted, end, sliderAmount > 50.0f);
      float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
      // Both guides contain normalized log luminance. Compare their geometric
      // means in encoded Display P3 so the contrast signal is in measured units.
      float2 levels = exp((float2(b64.r, stats.r) - 1.0f) * 9.3f);
      float2 region = toneEncode(float3(levels, 0.0f)).xy;
      float rate = sceneShadowRate(y, neighborhoodScene.y, region.x - region.y, region.y);
      float2 sceneBounds = positiveShadowSceneBounds(bounds, p3Bounds, rate * activityWeight, sliderAmount);
      float chroma = (bounds.y - bounds.x) / (bounds.y + 0.025f);
      // On colors whose luminance lies near the upper extremum, the spatial
      // measurement of the bright channel retains more of its lift.
      float relativeLuminance = (y - bounds.x) / (bounds.y - bounds.x);
      float2 minimum = p3Bounds + smoothstep(0.15f, 0.65f, relativeLuminance) * (adjusted - p3Bounds);
      adjusted = mix(adjusted, max(sceneBounds, minimum), smoothstep(0.15f, 0.95f, chroma) * chroma);
      bounds = p3Bounds;
    }
    if (gamutWeight > 0.0f) {
      // On the color lattice the low channel follows the luminance loss for
      // Highlights and the peak loss for Shadows. Keep the calibrated P3 peak.
      // A floor derived from the fixed −100 peak keeps the minimum in gamut
      // for the entire slider. A moving floor could brighten it near −100.
      float loss = p3Bounds.y - adjusted.y;
      float floor = -belowBlackRatio * max(at100.x, at100.y);
      if (control == 0.0f) {
        float inputY = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
        float fraction = (inputY - p3Bounds.x) / (p3Bounds.y - p3Bounds.x);
        loss = inputY - mix(adjusted.x, adjusted.y, fraction);
        // The full-resolution response uses this same −50 color at every strength.
        if ((neighborScale > 0.0f && gamutWeight < 1.0f) || sliderAmount > 50.0f) {
          float halfLoss = inputY - mix(at50.x, at50.y, fraction);
          float lowAt50 = max(floor, at50.x - belowBlackRatio * max(halfLoss, 0.0f));
          at50.x = mix(at50.x, lowAt50, gamutWeight);
        }
      }
      float low = max(floor, adjusted.x - belowBlackRatio * max(loss, 0.0f));
      adjusted.x = mix(adjusted.x, low, gamutWeight);
    }
    if (control == 2.0f && sliderAmount > 50.0f) {
      adjusted = strongShadowBounds(rgb, p3Bounds, adjusted, sliderAmount);
    }
    adjusted.y = max(adjusted.y, adjusted.x);
    // Interpolate the middle P3 channel to preserve RGB hue.
    float slope = (adjusted.y - adjusted.x) / max(bounds.y - bounds.x, 1e-6f);
    float3 output = adjusted.x + (rgb - bounds.x) * slope;
    if (control == 0.0f && sliderAmount > 50.0f && p3Bounds.y - p3Bounds.x > 1e-6f) {
      // Scale only the additional RGB loss from the fixed -50 color. Positive
      // multipliers preserve the direction of each channel throughout the interval.
      float span = p3Bounds.y - p3Bounds.x;
      float3 halfway = at50.x + (rgb - p3Bounds.x) * (max(at50.y - at50.x, 0.0f) / span);
      float chroma = span / (p3Bounds.y + 0.05f);
      const float3 strongChroma = float3(0.071357575f, -0.007663829f, -0.053735796f);
      float3 response = strongChroma * (chroma * (rgb / p3Bounds.y));
      output += response * (output - halfway);
    }
    if (control == 0.0f && sliderAmount > 50.0f) {
      float2 full = float2(min(output.r, min(output.g, output.b)), max(output.r, max(output.g, output.b)));
      // The fraction of log-luminance variance lost in the first Gaussian
      // distinguishes fine image detail from a smooth tone ramp.
      float detailFraction = 1.0f - stats.b / max(stats.g, 1e-8f);
      // Scale the spatial part of the −50 to −100 step using the spread of
      // log luminance in the scene and in this region. The odds-based step
      // for textured gray and the fixed −50 endpoint retain their own weights.
      float sceneDeviation = sqrt(max(stats.g, 0.0f));
      float regionDeviation = sqrt(max(b256.g - b256.r * b256.r, 0.0f));
      float4 distribution = float4(1.0f, min(5.0f * sceneDeviation, 1.0f),
        clamp(6.0f * detailFraction, 0.0f, 1.0f), min(regionDeviation / max(sceneDeviation, 0.04f), 2.0f));
      float intervalGain = clamp(1.0f + dot(distribution,
        float4(-0.07465879f, -0.06544599f, -0.32224240f, 0.28705601f)), 0.0f, 3.0f);
      float2 end = strongHighlightBounds(rgb, p3Bounds, at50, max(at50 - full, 0.0f),
        sliderAmount, detailFraction, intervalGain);
      float3 position = (rgb - p3Bounds.x) / max(p3Bounds.y - p3Bounds.x, 1e-6f);
      float3 fitted = mix(end.x, end.y, position);
      // Preserve the measured RGB endpoint where negative Highlights extend below
      // P3 black. Interpolate from the same −50 color throughout this interval.
      float3 halfway = mix(at50.x, at50.y, position);
      float3 spatial = mix(halfway, min(halfway, output), (sliderAmount - 50.0f) / 50.0f);
      output = mix(fitted, spatial, gamutWeight);
    }

    if (control == 0.0f && neighborScale > 0.0f) {
      float span = p3Bounds.y - p3Bounds.x;
      if (span > 1e-6f) {
        if (gamutWeight < 1.0f) {
          float3 halfway = at50.x + (rgb - p3Bounds.x) * (max(at50.y - at50.x, 0.0f) / span);
          float3 corrected = highlightLossInSurround(rgb, output, halfway, span, b4.r, b64.r, stats.r);
          output += (corrected - output) * (1.0f - gamutWeight);
        }
        // The small metering pass supplies a luminance loss. Resolve color
        // once, on the full-resolution pixel after the final spatial shift.
        output = separatedHighlightColor(rgb, output, span, gamutWeight);
      }
      if (gamutWeight < 1.0f) {
        output = highlightLossByToneRank(rgb, output, float4(b4.r, b16.r, b64.r, b256.r),
          float4(b4.g, b16.g, b64.g, b256.g), 1.0f - stats.b / max(stats.g, 1e-8f), 1.0f - gamutWeight);
      }
    }
    if (control == 2.0f && neighborScale > 0.0f && p3Bounds.y - p3Bounds.x > 1e-6f) {
      float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
      float2 levels = exp((float2(b64.r, stats.r) - 1.0f) * 9.3f);
      float2 region = toneEncode(float3(levels, 0.0f)).xy;
      float rate = sceneShadowRate(y, neighborhoodScene.y, region.x - region.y, region.y) * activityWeight;
      float3 loss = sceneShadowLoss(rgb, romm, rate, sliderAmount);
      float chroma = (romm.y - romm.x) / (romm.y + 0.025f);
      // The spatial −50 fit retains most of the response. Its error in
      // saturated colors partly cancels the independent signed-rate estimate.
      float weight = 0.25f * chroma;
      output = mix(output, rgb - loss, weight);
    }
    if (control == 2.0f && neighborScale > 0.0f) {
      // In a brighter surround, Lightroom retains some of the pixel's light.
      // Measure contrast in encoded luminance and reduce the whole RGB loss
      // by the same fraction at every strength. Fit from the −50 reference pairs.
      float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
      float2 levels = toneEncode(float3(y, exp((b16.r - 1.0f) * 9.3f), 0.0f)).xy;
      float protection = 0.186815302f * saturate(levels.y - levels.x);
      output = mix(output, rgb, protection);
    }
    // Extend the boundary adjustment to HDR values without clipping the input.
    return premultiply(float4(output + original - rgb, source.a));
  }

  // The guides hold encoded source color and the signed linear luminance loss.
  // Keeping the loss separate lets the full-resolution pixel retain its detail.
  float4 brightroomToneNeighborColor(sample_t source) {
    return premultiply(float4(toneEncode(clamp(unpremultiply(source).rgb, 0.0f, 1.0f)), source.a));
  }

  float4 brightroomToneNeighborLoss(sample_t source, sample_t adjusted) {
    const float3 luminance = float3(0.2289746f, 0.6917385f, 0.0792869f);
    float3 original = unpremultiply(source).rgb;
    float y = dot(clamp(original, 0.0f, 1.0f), luminance);
    float loss = dot(original - unpremultiply(adjusted).rgb, luminance);
    return float4(max(loss, 0.0f), max(-loss, 0.0f), y, 1.0f) * source.a;
  }

  // Each column represents one encoded-luminance bin. Accumulate loss and
  // support separately so a transparent or unrepresented tone has no influence.
  float4 brightroomSceneToneRows(sampler losses, float4 guideRect, destination dest) {
    float code = dest.coord().x / 128.0f;
    float row = floor(dest.coord().y);
    float3 sums = float3(0.0f);
    for (int i = 0; i < 64; ++i) {
      // Stagger the 64 × 32 strata to avoid sampling only one phase of a repeated texture.
      float2 jitter = fract(float2(i * 0.41421356f + row * 0.61803399f,
        row * 0.41421356f + i * 0.61803399f) + 0.5f);
      float2 position = guideRect.xy + floor((float2(i, row) + jitter) / float2(64.0f, 32.0f) * guideRect.zw) + 0.5f;
      float4 value = sample(losses, samplerTransform(losses, position));
      float3 data = unpremultiply(value).rgb;
      float distance = (toneEncode(float3(data.b)).r - code) / 0.02f;
      float weight = value.a * exp(-0.5f * distance * distance);
      sums += float3(weight * (data.r - data.g), weight, value.a);
    }
    return float4(sums / 64.0f, 1.0f);
  }

  // Summarize the 128 alpha-weighted luminance bins in one texel shared by every pixel.
  float4 brightroomHighlightSceneQuantiles(sampler table, destination dest) {
    if (dest.coord().x < 128.0f) return sample(table, samplerCoord(table));
    float total = 0.0f;
    for (int i = 0; i < 128; ++i) {
      total += toneGuideAt(table, float2(float(i) + 0.5f, 0.5f)).g;
    }
    float4 remaining = total * float4(0.25f, 0.75f, 0.95f, 0.98f);
    float4 level = float4(0.0f);
    float occupied = 0.0f;
    for (int i = 0; i < 128; ++i) {
      float weight = toneGuideAt(table, float2(float(i) + 0.5f, 0.5f)).g;
      // Overlap with a uniform histogram distinguishes a continuous spread
      // of tones from two distant peaks with little light between them.
      occupied += min(weight, total / 128.0f);
      level += clamp(remaining / max(weight, 1e-12f), 0.0f, 1.0f);
      remaining -= weight;
    }
    level /= 128.0f;
    float coverage = occupied / max(total, 1e-8f);
    float protection = max(level.y - level.x - 0.45f, 0.0f) * smoothstep(0.25f, 0.60f, coverage);
    return float4(level.z, level.w - level.y, protection, 1.0f);
  }

  float4 brightroomToneNeighborResponse(sampler colorGuide, sampler lossGuide,
    float radiusScale, float4 guideRect, float control, destination dest) {
    float4 source = sample(colorGuide, samplerCoord(colorGuide));
    if (source.a <= 0.0f) return source;
    float3 centerResponse = toneGuideAt(lossGuide, dest.coord());
    float centerLoss = centerResponse.r - centerResponse.g;
    float3 code = unpremultiply(source).rgb;
    float colorFalloff = toneNeighborFalloff(control);
    const float diagonal = 0.70710678f;
    const float2 direction[8] = { float2(1, 0), float2(diagonal, diagonal), float2(0, 1), float2(-diagonal, diagonal),
      float2(-1, 0), float2(-diagonal, -diagonal), float2(0, -1), float2(diagonal, -diagonal) };
    float weightSum = source.a;
    float correction = 0.0f;
    float peak = max(code.r, max(code.g, code.b));
    float4 peakCoverage = float4(0.0f);
    float2 bandWeight = float2(0.0f);
    float2 center = dest.coord();
    for (float radius = 4.0f; radius <= 256.0f; radius *= 4.0f) {
      for (int i = 0; i < 8; ++i) {
        float2 point = floor(center + radius * radiusScale * direction[i]) + 0.5f;
        point = clamp(point, guideRect.xy + 0.5f, guideRect.xy + guideRect.zw - 0.5f);
        float4 color = sample(colorGuide, samplerTransform(colorGuide, point));
        float3 difference = code - color.rgb / max(color.a, 1e-8f);
        float weight = color.a * exp(-dot(difference, difference) * colorFalloff);
        float3 other = toneGuideAt(lossGuide, point);
        correction += weight * (centerLoss - (other.r - other.g));
        if (control == 0.0f) {
          float neighborPeak = max(color.r, max(color.g, color.b)) / max(color.a, 1e-8f);
          float difference = peak - neighborPeak;
          float2 counts = color.a * smoothstep(0.0f, 0.25f, float2(difference, -difference));
          if (radius <= 16.0f) {
            peakCoverage.xy += counts;
            bandWeight.x += color.a;
          } else {
            peakCoverage.zw += counts;
            bandWeight.y += color.a;
          }
        }
        weightSum += weight;
      }
    }
    correction /= max(weightSum, 1e-8f);
    float gray = centerResponse.b - centerLoss;
    float shift = toneEncode(float3(gray + correction)).r - toneEncode(float3(gray)).r;
    float span = 0.0f;
    if (control == 0.0f) {
      peakCoverage /= max(bandWeight.xxyy, 1e-8f);
      float2 field = toneHighlightSurroundResponse(toneEncode(float3(centerResponse.b)).r, peakCoverage);
      shift += field.x / 1.5f;
      // Offset the signed color term so intermediate textures retain it at either working precision.
      span = 0.125f + field.y;
    }
    return float4(max(shift, 0.0f), max(-shift, 0.0f), span, 1.0f) * source.a;
  }
}}
#endif
