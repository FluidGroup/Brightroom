// Copyright (c) 2026 Hiroshi Kimura (Muukii)

#if defined(__METAL_CIKERNEL__)
#include <CoreImage/CoreImage.h>
#include "ColorAdjustmentWorkingSpace.metalh"
using namespace metal;

static float3 mixerEncode(float3 value) {
  return select(1.055f * pow(max(value, 0.0f), float3(1.0f / 2.4f)) - 0.055f,
    12.92f * value, value <= 0.0031308f);
}

static float3 mixerVertex(coreimage::sampler table, float3 index, float dimension, float2 offset) {
  return coreimage::sample(table, coreimage::samplerTransform(table,
    float2(index.r, index.g + dimension * index.b) + offset + 0.5f)).rgb;
}

// Tetrahedra preserve the exact neutral diagonal, unlike trilinear interpolation
// that mixes colored vertices even when R == G == B.
static float3 mixerDelta(coreimage::sampler table, float3 rgb, float dimension, float2 offset = float2(0.0f)) {
  const float3 coordinate = clamp(mixerEncode(rgb), 0.0f, 1.0f) * (dimension - 1.0f);
  const float3 low = min(floor(coordinate), dimension - 2.0f);
  const float3 f = coordinate - low;
  float3 first;
  float3 second;
  float3 sorted;
  if (f.r >= f.g) {
    if (f.g >= f.b) {
      first = float3(1, 0, 0); second = float3(1, 1, 0); sorted = f.rgb;
    } else if (f.r >= f.b) {
      first = float3(1, 0, 0); second = float3(1, 0, 1); sorted = f.rbg;
    } else {
      first = float3(0, 0, 1); second = float3(1, 0, 1); sorted = f.brg;
    }
  } else {
    if (f.r >= f.b) {
      first = float3(0, 1, 0); second = float3(1, 1, 0); sorted = f.grb;
    } else if (f.g >= f.b) {
      first = float3(0, 1, 0); second = float3(0, 1, 1); sorted = f.gbr;
    } else {
      first = float3(0, 0, 1); second = float3(0, 1, 1); sorted = f.bgr;
    }
  }
  return (1.0f - sorted.x) * mixerVertex(table, low, dimension, offset)
    + (sorted.x - sorted.y) * mixerVertex(table, low + first, dimension, offset)
    + (sorted.y - sorted.z) * mixerVertex(table, low + second, dimension, offset)
    + sorted.z * mixerVertex(table, low + 1.0f, dimension, offset);
}

// Ordered RGB triples occupy triangular slices: for a high channel h there
// are (h + 1)(h + 2)/2 pairs of lower channels. Each texel stores two deltas.
static float2 whitesEndpoints(coreimage::sampler table, uint3 index, float3 layout, float2 response) {
  uint l = index.x, m = index.y, h = index.z;
  uint offset = h * (h + 1) * (h + 2) / 6 + m * (m + 1) / 2 + l;
  uint width = uint(layout.y);
  float2 p = float2(offset % width, offset / width) + 0.5f;
  p.y += response.x * layout.z;
  float2 a = coreimage::sample(table, coreimage::samplerTransform(table, p)).rg;
  float2 b = coreimage::sample(table, coreimage::samplerTransform(table, p + float2(0.0f, layout.z))).rg;
  return mix(a, b, response.y);
}

