"""Fit the fraction of negative Highlights loss retained at four neighborhood sizes."""
import argparse
from collections import Counter
import json
from pathlib import Path

import numpy as np

from tone_chart import digest


FAMILY_WEIGHTS = {'photo': .62, 'chart': .28, 'cube': .10}
LUMINANCE = np.array([.22897457, .69173855, .07928692], dtype=np.float32)


def normal_equations(manifest, entry):
    """Measure the signed change from each renderer's own neutral at matching pixels."""
    path = manifest.parent / entry['file']
    if digest(path) != entry['sha256']:
        raise ValueError(f'Changed calibration capture {path}')
    with np.load(path, allow_pickle=False) as sample:
        index = sample['idx']
        height, width = sample['shape']
        guide = sample['guide']
        source, native, neutral, adobe = (sample[key].astype(np.float64) for key in ('x', 'e50', 'n50', 't50'))
    size = len(index)
    if (size == 0 or len(np.unique(index)) != size or np.any(index < 0) or np.any(index >= width * height)
            or guide.shape != (size, 19) or not np.all(np.isfinite(guide))
            or any(rgb.shape != (size, 3) or not np.all(np.isfinite(rgb)) for rgb in (source, native, neutral, adobe))):
        raise ValueError(f'Invalid matched pixel positions in {path}')

    y = np.clip(source, 0., 1.) @ LUMINANCE
    code = np.where(y <= .0031308, 12.92 * y, 1.055 * y ** (1 / 2.4) - .055)
    log_y = 1 + np.log(np.maximum(y, .0001)) / 9.3
    # Each guide stores the first and second moments of normalized log luminance.
    means = guide[:, [7, 10, 13, 16]]
    variance = np.maximum(guide[:, [8, 11, 14, 17]] - means ** 2, 0.)
    width_in_log = .05 / np.maximum((code + .055) * 9.3 / 2.4, .05)
    z = (log_y[:, None] - means) / np.sqrt(variance + width_in_log[:, None] ** 2)
    ranks = 1 / (1 + np.exp(-1.7 * np.clip(z, -50, 50))) - .5
    detail = np.clip(1 - (guide[:, 5] / np.maximum(guide[:, 4], 1e-7)) ** 2, 0., 1.)
    regional = ranks[:, 2] - ranks[:, 3]
    terms = np.column_stack((
        detail * ranks[:, 0], ranks[:, 0] - ranks[:, 1],
        regional * np.clip(1 - 2 * code, 0, 1), regional * np.maximum(1 - abs(2 * code - 1), 0),
        regional * np.maximum(2 * code - 1, 0),
    ))
    loss = source - native
    residual = native - (source + adobe - neutral)
    if entry['family'] == 'cube':
        if (width, height) != (1024, 256):
            raise ValueError('Expected the registered 32-cubed color lattice and its two gray ramps')
        # Only the lower half contains the color lattice. Leave both gray ramps out of the fit.
        keep = index >= width * (height // 2)
        terms, loss, residual = terms[keep], loss[keep], residual[keep]
    error = np.abs(residual).max(axis=1)
    p95 = max(np.quantile(error, .95, method='inverted_cdf'), .004)
    weight = (.35 + .65 * np.minimum(1., error / (p95 + .0001))) / (len(error) * (p95 + .01) ** 1.5)
    lhs = terms.T @ ((weight * (loss * loss).sum(axis=1))[:, None] * terms)
    rhs = terms.T @ (weight * (-loss * residual).sum(axis=1))
    return lhs, rhs


def fit(path):
    manifest = json.loads(path.read_text())
    samples = manifest['samples']
    counts = Counter(row['family'] for row in samples)
    if (manifest['control'] != 'Highlights2012' or manifest['amount'] != -50
            or set(counts) != set(FAMILY_WEIGHTS) or len({r['source'] for r in samples}) != len(samples)):
        raise ValueError('Expected distinct photographs, charts and a lattice with registered Highlights −50 pairs')
    lhs, rhs = np.zeros((5, 5)), np.zeros(5)
    for entry in samples:
        matrix, vector = normal_equations(path, entry)
        weight = FAMILY_WEIGHTS[entry['family']] / counts[entry['family']]
        lhs += weight * matrix
        rhs += weight * vector
    ridge = .5 * np.maximum(lhs.diagonal(), 1e-6) + 1e-10
    fine, local, dark, middle, light = np.linalg.solve(lhs + np.diag(ridge), rhs)
    return dict(sources=counts, baselineKernel=manifest['baselineKernel'], fineDetail=fine, local=local,
                regionalByTone=[dark, middle, light])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(json.dumps(fit(parser.parse_args().manifest), indent=2, allow_nan=False))
