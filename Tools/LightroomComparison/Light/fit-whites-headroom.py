"""Rebuild the positive Whites scene estimates from registered synthetic and photographic +75 displacements."""
import argparse
import json
from pathlib import Path
import re

import numpy as np


def flat_region_parameters(calibration, masses, displacement):
    """Choose how strongly to cap histogram occupancy when comparing flat regions."""
    scenes = calibration['scenes']
    summary = np.array([s['encodedLuminance'] for s in scenes])
    if summary.shape != (len(scenes), 14) or not np.isfinite(summary).all():
        raise ValueError('Invalid Whites luminance summaries')
    mean = summary[:, 0]
    centered = summary[:, 1:] - mean[:, None]
    distance = (calibration['meanWeight'] * (mean[:, None] - mean) ** 2
                + ((centered[:, None] - centered) ** 2).mean(axis=2))
    kernel = np.exp(-.5 * distance / calibration['distributionWidth'] ** 2)
    prior = calibration['uniformSlope'] * (1 - mean)

    # All 17 scenes belong to one of these five generated layout families.
    def family(name):
        if name.startswith('whites-context-flat'):
            return 'color grid on a uniform field'
        if name.startswith('whites-context-smooth'):
            return 'color grid on a smooth field'
        if name.startswith('adaptcal-flat'):
            return 'uniform gray'
        if 'ramp' in name:
            return 'gray ramp'
        if name.startswith('paired-surround'):
            return 'paired surrounds'
        raise ValueError(f'Unknown synthetic scene {name}')

    families = np.array([family(s['scene']) for s in scenes])
    candidates = {}
    for cap in [1., .01, .025, .07, .15, .3]:
        capped = np.minimum(masses, cap)
        roots = np.sqrt(capped / capped.sum(axis=1, keepdims=True))
        affinity = np.clip(roots @ roots.T, 0, 1)
        for exponent in [4, 8, 16, 32]:
            candidates[cap, exponent] = (affinity, affinity ** exponent, [])

    for i in range(len(scenes)):
        for keep in [np.arange(len(scenes)) != i, families != families[i]]:
            coefficients = np.linalg.solve(kernel[np.ix_(keep, keep)] + calibration['ridge'] * np.eye(keep.sum()),
                                           displacement[keep] - prior[keep])
            broad = prior[i] + kernel[i, keep] @ coefficients
            for affinity, proximity, errors in candidates.values():
                weights = proximity[i, keep] / np.maximum(1 - affinity[i, keep], 1e-6)
                if weights.sum() > 0:
                    local = weights @ displacement[keep] / weights.sum()
                    estimate = broad + proximity[i, keep].max() * (local - broad)
                else:
                    estimate = broad
                errors.append(abs(np.log(max(estimate, 1e-6) / displacement[i])))
    scores = {key: np.mean(errors) for key, (_, _, errors) in candidates.items()}
    return min(scores, key=scores.get), scores


