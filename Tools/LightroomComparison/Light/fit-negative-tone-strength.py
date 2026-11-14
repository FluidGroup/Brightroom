"""Recover the Camera Raw strength coordinates from neutral, −10, −25 and −50 TIFF exports."""
import argparse
import hashlib
import json
from pathlib import Path
import re

import numpy as np

from adaptive_data import FrozenSet, P3_TO_ROMM

INTERVALS = 32


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_chart(root, control, anchor_set, anchor_prefix, weak_set, weak_prefix):
    """Select the same source pixels in all four registered 16-bit ProPhoto exports."""
    source_hash = None
    result = {}
    for name, prefix, amounts in [(anchor_set, anchor_prefix, [0, -50]), (weak_set, weak_prefix, [-10, -25])]:
        directory = root / name
        catalog = FrozenSet(directory)
        cases = {r['id']: r for r in json.loads((directory / 'cases.json').read_text())['cases']}
        for amount in amounts:
            identity = prefix + ('neutral' if amount == 0 else f'{control}-{amount}')
            case = cases[identity]
            ref = catalog.references[identity]
            if source_hash is None:
                source_hash = case['inputSHA256']
            other = 'Shadows2012' if control == 'Highlights2012' else 'Highlights2012'
            if not (case['inputSHA256'] == digest(case['input']) == source_hash
                    and case['settingsSHA256'] == digest(case['settings']) == ref['settingsSHA256']
                    and case['parameters'] == ({control: amount} if amount else {})
                    and float(ref['resolvedSettings'][control]) == amount
                    and float(ref['resolvedSettings'][other]) == 0
                    and ref['inspection']['profile'] == 'ProPhoto RGB' and ref['inspection']['bits'] == 16
                    and catalog.decoded[identity]['space'] == 'extended-linear Display-P3 D65'):
                raise ValueError(f'Inconsistent source, settings, or color space for {identity}')
            pixels = catalog.read(identity)
            if pixels.shape != (256, 1024, 4):
                raise ValueError(f'Unexpected chart dimensions for {identity}')
            result[amount] = pixels[..., :3].reshape(-1, 3)
    positions = np.random.default_rng(int(source_hash[:16], 16)).choice(len(result[0]), 16384, replace=False)
    colors = {amount: rgb[positions].astype(float) @ P3_TO_ROMM.T for amount, rgb in result.items()}
    # Follow the two channels defining the original hue, even when they meet at an endpoint.
    extrema = np.column_stack((colors[0].argmin(axis=1), colors[0].argmax(axis=1)))
    return {amount: np.clip(np.take_along_axis(rgb, extrema, axis=1), 0, 1) for amount, rgb in colors.items()}


def coordinate(value, highlights):
    if highlights:
        return np.arcsin(np.sqrt(value)) * (2 / np.pi)
    return 0.5 + np.log((value + .0001) / (1.0001 - value)) / (2 * np.log(10001))


def linear_value(position, highlights):
    position = np.clip(position, 0, 1)
    if highlights:
        return np.sin(position * np.pi / 2) ** 2
    return np.clip(1.0002 / (1 + np.exp((.5 - position) * 2 * np.log(10001))) - .0001, 0, 1)


def basis(position):
    """Integrated unit slopes, so the fitted coordinate is continuous at every knot."""
    return np.clip(INTERVALS * position.reshape(-1, 1) - np.arange(INTERVALS), 0, 1) / INTERVALS


def fit(root, control):
    highlights = control == 'Highlights2012'
    gram = np.zeros((INTERVALS, INTERVALS))
    for datasets in [('adaptive-002', 'adaptive-ramp-', 'adaptive-calibration-001', 'adaptcal-ramp-'),
                     ('adjustments-001', 'adjust-chart-', 'response-model-001', 'adjust-chart-')]:
        levels = read_chart(root, control, *datasets)
        start = basis(coordinate(levels[0], highlights))
        end = basis(coordinate(levels[-50], highlights))
        for amount in (-10, -25):
            fraction = abs(amount) / 50
            position = coordinate(levels[amount], highlights)
            # Penalize interpolation error in linear pixel units, weighting the two charts equally.
            weight = (linear_value(position + .001, highlights) - linear_value(position - .001, highlights)) / .002
            design = ((1 - fraction) * start + fraction * end - basis(position)) * (weight.ravel() / np.sqrt(weight.size))[:, None]
            gram += design.T @ design
    # Unit mean fixes the arbitrary scale. Regularize toward a smooth, unit slope.
    mean = np.ones(INTERVALS) / INTERVALS
    difference = np.diff(np.eye(INTERVALS), axis=0)
    penalty = .01 * max(np.trace(gram) / INTERVALS, 1e-10) * (np.eye(INTERVALS) + 4 * difference.T @ difference)
    slopes = np.linalg.solve(gram + penalty + np.outer(mean, mean), penalty @ np.ones(INTERVALS) + mean)
    if not np.all((.05 < slopes) & (slopes < 8)):
        raise ValueError('The fitted coordinate is outside the calibrated slope range')
    return np.r_[0, np.cumsum(slopes) / np.sum(slopes)]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('research', type=Path, help='parent of the four registered, decoded acquisitions')
    parser.add_argument('--check', type=Path, help='check the tables in HighlightShadowKernels.metal')
    args = parser.parse_args()
    fitted = np.column_stack([fit(args.research, key) for key in ('Highlights2012', 'Shadows2012')])
    if args.check:
        table = args.check.read_text().split('negativeStrengthKnots[33] = {', 1)[1].split('};', 1)[0]
        stored = np.array(re.findall(r'float2\(([.\d]+)f, ([.\d]+)f\)', table), dtype=float)
        np.testing.assert_allclose(stored, fitted, rtol=0, atol=5.1e-9)
        print('Verified the 33 Highlights and 33 Shadows strength knots')
    else:
        for highlight, shadow in fitted:
            print(f'float2({highlight:.8f}f, {shadow:.8f}f),')
