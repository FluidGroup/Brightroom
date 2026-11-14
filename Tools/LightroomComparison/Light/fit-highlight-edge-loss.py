"""Fit how much local −50 Highlights loss to retain on the bright side of a dark edge."""
import argparse
import hashlib
from itertools import product
import json
from pathlib import Path

import numpy as np

from error_metrics import nearest_rank

LUMINANCE = np.array([.22897456, .69173852, .07928692])
RADII = (4, 16, 64, 256)


def load_samples(path):
    """Read registered rows in which both candidate renders and Lightroom use the same pixel indices."""
    manifest = json.loads(path.read_text())
    if manifest['control'] != 'Highlights2012' or manifest['amount'] != -50:
        raise ValueError('Expected registered −50 Highlights captures')
    samples = []
    sources = set()
    for entry in manifest['samples']:
        if entry['source'] in sources:
            raise ValueError(f"Duplicate calibration source {entry['id']}")
        sources.add(entry['source'])
        file = path.parent / entry['file']
        with file.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != entry['sha256']:
                raise ValueError(f'Changed calibration capture {file}')
        with np.load(file, allow_pickle=False) as capture:
            idx = capture['idx']
            n = len(idx)
            rgb = capture['rgb'].astype(float)
            guide = capture['guide'].astype(float)
            change = capture['change'].astype(float)
            error = capture['error'].astype(float)
            bands = capture['distanceBand']
        if (not n or len(np.unique(idx)) != n or bands.shape != (n,) or not np.isin(bands, range(6)).all()
                or guide.shape != (n, 5) or any(a.shape != (n, 3) for a in (rgb, change, error))
                or not all(np.isfinite(a).all() for a in (rgb, guide, change, error))):
            raise ValueError(f'Invalid paired samples in {file}')
        y = np.clip(np.clip(rgb, 0, 1) @ LUMINANCE, 0, 1)
        log_y = 1 + np.log(np.maximum(y, .0001)) / 9.3
        relative = (log_y[:, None] - guide[:, 1:]) / np.maximum(guide[:, :1], .04)
        band_masks = [bands == value for value in (2, 3, 4)]
        samples.append((entry['family'], error, change, relative, band_masks, scores(error, band_masks)))
    return samples


def scores(error, bands):
    """Measure full-color p95 and three bright-side luminance p95s selected from the source."""
    y_error = np.abs(error @ LUMINANCE)
    return np.array([nearest_rank(np.max(np.abs(error), axis=1), .95),
                     *[nearest_rank(y_error[mask], .95) if mask.sum() >= 48 else np.nan for mask in bands]])


def fit(samples):
    families = np.array([sample[0] for sample in samples])
    weights = {'photo': .50, 'chart': .30, 'cube': .20}
    if set(families) != set(weights):
        raise ValueError('Expected photographs, spatial charts and a color lattice')
    best = None
    candidates = product(enumerate(RADII), (.25, .5, 1.), (-1, 1), ('darken', 'lift', 'both'), (.5, 1.))
    for (col, radius), width, side, sign, gain in candidates:
        deltas = []
        for _, error, change, relative, masks, base in samples:
            t = np.clip(side * relative[:, col] / width, 0, 1)
            keep = gain * t * t * (3 - 2 * t)
            if sign != 'both':
                shift = change @ LUMINANCE
                keep *= shift < 0 if sign == 'darken' else shift > 0
            deltas.append(scores(error - change * keep[:, None], masks) - base)
        measurement = []
        for metric in np.array(deltas).T:
            values, family_weights = [], []
            for family, weight in weights.items():
                row = metric[(families == family) & np.isfinite(metric)]
                if len(row):
                    values.append(np.mean(row + 1.5 * np.maximum(row, 0)))
                    family_weights.append(weight)
            if not values:
                raise ValueError('No usable calibration measurements for a distance band')
            measurement.append(np.average(values, weights=family_weights))
        score = np.average(measurement, weights=(.50, .30, .15, .05))
        if best is None or score < best['score']:
            best = dict(radius=radius, width=width, side='bright' if side == 1 else 'dark',
                        shift=sign, retained=gain, score=float(score), sources=len(samples))
    return best


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(json.dumps(fit(load_samples(parser.parse_args().manifest)), indent=2, allow_nan=False))
