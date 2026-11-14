"""Fit the fraction of negative Shadows loss retained when the surrounding region is brighter."""
import argparse
from collections import Counter
import json
from pathlib import Path

import numpy as np

from tone_chart import digest


def display_code(linear):
    return np.where(linear < .0031308, linear * 12.92,
                    1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def equations(path, row):
    file = path.parent / row['file']
    if digest(file) != row['sha256']:
        raise ValueError(f'Changed Shadows calibration pixels in {file}')
    with np.load(file, allow_pickle=False) as sample:
        source, native, neutral, target = [sample[key] for key in ('x', 'e50', 'n50', 't50')]
        near_log = sample['log'][:, 2]  # Gaussian mean at radius 16 × long edge / 1024.
        indices = sample['idx']
    n = len(indices)
    if (not n or len(np.unique(indices)) != n or near_log.shape != (n,)
            or any(v.shape != (n, 3) for v in (source, native, neutral, target))
            or not all(np.isfinite(v).all() for v in (source, native, neutral, target, near_log))):
        raise ValueError(f'Invalid Shadows capture {file}')

    luminance = np.clip(source.astype('f8'), 0, 1) @ np.array([.22897456, .69173852, .07928692], dtype='f4')
    contrast = display_code(np.exp((near_log - 1) * 9.3)) - display_code(luminance)
    movement = native - source
    residual = movement - (target - neutral)
    magnitude = np.max(abs(residual), axis=1)
    p95 = np.quantile(magnitude, .95, method='inverted_cdf')
    weights = (.35 + .65 * np.minimum(1, magnitude / (p95 + .0001))) / (n * (p95 + .007) ** 2)
    # Fit both sides of the edge. GPU comparisons selected only the positive
    # side, where returning part of the original RGB reduces excessive loss.
    gram = np.sum(weights * np.sum(movement * movement, axis=1) * contrast ** 2)
    right = np.sum(weights * np.sum(movement * residual, axis=1) * contrast)
    return gram, right


def fit(path):
    manifest = json.loads(path.read_text())
    if manifest['control'] != 'Shadows2012' or manifest['amount'] != -50:
        raise ValueError('Expected isolated Shadows −50 cases')
    rows = manifest['cases']
    counts = Counter(row['family'] for row in rows)
    if set(counts) != {'photo', 'chart'} or len({r['source'] for r in rows}) != len(rows):
        raise ValueError('Expected distinct photo and chart inputs')
    gram = right = 0.0
    for row in rows:
        g, b = equations(path, row)
        weight = {'photo': .6, 'chart': .4}[row['family']] / counts[row['family']]
        gram += weight * g
        right += weight * b
    if gram <= 0:
        raise ValueError('No measurable contrast or adjustment in the calibration')
    return dict(coefficient=right / (1.02 * gram), scenes=counts)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    args = parser.parse_args()
    print(json.dumps(fit(args.manifest), indent=2, allow_nan=False))
