"""Fit negative Highlights metering from paired −50 Lightroom and Brightroom samples."""
import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

from tone_chart import digest


LUMINANCE = np.array([.22897457, .69173855, .07928692], dtype=np.float32)
# Each family has a fixed total weight, divided equally among its sources.
FAMILY_WEIGHTS = {'photo': .52, 'chart': .39, 'cube': .09}


def equations(directory, case):
    """Return the equally pixel-weighted normal equations for one registered source."""
    path = directory / case['capture']
    if digest(path) != case['captureSHA256']:
        raise ValueError(f'Changed capture {path}')
    with np.load(path, allow_pickle=False) as samples:
        indices = samples['idx']
        height, width = samples['shape']
        histogram = samples['hist']
        neutral, adjusted, adobe_neutral, adobe = (samples[k].astype(float) for k in ('x', 'e50', 'n50', 't50'))
        guide = samples['guide'].astype(float)
    if (height <= 0 or width <= 0 or indices.ndim != 1 or not len(indices)
            or not np.issubdtype(indices.dtype, np.integer) or indices.min() < 0 or indices.max() >= height * width
            or len(np.unique(indices)) != len(indices)
            or any(x.shape != (len(indices), 3) or not np.isfinite(x).all()
                   for x in (neutral, adjusted, adobe_neutral, adobe))
            or guide.shape != (len(indices), 19) or not np.isfinite(guide).all()
            or histogram.shape != (256,) or not np.issubdtype(histogram.dtype, np.integer)
            or (histogram < 0).any() or histogram.sum() != height * width):
        raise ValueError(f'Invalid registered samples in {path}')
    if case['family'] == 'cube':
        if (height, width) != (256, 1024) or not np.any(indices >= 128 * width):
            raise ValueError('Expected the registered color lattice and its two ramp strips')
        colored = indices >= 128 * width
        neutral, adjusted, adobe_neutral, adobe, guide = (x[colored] for x in (neutral, adjusted, adobe_neutral, adobe, guide))

    # The histogram covers the complete registered neutral, including both ramp strips.
    centers = (np.arange(len(histogram)) + .5) / len(histogram)
    q75, q95, q98 = np.interp([.75, .95, .98], np.cumsum(histogram) / histogram.sum(), centers)
    source = np.clip(neutral, 0, 1)
    luminance = source @ LUMINANCE
    means = guide[:, [7, 13]]
    variance = np.maximum(guide[:, [8, 14]] - means**2, 0)
    log_y = 1 + np.log(np.maximum(luminance, 1e-4)) / 9.3
    contrast = (log_y[:, None] - means) * .0064 / (variance + .0064)
    columns = np.column_stack((np.full(len(source), q95 - .88), np.full(len(source), q98 - q75 - .18), contrast))

    # Fit on grayscale agreement used for sharing the −50 loss across the scene.
    # Application of the fitted luminance correction tapers faster on saturated colors.
    agreement = np.sqrt(source.min(axis=1) / np.maximum(source.max(axis=1), 1e-7))
    loss = np.maximum(luminance - adjusted @ LUMINANCE, 0)
    design = columns * (agreement * loss)[:, None]
    residual = np.clip((neutral + (adobe - adobe_neutral) - adjusted) @ LUMINANCE, -.15, .15)
    return design.T @ design / len(source), design.T @ residual / len(source)


def fit(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    if manifest['control'] != 'Highlights2012' or manifest['space'] != 'extended-linear Display-P3 D65':
        raise ValueError('Expected neutral and negative Highlights in linear Display P3')
    by_family = defaultdict(list)
    seen = set()
    for case in manifest['cases']:
        for key in ('sourceSHA256', 'iccSHA256', 'xmpSHA256', 'referenceSHA256', 'neutralReferenceSHA256'):
            if len(case[key]) != 64 or any(c not in '0123456789abcdef' for c in case[key]):
                raise ValueError(f'Incomplete registration for {case["id"]}')
        if case['amount'] != -50 or case['sourceSHA256'] in seen:
            raise ValueError('Expected one −50 observation for each calibration source')
        seen.add(case['sourceSHA256'])
        by_family[case['family']].append(equations(manifest_path.parent, case))
    if set(by_family) != set(FAMILY_WEIGHTS):
        raise ValueError('Expected photographs, spatial charts and a color lattice')
    gram = np.zeros((4, 4))
    right = np.zeros(4)
    for family, values in by_family.items():
        weight = FAMILY_WEIGHTS[family] / len(values)
        for matrix, target in values:
            gram += weight * matrix
            right += weight * target
    coefficients = np.linalg.solve(gram + np.eye(4) * .000002, right)
    return dict(coefficients=coefficients.tolist(), counts={key: len(vals) for key, vals in by_family.items()},
                calibrationSHA256=digest(manifest_path), baselineKernel=manifest['baselineKernel'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(json.dumps(fit(parser.parse_args().manifest), indent=2, allow_nan=False))
