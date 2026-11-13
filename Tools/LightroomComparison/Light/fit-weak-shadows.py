"""Recover the positive Shadows strength below +50 from registered gray-ramp exports."""
import argparse
from pathlib import Path
import re

import numpy as np

from adaptive_data import FrozenSet


def encoded(values):
    return np.where(values <= 0.0031308, 12.92 * values,
                    1.055 * np.maximum(values, 0) ** (1 / 2.4) - 0.055)


def ramp(dataset, prefix, amount):
    identity = prefix + ('neutral' if amount == 0 else f'Shadows2012-{amount}')
    pixels = dataset.read(identity)
    if pixels.shape != (256, 1024, 4):
        raise ValueError('Unexpected ramp dimensions')
    return encoded(pixels[128, :, 0].astype(float))


def fit(anchor, weak):
    x = ramp(anchor, 'adaptive-ramp-', 0)
    x_weak = ramp(weak, 'adaptcal-ramp-', 0)
    if np.max(abs(x - x_weak)) >= 0.0003:
        raise ValueError('The registered neutral ramps differ')
    response = ramp(anchor, 'adaptive-ramp-', 50) - x
    centers = np.linspace(0, 1, 9)
    # Fit the weak-to-+50 change in overlapping tone ranges. Least squares
    # suppresses unstable per-pixel ratios where the +50 change is near zero.
    weights = np.exp(-0.5 * ((x[:, None] - centers) / 0.045) ** 2)
    denominator = (response ** 2) @ weights
    if np.any(denominator <= 0):
        raise ValueError('Missing +50 response within a tone range')
    return np.stack([((ramp(weak, 'adaptcal-ramp-', amount) - x_weak) * response) @ weights
                     / denominator for amount in (10, 25)], axis=1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('anchor', type=Path, help='adaptive-002 acquisition')
    parser.add_argument('weak', type=Path, help='adaptive-calibration-001 acquisition')
    parser.add_argument('--check', type=Path, help='verify the generated values in HighlightShadowKernels.metal')
    args = parser.parse_args()
    gains = fit(FrozenSet(args.anchor), FrozenSet(args.weak))
    if args.check:
        source = args.check.read_text().split('static float weakShadowStrength(', 1)[1]
        array = source.split('const float2 gains[9] = {', 1)[1].split('};', 1)[0]
        values = re.findall(r'float2\(([.\d]+)f, ([.\d]+)f\)', array)
        np.testing.assert_allclose(np.array(values, dtype=float), gains, atol=5.1e-8, rtol=0)
        print('Verified 18 measured Shadows strength values')
    else:
        for low, high in gains:
            print(f'float2({low:.7f}f, {high:.7f}f),')