extern "C" { namespace coreimage {
  // Combine the two measured knots and their PCHIP tangents once per cube vertex.
  float4 brightroomSaturationTable(sampler atlas, float firstColumn, float dimension,
    float4 weights, destination dest) {
    float2 p = dest.coord() + float2(firstColumn, 0.0f);
    float3 residual = float3(0.0f);
    for (int i = 0; i < 4; ++i) {
      float2 position = p + float2(float(i) * dimension, 0.0f);
      residual += weights[i] * sample(atlas, samplerTransform(atlas, position)).rgb;
    }
    return float4(residual, 1.0f);
  }

  float4 brightroomGlobalSaturation(sampler input, sampler table, float strength, float dimension) {
    float4 source = sample(input, samplerCoord(input));
    if (source.a <= 0.0f) return source;
    float3 rgb = unpremultiply(source).rgb;
    float y = dot(rgb, float3(0.2289746f, 0.6917385f, 0.0792869f));
    // Linear chroma carries extended-range values beyond the measured SDR cube.
    float3 base = mix(float3(y), rgb, 1.0f + strength);
    return premultiply(float4(base + mixerDelta(table, rgb, dimension), source.a));
  }

  // Alpha-weighted linear luminance: transparent pixels carry no scene data.
  float4 brightroomWhitesLuminance(sample_t input) {
    float luma = dot(clamp(unpremultiply(input).rgb, 0.0f, 1.0f),
      float3(0.2289746f, 0.6917385f, 0.0792869f));
    return float4(luma * input.a, 0.0f, 0.0f, input.a);
  }

  // CIAreaAverage reduces raw moments; coverage excludes transparent pixels.
  float4 brightroomWhitesMoments(sample_t blurred, sample_t source) {
    float x = mixerEncode(float3(blurred.r / max(blurred.a, 1e-8f))).r;
    return float4(x, x * x, x * x * x, 1.0f) * source.a;
  }

  float4 brightroomAdaptiveWhites(sampler inputImage, sampler table,
    sampler statistics, float amount, float dimension) {
    float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0f) return source;
    float4 moments = sample(statistics, samplerTransform(statistics, float2(0.5f)));
    float3 m = moments.rgb / max(moments.a, 1e-8f);
    float variance = max(m.g - m.r * m.r, 0.0f);
    float third = m.b - 3.0f * m.r * m.g + 2.0f * m.r * m.r * m.r;
    // Synthetic-only, leave-one-scene-out fit. See Light/white-stats.py for
    // provenance and held-out measurements; these are not photo-specific gains.
    float factor = exp(0.900511174f - 0.287816331f * m.r - 1.207664699f * m.r * m.r
      - 3.290332480f * variance - 25.471796583f * third);
    float strength = amount * factor;
    float lower;
    float upper;
    float index;
    if (strength < 10.0f) { lower = 0.0f; upper = 10.0f; index = 0.0f; }
    else if (strength < 25.0f) { lower = 10.0f; upper = 25.0f; index = 1.0f; }
    else if (strength < 50.0f) { lower = 25.0f; upper = 50.0f; index = 2.0f; }
    else { lower = 50.0f; upper = 100.0f; index = 3.0f; }
    float3 rgb = unpremultiply(source).rgb;
    float3 a = mixerDelta(table, rgb, dimension, float2(0.0f, index * dimension * dimension));
    float3 b = mixerDelta(table, rgb, dimension, float2(0.0f, (index + 1.0f) * dimension * dimension));
    float3 delta = mix(a, b, (strength - lower) / (upper - lower));
    // Beyond the last measured strength, extend its slope up to the SDR
    // boundary while preserving any headroom already present in the input.
    if (strength > 100.0f) delta = min(delta, max(1.0f - rgb, b));
    return premultiply(float4(rgb + delta, source.a));
  }

  float4 brightroomWhitesEncodedLuminance(sample_t source) {
    float y = dot(clamp(unpremultiply(source).rgb, 0.0f, 1.0f), float3(0.2289746f, 0.6917385f, 0.0792869f));
    return float4(mixerEncode(float3(y)).r, 0.0f, 0.0f, 1.0f) * source.a;
  }

  // Measure luminance, its local average, and the proximity of a colored channel to white.
  float4 brightroomWhitesDistributionSample(sampler luminance, sampler blurred, sampler source,
    float2 origin, float2 stride, destination dest) {
    uint2 cell = uint2(floor(dest.coord()));
    uint hash = (cell.x * 1664525u + cell.y * 1013904223u) ^ 0x85ebca6bu;
    hash ^= hash >> 16;
    hash *= 0x7feb352du;
    hash ^= hash >> 15;
    float2 jitter = (float2(hash & 65535u, hash >> 16) + 0.5f) / 65536.0f;
    float2 position = origin + floor((float2(cell) + jitter) * stride) + 0.5f;
    float4 raw = sample(luminance, samplerTransform(luminance, position));
    float4 smooth = sample(blurred, samplerTransform(blurred, position));
    float3 rgb = unpremultiply(sample(source, samplerTransform(source, position))).rgb;
    float3 romm = brightroom::linearP3ToROMM(rgb);
    float highest = clamp(max(romm.r, max(romm.g, romm.b)), 0.0f, 1.0f);
    // The last interval of the measured 32-code grid. Subtract the weight
    // already explained by luminance so a neutral white cannot contribute.
    float2 codes = float2(mixerEncode(float3(highest)).r, raw.r / max(raw.a, 1e-8f));
    float2 white = clamp(1.0f + 31.0f * (codes - 1.0f), 0.0f, 1.0f);
    float excess = max(0.0f, white.x - white.y);
    return float4(raw.r, raw.a * smooth.r / max(smooth.a, 1e-8f), raw.a * excess, raw.a);
  }

  // Center before squaring so nearly uniform scenes keep their variance in a half-float context.
  float4 brightroomWhitesContrast(sampler guide, sampler average) {
    float4 value = sample(guide, samplerCoord(guide));
    float4 scene = sample(average, samplerTransform(average, float2(0.5f)));
    float2 code = value.rg / max(value.a, 1e-8f);
    float high = code.r - code.g;
    float total = code.r - scene.r / max(scene.a, 1e-8f);
    return float4(high * high, total * total, 0.0f, 1.0f) * value.a;
  }

  // Each row counts 8×8 guide pixels. The extra column collects the coverage,
  // first moment and centered second moment of locally constant brightness.
  float4 brightroomWhitesHistogram(sampler guide, sampler contrast, float2 size, destination dest) {
    uint tile = uint(dest.coord().y);
    uint columns = uint(ceil(size.x / 8.0f));
    uint2 origin = uint2(tile % columns, tile / columns) * 8u;
    float3 centers = floor(dest.coord().x) * 3.0f + float3(0.0f, 1.0f, 2.0f);
    float4 energy = sample(contrast, samplerTransform(contrast, float2(0.5f)));
    float smoothWeight = clamp(energy.r / max(energy.g, 1e-5f * energy.a + 1e-12f), 0.0f, 1.0f);
    float3 mass = float3(0.0f);
    for (uint y = 0; y < 8 && origin.y + y < uint(size.y); ++y) {
      for (uint x = 0; x < 8 && origin.x + x < uint(size.x); ++x) {
        float2 p = float2(origin + uint2(x, y)) + 0.5f;
        float4 value = sample(guide, samplerTransform(guide, p));
        float level = clamp(mix(value.r, value.g, smoothWeight) / max(value.a, 1e-8f), 0.0f, 1.0f);
        if (centers.x < 128.0f) {
          mass += value.a * max(1.0f - abs(centers - level * 127.0f), 0.0f);
        } else {
          const float2 offsets[4] = { float2(-1, 0), float2(1, 0), float2(0, -1), float2(0, 1) };
          float code = value.r / max(value.a, 1e-8f);
          float coverage = value.a;
          for (int i = 0; i < 4; ++i) {
            float2 q = clamp(p + offsets[i], float2(0.5f), size - 0.5f);
            float4 neighbor = sample(guide, samplerTransform(guide, q));
            // Compare straight luminance at one 16-bit code of tolerance.
            // A fully transparent neighbor supplies no brightness observation.
            if (abs(neighbor.r - code * neighbor.a) > neighbor.a / 65535.0f) coverage = 0.0f;
          }
          mass += coverage * float3(1.0f, level, (level - 0.5f) * (level - 0.5f));
        }
      }
    }
    return float4(mass / 64.0f, 1.0f);
  }

  // The distribution and its distance from each calibration scene are
  // evaluated once for the image. Only the resulting table coordinate is
  // sampled by the full-resolution response.
  float4 brightroomWhitesDisplacement(sampler histogram, sampler distributions, sampler positions, sampler guideMean,
    float3 model, float4 law, float4 upperCurve, float histogramExponent, float sceneCount, float layerCount) {
    const float ranks[13] = { .01f, .05f, .1f, .2f, .3f, .4f, .5f, .6f, .7f, .8f, .9f, .95f, .99f };
    float mass[129];
    float total = 0.0f;
    float first = 0.0f;
    for (int i = 0; i < 43; ++i) {
      float3 v = sample(histogram, samplerTransform(histogram, float2(float(i) + 0.5f, 0.5f))).rgb;
      for (int c = 0; c < 3; ++c) {
        int bin = i * 3 + c;
        mass[bin] = v[c];
        total += v[c];
        first += v[c] * float(bin);
      }
    }
    if (total <= 0.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    // Hellinger affinity compares population in fixed brightness intervals. Two
    // scenes can retain the same tones even as a plateau moves across a quantile.
    float overlap = 0.0f;
    float roots[16] = {};
    float mean = first / (127.0f * total);
    float variance = 0.0f;
    for (int i = 0; i < 128; ++i) {
      // Overlap four bins apart falls when the histogram consists of isolated peaks.
      if (i >= 4) overlap += min(mass[i], mass[i - 4]);
      float offset = float(i) / 127.0f - mean;
      variance += mass[i] * offset * offset;
      float position = float(i) * (15.0f / 127.0f);
      int lower = min(int(position), 14);
      float fraction = position - float(lower);
      roots[lower] += mass[i] * (1.0f - fraction);
      roots[lower + 1] += mass[i] * fraction;
    }
    // Estimate headroom from the entire frame and separately from its brightest levels.
    float linearHeadroom = 0.0f, highlightMass = 0.0f, highlightHeadroom = 0.0f;
    // Capping a bin's mass compares the levels present across flat regions
    // even when the areas occupied by those levels differ between images.
    const float massCap = 0.025f;
    float cappedMass = 0.0f;
    for (int i = 0; i < 16; ++i) {
      float density = max(0.0f, roots[i] / total);
      cappedMass += min(density, massCap);
      float code = float(i) / 15.0f;
      float level = code <= 0.04045f ? code / 12.92f : pow((code + 0.055f) / 1.055f, 2.4f);
      float weighted = density * exp(8.0f * (level - 1.0f));
      linearHeadroom += density * (1.0f - level);
      highlightMass += weighted;
      highlightHeadroom += weighted * (1.0f - level);
      roots[i] = sqrt(density);
    }
    float values[15] = {};
    values[0] = mean;
    float prior = 0.0f;
    int rank = 0;
    for (int bin = 0; bin < 128 && rank < 13; ++bin) {
      float next = prior + mass[bin];
      while (rank < 13 && next >= total * ranks[rank]) {
        float f = (total * ranks[rank] - prior) / max(mass[bin], 1e-12f);
        values[1 + rank] = clamp((float(bin) - 0.5f + f) / 127.0f, 0.0f, 1.0f) - mean;
        ++rank;
      }
      prior = next;
    }

    float response75 = model.x * (1.0f - mean);
    float2 localTotal = 0.0f, localResponse = 0.0f, confidence = 0.0f;
    for (int scene = 0; scene < int(sceneCount); ++scene) {
      float distance = 0.0f;
      float coefficient = 0.0f;
      for (int column = 0; column < 5; ++column) {
        float3 row = sample(distributions, samplerTransform(distributions, float2(column, scene) + 0.5f)).rgb;
        for (int c = 0; c < 3; ++c) {
          int index = 3 * column + c;
          if (index == 14) {
            coefficient = row[c];
          } else {
            float difference = values[index] - row[c];
            distance += difference * difference * (index == 0 ? model.y : 1.0f / 13.0f);
          }
        }
      }
      response75 += coefficient * exp(-model.z * distance);
      float2 affinity = 0.0f;
      float sceneCappedMass = 0.0f, measured = 0.0f;
      for (int column = 5; column < 11; ++column) {
        float3 row = sample(distributions, samplerTransform(distributions, float2(column, scene) + 0.5f)).rgb;
        for (int c = 0; c < 3; ++c) {
          int index = 3 * (column - 5) + c;
          if (index < 16) {
            float sceneRoot = row[c];
            float cappedRoot = min(sceneRoot, sqrt(massCap));
            affinity.x += roots[index] * sceneRoot;
            affinity.y += min(roots[index], sqrt(massCap)) * cappedRoot;
            sceneCappedMass += cappedRoot * cappedRoot;
          }
          if (index == 16) measured = row[c];
        }
      }
      affinity.y /= sqrt(max(cappedMass * sceneCappedMass, 1e-12f));
      affinity = clamp(affinity, 0.0f, 1.0f);
      float2 proximity = pow(affinity, float2(histogramExponent, 32.0f));
      float2 weight = proximity / max(1.0f - affinity, 1e-6f);
      localResponse += weight * measured;
      localTotal += weight;
      confidence = max(confidence, proximity);
    }
    float2 estimates = max(mix(float2(response75), localResponse / max(localTotal, 1e-20f), confidence), 1e-6f);
    float densityWeight = clamp(overlap / total, 0.0f, 1.0f);
    densityWeight *= densityWeight;
    // Rebuild this log-displacement fit from the 17 synthetic scenes with fit-whites-headroom.py.
    const float4 headroomFit = float4(-3.313040584f, 1.158262548f, 0.794735651f, -1.952705711f);
    float estimate = dot(headroomFit, float4(1.0f, linearHeadroom,
      highlightHeadroom / max(highlightMass, 1e-12f), highlightMass));
    estimates = exp(mix(log(estimates), float2(estimate), 0.25f * (1.0f - confidence) * densityWeight * densityWeight));
    // A single flat tone carries no variation between flat regions. Their
    // contribution is the part of the whole-frame variance their tones span.
    float3 flat = sample(histogram, samplerTransform(histogram, float2(43.5f, 0.5f))).rgb;
    float flatMean = flat.y / max(flat.x, 1e-12f) - 0.5f;
    float flatVariance = max(0.0f, flat.z - flat.x * flatMean * flatMean);
    float fractionFlat = clamp(flatVariance / max(variance, total / (127.0f * 127.0f)), 0.0f, 1.0f);
    response75 = mix(estimates.x, estimates.y, fractionFlat);
    // The 17 scene distributions cover the lower end of this range. The upper
    // end and log response come from the +50 color lattice and its gray equivalent.
    const float3 chromaticHeadroom = float3(0.002486f, 0.009944f, -0.167289f);
    float4 average = sample(guideMean, samplerTransform(guideMean, float2(0.5f)));
    float chromaticWhite = average.b / max(average.a, 1e-8f);
    float fraction = clamp((chromaticWhite - chromaticHeadroom.x) / (chromaticHeadroom.y - chromaticHeadroom.x), 0.0f, 1.0f);
    response75 *= exp(fraction * chromaticHeadroom.z);
    float response = exp(law.x + law.y * log(response75));
    if (law.w > 0.0f) {
      // A long bright tail lowers the +75 displacement. Shrink the imbalance
      // by how much it changes when trimming both tails from 1% to 5%.
      float outerBalance = -(values[1] + values[13]);
      float innerBalance = -(values[2] + values[12]);
      float balance = sign(outerBalance) * max(0.0f, abs(outerBalance) - abs(outerBalance - innerBalance));
      float span = values[13] - values[1];
      float textured = (1.0f - clamp(flat.x / total, 0.0f, 1.0f)) * (1.0f - fractionFlat);
      float affinitySquared = confidence.x * confidence.x;
      float weight = span * span * (1.0f - affinitySquared * affinitySquared) * textured * (1.0f - fraction);
      const float tailGain = 1.585221f;
      // The mean of each outer 5% measures how far brightness extends beyond
      // its percentile. Split a boundary bin by its remaining population.
      float tailMass = 0.05f * total;
      float2 remaining = float2(tailMass);
      float excess = 0.0f;
      for (int i = 0; i < 128 && any(remaining > 0.0f); ++i) {
        float2 used = min(remaining, float2(mass[i], mass[127 - i]));
        float2 level = float2(i, 127 - i) / 127.0f;
        excess += dot(used, level - (mean + float2(values[2], values[12])));
        remaining -= used;
      }
      // Once the outer imbalance reaches one standard deviation the existing
      // tail estimate dominates. Both measurements are in encoded luminance.
      float spread = sqrt(max(variance / total, 1.0f / (127.0f * 127.0f)));
      float centralWeight = max(0.0f, 1.0f - abs(outerBalance) / spread);
      const float tailExcessGain = -4.140309f;
      excess /= tailMass;
      // Mean and median can occupy the same histogram bin. Fade the extra
      // correction when their separation points toward the opposite tail.
      float agreement = clamp(1.0f - 127.0f * sign(excess) * values[7], 0.0f, 1.0f);
      // When the asymmetry recedes between the 5% and 10% tails, scale its
      // contribution by the remaining headroom. Flat regions and imbalances
      // smaller than one histogram bin provide little evidence for this fit.
      float decileBalance = -(values[3] + values[11]);
      float decrease = max(0.0f, abs(innerBalance) - abs(decileBalance));
      float outerChange = max(abs(outerBalance - innerBalance), 1.0f / 127.0f);
      float concentration = sqrt(clamp(decrease / outerChange, 0.0f, 1.0f))
        * clamp(127.0f * abs(balance), 0.0f, 1.0f) * textured;
      const float concentratedTailGain = 3.345947f;
      const float concentratedExcessGain = -3.311515f;
      float headroom = max(1.0f - mean, 1.0f / 127.0f);
      float normalizedGain = concentratedTailGain / (1.0f + 2.0f * abs(outerBalance) / headroom);
      float logChange = mix(tailGain, normalizedGain, concentration) * weight * balance
        + mix(tailExcessGain, concentratedExcessGain, concentration) * weight * centralWeight * agreement * excess;
      // The +50 endpoint bounds the correction even if nearly the whole image
      // is dark and a small, bright region pushes the upper tail close to white.
      response75 = max(response, response75 * exp(logChange));
      response = response75;
    }
    if (law.z > 0.0f) {
      // Eight color charts and two gray ramps measure the extra lift to +100.
      // The numerator and denominator keep its slope finite as headroom increases.
      float numerator = response75 * (upperCurve.x + response75 * upperCurve.y);
      float denominator = 1.0f + response75 * (upperCurve.z + response75 * upperCurve.w);
      float upper = numerator / denominator;
      response = exp(mix(log(response75), log(max(upper, response75)), law.z));
    }
    // Resolve the two enclosing RGB layers once. Their spacing follows the measured curvature.
    float lower = 0.0f;
    for (int i = 1; i < int(layerCount); ++i) {
      float upper = sample(positions, samplerTransform(positions, float2(float(i) + 0.5f, 0.5f))).r;
      if (response <= upper || i == int(layerCount) - 1) {
        float fraction = clamp((response - lower) / max(upper - lower, 1e-7f), 0.0f, 1.0f);
        // Store the discrete index as a byte code. An integer working format
        // can carry the same two layer coordinates as a floating-point context.
        return float4(float(i - 1) / 255.0f, fraction, 0.0f, 1.0f);
      }
      lower = upper;
    }
    return float4(0.0f, 0.0f, 0.0f, 1.0f);
  }

  static inline float4 whitesResponse(float4 source, sampler table, sampler displacement, float3 layout) {
    if (source.a <= 0.0f) return source;
    float3 rgb = unpremultiply(source).rgb;
    float2 response = sample(displacement, samplerTransform(displacement, float2(0.5f))).rg;
    response.x = round(response.x * 255.0f);
    float3 bounded = clamp(rgb, 0.0f, 1.0f);
    float3 romm = brightroom::linearP3ToROMM(bounded);
    float rgLow = min(romm.r, romm.g), rgHigh = max(romm.r, romm.g);
    float3 ordered = float3(min(rgLow, romm.b), max(rgLow, min(rgHigh, romm.b)), max(rgHigh, romm.b));
    float3 coord = clamp(mixerEncode(ordered), 0.0f, 1.0f) * (layout.x - 1.0f);
    uint3 base = uint3(min(floor(coord), layout.x - 2.0f));
    float3 f = coord - float3(base);
    float small = min(f.x, min(f.y, f.z));
    float large = max(f.x, max(f.y, f.z));
    float middle = max(min(f.x, f.y), min(max(f.x, f.y), f.z));
    // At a tied fraction the intervening vertex has weight zero. Advancing
    // the tied axes together keeps all four vertices inside the ordered grid.
    uint3 first = uint3(step(large, f));
    uint3 second = uint3(step(middle, f));
    float2 ends = (1.0f - large) * whitesEndpoints(table, base, layout, response)
      + (large - middle) * whitesEndpoints(table, base + first, layout, response)
      + (middle - small) * whitesEndpoints(table, base + second, layout, response)
      + small * whitesEndpoints(table, base + 1u, layout, response);
    // The measured extrema meet at white. Project a crossed estimate to their
    // common value before extending the response outside the measured gamut.
    float2 reference = clamp(ordered.xz, 0.0f, 1.0f);
    float2 adjusted = reference + ends;
    if (adjusted.x > adjusted.y) adjusted = float2(0.5f * (adjusted.x + adjusted.y));
    ends = clamp(adjusted, 0.0f, 1.0f) - reference;
    // A common scale and offset in linear ROMM are also a common scale and
    // offset in linear P3. Carry the input hue and extend its SDR boundary delta.
    float3 position = (bounded - ordered.x) / max(ordered.z - ordered.x, 1e-7f);
    return premultiply(float4(rgb + ends.x + position * (ends.y - ends.x), source.a));
  }

  float4 brightroomStrongWhites(sampler input, sampler table, sampler displacement, float3 layout) {
    return whitesResponse(sample(input, samplerCoord(input)), table, displacement, layout);
  }

  // Reduce the largest visible channel of both images. A rare bright pixel still
  // bounds the correction, regardless of whether the distribution grid sampled it.
  float4 brightroomWhitesPeaks(sample_t source, sample_t endpoint) {
    if (source.a <= 0.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    float3 input = unpremultiply(source).rgb, output = unpremultiply(endpoint).rgb;
    return float4(max(input.r, max(input.g, input.b)), max(output.r, max(output.g, output.b)), 0.0f, 1.0f);
  }

  float4 brightroomWhitesPeakResponse(sampler input, sampler table, sampler displacement, sampler endpoint,
    sampler peaks, float3 layout, float progress, float2 curve) {
    // Apply the RGB response and the peak correction in the same pass. Storing
    // the first result in a half-float texture can darken an already white channel.
    float4 source = sample(input, samplerCoord(input));
    float4 value = whitesResponse(source, table, displacement, layout);
    float2 peak = sample(peaks, samplerTransform(peaks, float2(0.5f))).rg;
    if (value.a <= 0.0f || peak.g <= 0.0f || peak.g >= 1.0f) return value;
    // The five constant-gray exports approach white as x / (x + k (1-x))
    // in encoded P3. Below the darkest measured gray, join that endpoint to black in linear light.
    float darkest = curve.x;
    float code = mixerEncode(float3(clamp(peak.r, darkest, 1.0f))).r;
    float white = code / (code + curve.y * (1.0f - code));
    float target = pow((white + 0.055f) / 1.055f, 2.4f) * clamp(peak.r / darkest, 0.0f, 1.0f);
    if (target <= peak.g) return value;
    float4 end = progress == 1.0f ? value : whitesResponse(source, table, endpoint, layout);
    float3 high = clamp(unpremultiply(end).rgb, 0.0f, 1.0f);
    float3 delta = min(high * (target / peak.g - 1.0f), 1.0f - high);
    float3 rgb = unpremultiply(value).rgb;
    return premultiply(float4(rgb + min(progress * delta, max(1.0f - rgb, 0.0f)), value.a));
  }

  // The standalone Whites/Blacks features share the same encoded lattice and
  // linear response representation, but evaluate only their own delta table.
  float4 brightroomTonalPoint(sampler inputImage, sampler table, float dimension) {
    const float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0f) return source;
    float3 rgb = unpremultiply(source).rgb;
    rgb += mixerDelta(table, rgb, dimension);
    return premultiply(float4(rgb, source.a));
  }

  float4 brightroomCalibratedColorMixer(sampler inputImage,
    sampler luminance, sampler saturation, sampler hue, float dimension) {
    const float4 source = sample(inputImage, samplerCoord(inputImage));
    if (source.a <= 0.0f) return source;
    float3 rgb = unpremultiply(source).rgb;
    rgb += mixerDelta(luminance, rgb, dimension);
    rgb += mixerDelta(saturation, rgb, dimension);
    rgb += mixerDelta(hue, rgb, dimension);
    return premultiply(float4(rgb, source.a));
  }
}}
#endif
