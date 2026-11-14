"""Recover the joint Highlights/Shadows response from registered Lightroom TIFFs.

The RGB chart has a neutral, separate slider sweeps and one two-slider export.
Fit the effective solo strengths whose summed changes best explain that export.
All samples are measured in extended-linear Display P3 after ICC conversion.
"""
import argparse
import hashlib
from itertools import product
import json
from pathlib import Path

import numpy as np

from adaptive_data import FrozenSet


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fit_interval(columns, target, upper):
    """Find the least-squares minimum inside a two-slider rectangle or on its edges."""
    estimate = np.linalg.lstsq(columns, target, rcond=None)[0]
    candidates = [np.clip(estimate, 0, upper)]
    for fixed, free in [(0, 1), (1, 0)]:
        direction = columns[:, free]
        energy = np.dot(direction, direction)
        for edge in (0, upper[fixed]):
            remainder = target - edge * columns[:, fixed]
            fraction = np.zeros(2)
            fraction[fixed] = edge
            if energy > 0:
                fraction[free] = np.clip(np.dot(remainder, direction) / energy, 0, upper[free])
            candidates.append(fraction)
    return min(((np.linalg.norm(columns @ x - target), x) for x in candidates), key=lambda result: result[0])


def measure(steps, endpoints):
    acquisitions = [FrozenSet(steps), FrozenSet(endpoints)]
    registrations = [{r['id']: r for r in json.loads((data.root / 'cases.json').read_text())['cases']}
                     for data in acquisitions]
    neutral_id = 'adjust-chart-neutral'
    source_hash = registrations[0][neutral_id]['inputSHA256']

    def read(index, name, highlights=0, shadows=0):
        data = acquisitions[index]
        case, reference = registrations[index][name], data.references[name]
        controls = {'Highlights2012': highlights, 'Shadows2012': shadows}
        neutral = data.references[neutral_id]['resolvedSettings']
        settings = reference['resolvedSettings']
        if ({k: v for k, v in controls.items() if v} != case['parameters']
                or any(float(settings[k]) != v for k, v in controls.items())
                or any(settings.get(k) != neutral.get(k) for k in (neutral.keys() | settings.keys())
                       if k not in controls and k != 'RawFileName')
                or digest(case['input']) != case['inputSHA256'] or case['inputSHA256'] != source_hash
                or digest(case['settings']) != case['settingsSHA256']
                or case['settingsSHA256'] != reference['settingsSHA256']
                or data.decoded[name]['space'] != 'extended-linear Display-P3 D65'):
            raise ValueError(f'Incompatible calibration case {name}')
        rgb = data.read(name)[..., :3]
        if rgb.shape != (256, 1024, 3):
            raise ValueError(f'Unexpected RGB chart dimensions at {name}: {rgb.shape}')
        return rgb.astype(np.float64)

    neutral = [read(i, neutral_id) for i in range(2)]
    if not np.array_equal(neutral[0], neutral[1]):
        raise ValueError('The two sweeps must have the same neutral pixels')
    joint_amount = np.array([35, 42])
    joint = read(0, 'adjust-chart-hs', -35, 42) - neutral[0]
    knots = [0, 10, 25, 50]
    sweeps = []
    for control in ('Highlights', 'Shadows'):
        sweep = [np.zeros_like(joint)]
        for amount in knots[1:]:
            i = int(amount == 50)
            signed = -amount if control == 'Highlights' else amount
            values = {'highlights': signed} if control == 'Highlights' else {'shadows': signed}
            sweep.append(read(i, f'adjust-chart-{control}2012-{signed}', **values) - neutral[i])
        sweeps.append(sweep)

    # Each pair of adjacent slider intervals is linear in its two fractions.
    # Solve every rectangle so the result is independent of a starting guess.
    best = None
    for i, j in product(range(len(knots) - 1), repeat=2):
        low = np.array([knots[i], knots[j]])
        width = np.array([knots[i + 1], knots[j + 1]]) - low
        columns = np.column_stack([(sweeps[0][i + 1] - sweeps[0][i]).ravel(),
                                   (sweeps[1][j + 1] - sweeps[1][j]).ravel()])
        residual = (joint - sweeps[0][i] - sweeps[1][j]).ravel()
        error, fraction = fit_interval(columns, residual, np.minimum(1, (joint_amount - low) / width))
        if best is None or error < best[0]:
            best = error, low + fraction * width

    effective = best[1]
    coefficients = (joint_amount / effective - 1) / joint_amount[::-1]
    return dict(highlightsPerShadow=float(coefficients[0]), shadowsPerHighlight=float(coefficients[1]),
                chartSHA256=source_hash, pixels=int(np.prod(joint.shape[:2])),
                effectiveSoloAtMinus35Plus42=[-float(effective[0]), float(effective[1])],
                calibration=[data.evidence for data in acquisitions])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('steps', type=Path, help='registration with the ±10, ±25 and joint chart exports')
    parser.add_argument('endpoints', type=Path, help='registration with the ±50 chart exports')
    args = parser.parse_args()
    print(json.dumps(measure(args.steps, args.endpoints), indent=2, allow_nan=False))
