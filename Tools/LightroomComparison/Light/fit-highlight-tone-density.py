"""Refit the two negative-Highlights gains from the density of neighboring scene tones."""
import argparse
from collections import Counter
import json
from pathlib import Path

import numpy as np

from adaptive_data import P3_TO_ROMM
from tone_chart import digest


LUMINANCE = np.array([.22897456, .69173852, .07928692], dtype='f4')
FAMILY_WEIGHT = {'photo': .62, 'chart': .28, 'cube': .10}


def equations(directory, case):
    """Form the RGB loss fit for the registered positions of one −50 pair."""
    file = directory / case['file']
    if digest(file) != case['sha256']:
        raise ValueError(f'Changed calibration capture {file}')
    with np.load(file, allow_pickle=False) as sample:
        indices, (height, width), mass = (sample[key] for key in ('idx', 'shape', 'hist'))
        source, adjusted, neutral, adobe = (sample[key] for key in ('x', 'e50', 'n50', 't50'))
    if (height <= 0 or width <= 0 or indices.ndim != 1 or not len(indices)
            or not np.issubdtype(indices.dtype, np.integer) or len(np.unique(indices)) != len(indices)
            or indices.min() < 0 or indices.max() >= height * width
            or mass.shape != (128,) or not np.isfinite(mass).all() or mass.min() < 0 or mass.max() > 1
            or any(rgb.shape != (len(indices), 3) or not np.isfinite(rgb).all()
                   for rgb in (source, adjusted, neutral, adobe))):
        raise ValueError(f'Invalid sample or histogram in {file}')
    if case['family'] == 'cube':
        if (height, width) != (256, 1024):
            raise ValueError('Expected the registered 32³ color lattice')
        # Keep both gray ramps for validation.
        colored = indices >= width * (height // 2)
        source, adjusted, neutral, adobe = (rgb[colored] for rgb in (source, adjusted, neutral, adobe))

    rgb = np.clip(source, 0, 1)
    luminance = rgb @ LUMINANCE
    code = np.where(luminance <= .0031308, 12.92 * luminance, 1.055 * luminance ** (1 / 2.4) - .055)
    centers = (np.arange(128) + .5) / 128
    center = np.interp(code, centers, mass)
    darker = np.interp(code - .09, centers, mass)
    brighter = np.interp(code + .09, centers, mass)

    # Near the P3 black boundary, the renderer gives more weight to its peak-channel fit.
    low = rgb.min(axis=1)
    margin = .4 * (np.clip(rgb @ P3_TO_ROMM.T, 0, 1).min(axis=1) - low)
    v = np.clip(low / np.maximum(margin, 1e-8), 0, 1)
    weight = np.where((margin > low) & (np.ptp(rgb, axis=1) > 1e-6), v * v * (3 - 2 * v), 1)
    side = np.column_stack((darker, brighter))
    # A missing darker or brighter tone is also common at the endpoint of a ramp.
    represented = np.clip(np.minimum(center[:, None], side) / .014, 0, 1)
    support = represented ** 2 * (3 - 2 * represented)
    excess = np.maximum(center[:, None] - side, 0) * support
    columns = excess * ((1 - code) ** 2 * weight)[:, None]
    loss = source - adjusted
    residual = adjusted - (source + adobe - neutral)
    # Equalize the influence of pictures with different absolute levels of residual error.
    scale = len(rgb) * max(.004, np.percentile(abs(residual).max(axis=1), 95)) ** 2
    gram = columns.T @ (columns * (loss ** 2).sum(axis=1)[:, None])
    target = columns.T @ (-(loss * residual).sum(axis=1))
    return gram / scale, target / scale


def fit(path):
    manifest = json.loads(path.read_text())
    cases = manifest['cases']
    counts = Counter(case['family'] for case in cases)
    if (manifest['control'] != 'Highlights2012' or manifest['space'] != 'extended-linear Display P3'
            or set(counts) != set(FAMILY_WEIGHT) or len({c['source'] for c in cases}) != len(cases)
            or any(c['amount'] != -50 for c in cases)):
        raise ValueError('Expected distinct −50 photographs, spatial charts and a color lattice in linear P3')
    gram, target = np.zeros((2, 2)), np.zeros(2)
    for case in cases:
        matrix, vector = equations(path.parent, case)
        weight = FAMILY_WEIGHT[case['family']] / counts[case['family']]
        gram += weight * matrix
        target += weight * vector
    ridge = .125 * np.maximum(gram.diagonal(), 1e-6) + 1e-8
    darker, brighter = np.linalg.solve(gram + np.diag(ridge), target)
    return dict(darker=darker, brighter=brighter, sources=counts, baselineKernel=manifest['baselineKernel'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(json.dumps(fit(parser.parse_args().manifest), indent=2, allow_nan=False))