def photographic_tail_gains(observations, *, normalize_by_headroom=False):
    """Fit the percentile imbalance and outer 5% extension, optionally scaling imbalance by headroom."""
    if len({r['sourceSHA256'] for r in observations}) != len(observations):
        raise ValueError('Duplicate photographic +75 source')
    terms, extensions, residuals = [], [], []
    for row in observations:
        mean, low, inner_low, inner_high, high = (row[k] for k in ('mean', 'q01', 'q05', 'q95', 'q99'))
        weight = row['meterWeight']
        before, observed = row['baselineDisplacement75'], row['measuredDisplacement75']
        if not (0 <= low <= inner_low <= inner_high <= high <= 1 and 0 <= mean <= 1
                and 0 <= weight <= 1 and 0 < before < 1 and 0 < observed < 1):
            raise ValueError(f"Invalid photographic +75 observation {row['id']}")
        outer, inner = 2 * mean - low - high, 2 * mean - inner_low - inner_high
        balance = np.sign(outer) * max(0, abs(outer) - abs(outer - inner))
        scale = weight * (high - low) ** 2
        if normalize_by_headroom:
            balance /= 1 + 2 * abs(outer) / max(1 - mean, 1 / 127)
        terms.append(scale * balance)
        median = row['q50']
        low_mean, high_mean = row['lowestFivePercentMean'], row['highestFivePercentMean']
        variance = row['encodedVariance']
        # Quantiles interpolate within each 1/127 bin. Tail means use its center.
        if not (inner_low <= median <= inner_high and 0 <= low_mean <= inner_low + .5 / 127
                and inner_high - .5 / 127 <= high_mean <= 1 and 0 <= variance <= .25):
            raise ValueError(f"Invalid photographic +75 tail populations {row['id']}")
        excess = (high_mean - inner_high) - (inner_low - low_mean)
        central = max(0, 1 - abs(outer) / max(np.sqrt(variance), 1 / 127))
        agreement = np.clip(1 + 127 * np.sign(excess) * (mean - median), 0, 1)
        extensions.append(scale * central * agreement * excess)
        residuals.append(np.log(observed / before))
    if not any(x > 0 for x in terms) or not any(x < 0 for x in terms):
        raise ValueError('Expected photos with long bright and dark tails')
    if not any(extensions):
        raise ValueError('No measured photograph has an independent tail extension')
    gain = np.dot(terms, residuals) / np.dot(terms, terms)
    remainder = residuals - np.asarray(terms) * gain
    return gain, np.dot(extensions, remainder) / np.dot(extensions, extensions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('calibration', type=Path)
    parser.add_argument('--check', type=Path, help='verify the fit in ColorMixerCalibrationKernels.metal')
    args = parser.parse_args()
    calibration = json.loads(args.calibration.read_text())
    scenes = calibration['scenes']
    masses = np.array([s['luminanceHistogram'] for s in scenes])
    displacement = np.array([s['grayDisplacement75'] for s in scenes])
    if (masses.shape != (17, 16) or (masses < 0).any() or (displacement <= 0).any()
            or not np.isfinite(displacement).all() or len({s['sourceSHA256'] for s in scenes}) != 17):
        raise ValueError('Expected the 17 registered synthetic luminance histograms and positive displacements')
    np.testing.assert_allclose(masses.sum(axis=1), 1, atol=1e-6, rtol=0)
    code = np.arange(16) / 15
    linear = np.where(code <= .04045, code / 12.92, ((code + .055) / 1.055) ** 2.4)
    highlight = np.exp(8 * (linear - 1))
    weight = masses @ highlight
    features = np.column_stack([1 - masses @ linear, (masses @ (highlight * (1 - linear))) / weight, weight])
    scale = np.maximum(features.std(axis=0), .02)
    normalized = (features - features.mean(axis=0)) / scale
    target = np.log(displacement)
    slopes = np.linalg.solve(normalized.T @ normalized + .5 * np.eye(3),
                             normalized.T @ (target - target.mean())) / scale
    fit = np.r_[target.mean() - features.mean(axis=0) @ slopes, slopes]
    (cap, exponent), scores = flat_region_parameters(calibration, masses, displacement)
    tail_gain, excess_gain = photographic_tail_gains(calibration['photographicTails'])
    concentrated_gain, concentrated_excess = photographic_tail_gains(calibration['photographicTails'],
                                                                      normalize_by_headroom=True)
    if args.check:
        shader = args.check.read_text()
        table = re.search(r'headroomFit = float4\(([^)]+)\);', shader)
        if not table:
            raise ValueError('Missing Whites headroom fit')
        np.testing.assert_allclose(np.array([float(v.strip()[:-1]) for v in table[1].split(',')]),
                                   fit, rtol=0, atol=5.1e-10)
        mass_cap = re.search(r'const float massCap = ([\d.]+)f;', shader)
        power = re.search(r'pow\(affinity, float2\(histogramExponent, ([\d.]+)f\)\)', shader)
        if not mass_cap or not power or (float(mass_cap[1]), float(power[1])) != (cap, exponent):
            raise ValueError('Whites flat-region calibration differs from the shader')
        for name, expected in [('tailGain', tail_gain), ('tailExcessGain', excess_gain),
                               ('concentratedTailGain', concentrated_gain), ('concentratedExcessGain', concentrated_excess)]:
            match = re.search(rf'const float {name} = ([-\d.]+)f;', shader)
            if not match or abs(float(match[1]) - expected) > .00000051:
                raise ValueError(f'Whites {name} differs from the photographic measurements')
    print('Whites +75 headroom fit:', *fit)
    print('Flat-region mass cap and exponent:', cap, exponent)
    print('Photographic +75 tail and excess gains:', tail_gain, excess_gain)
    print('Photographic +75 headroom-normalized tail and excess gains:', concentrated_gain, concentrated_excess)
    print('Mean absolute log displacement error with one source or family withheld:',
          scores[1., calibration['distributionGuide']['histogramExponent']], '->', scores[cap, exponent])


if __name__ == '__main__':
    main()
