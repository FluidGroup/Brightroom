"""Fit the local contrast contribution to the −50 Shadows endpoint from paired 16-bit exports."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import numpy as np

from adaptive_data import P3_TO_ROMM

LUMINANCE = np.array([.22897457, .69173855, .07928692])
FAMILY_WEIGHT = {'photo': .55, 'chart': .30, 'cube': .15}


def smoothstep(value):
    t = np.clip(value, 0, 1)
    return t * t * (3 - 2 * t)


def equations(path, entry):
    """Return one image's normal equations, giving each of its sampled pixels the same base weight."""
    file = path.parent / entry['file']
    with file.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != entry['sha256']:
            raise ValueError(f'Changed calibration capture {file}')
    with np.load(file, allow_pickle=False) as capture:
        indices = capture['idx']
        guide = capture['guide'].astype(float)
        source, native, neutral, target = (capture[key].astype(float) for key in ('x', 'e50', 'n50', 't50'))
    size = len(indices)
    if (not size or len(np.unique(indices)) != size or guide.shape != (size, 19)
            or any(a.shape != (size, 3) for a in (source, native, neutral, target))
            or not all(np.isfinite(a).all() for a in (source, native, neutral, target, guide))):
        raise ValueError(f'Invalid matched pixel samples in {file}')

    # The first three guide channels are linear P3. Columns 7 and 8 hold the
    # first and second moments of log luminance in the four-pixel Gaussian guide.
    rgb = np.clip(guide[:, :3], 0, 1)
    y = rgb @ LUMINANCE
    code = np.where(y <= .0031308, 12.92 * y, 1.055 * y ** (1 / 2.4) - .055)
    dark = 1 - smoothstep((code - .18) / (.45 - .18))
    local = guide[:, 7]
    contrast = 1 + np.log(np.maximum(y, .0001)) / 9.3 - local
    variance = np.maximum(guide[:, 8] - local * local, 0)
    low_variance = .0064 / (variance + .0064)

    low = rgb.min(axis=1)
    margin = .4 * ((rgb @ P3_TO_ROMM.T).min(axis=1) - low)
    in_gamut = np.where(margin > low, smoothstep(low / np.maximum(margin, 1e-8)), 1)
    activity = smoothstep((guide[:, 5] - .001) / .012) * in_gamut
    # Derivative of linear luminance with respect to the calibrated log odds.
    room = (y + .000228) * (1.17866 - y) / 1.178888
    columns = (contrast * activity * dark * room)[:, None] * np.column_stack((dark, low_variance))
    residual = (native - source) - (target - neutral)
    maximum = np.max(np.abs(residual), axis=1)
    weights = (.4 + 1.6 * (maximum >= np.quantile(maximum, .82))) / size
    return columns.T @ (columns * weights[:, None]), columns.T @ ((residual @ LUMINANCE) * weights)


def fit(path):
    manifest = json.loads(path.read_text())
    if manifest['control'] != 'Shadows2012' or manifest['amount'] != -50:
        raise ValueError('Expected a negative Shadows calibration at −50')
    rows = manifest['samples']
    counts = Counter(row['family'] for row in rows)
    if set(counts) != set(FAMILY_WEIGHT) or len({row['source'] for row in rows}) != len(rows):
        raise ValueError('Expected distinct photographs, spatial charts and a color lattice')
    lhs, rhs = np.zeros((2, 2)), np.zeros(2)
    for row in rows:
        matrix, vector = equations(path, row)
        weight = FAMILY_WEIGHT[row['family']] / counts[row['family']]
        lhs += weight * matrix
        rhs += weight * vector
    penalty = .025 * np.diag(np.maximum(np.diag(lhs), .00004))
    dark, low_variance = np.linalg.solve(lhs + penalty, rhs)
    return dict(sources=counts, baselineKernel=manifest['baselineKernel'],
                darkContrast=float(dark), lowVarianceContrast=float(low_variance))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(json.dumps(fit(parser.parse_args().manifest), indent=2, allow_nan=False))
