"""Refit the local and regional contrast gains of the negative Highlights loss."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from adaptive_data import P3_TO_ROMM


LUMINANCE = np.array([.22897456, .69173852, .07928692])
ROMM_TO_P3 = np.linalg.inv(P3_TO_ROMM)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def encode(linear):
    return np.where(linear <= .0031308, 12.92 * linear, 1.055 * np.maximum(linear, 0)**(1 / 2.4) - .055)


def sample_equations(path, case):
    """Return equally weighted normal equations for one registered source and strength."""
    amount = case['amount']
    if amount not in (-50, -100):
        raise ValueError(f"Unexpected calibration strength in {case['id']}")
    capture = path.parent / case['capture']
    if digest(capture) != case['captureSHA256']:
        raise ValueError(f'Changed capture {capture}')
    with np.load(capture, allow_pickle=False) as samples:
        indices = samples['idx']
        height, width = samples['shape']
        if (indices.ndim != 1 or len(indices) == 0 or not np.issubdtype(indices.dtype, np.integer)
                or len(np.unique(indices)) != len(indices) or indices.min() < 0 or indices.max() >= height * width):
            raise ValueError(f'Invalid source pixel indices in {capture}')
        fields = ('x', 'e50', f'e{-amount}', f'n{-amount}', f't{-amount}')
        rgb = [samples[key].astype(float) for key in fields]
        if 'guide' in samples:
            guides = samples['guide'].astype(float)
        else:
            guide = path.parent / case['guide']
            if digest(guide) != case['guideSHA256']:
                raise ValueError(f'Changed luminance guides {guide}')
            guides = np.fromfile(guide, '<f4').reshape(-1, 19).astype(float)
    if (any(x.shape != (len(indices), 3) or not np.isfinite(x).all() for x in rgb)
            or guides.shape != (len(indices), 19) or not np.isfinite(guides).all()):
        raise ValueError(f'Unpaired color samples or guides in {capture}')
    if case['colorLattice']:
        if (height, width) != (256, 1024):
            raise ValueError(f'Unexpected color lattice size in {capture}')
        color_rows = indices >= 128 * width
        if not color_rows.any():
            raise ValueError(f'No color patches in {capture}')
        rgb = [x[color_rows] for x in rgb]
        guides = guides[color_rows]

    original, halfway, adjusted, adobe_neutral, adobe_adjusted = rgb
    source = np.clip(original, 0, 1)
    # HDR passthrough is added after processing. Fit the same SDR portion.
    halfway += source - original
    adjusted += source - original
    target = source + (adobe_adjusted - adobe_neutral)
    romm = source @ P3_TO_ROMM.T
    clipped = np.clip(romm, 0, 1)
    chroma = np.ptp(clipped, axis=1) / (clipped.max(axis=1) + .025)
    luminance = source @ LUMINANCE
    # The 19-float capture contains the scene mean at 3 and blurred means at 7 and 13.
    near, region, scene = encode(np.exp((guides[:, [7, 13, 3]] - 1) * 9.3)).T
    contrast = np.column_stack((near - encode(luminance), region - scene)) * chroma[:, None]

    loss = np.maximum(romm - adjusted @ P3_TO_ROMM.T, 0)
    half_loss = np.maximum(romm - halfway @ P3_TO_ROMM.T, 0)
    half_luminance_loss = np.maximum((source - halfway) @ LUMINANCE, 0)
    # The sensitivity of the neutral −50 shift vanishes when a channel has no loss.
    ratio = np.minimum(half_luminance_loss[:, None] / np.maximum(half_loss, 1e-7), 8)
    weak = np.minimum(half_loss, loss) * ratio
    extra = np.maximum(loss - half_loss, 0)
    directions = [-change @ ROMM_TO_P3.T for change in (weak, extra)]
    matrix = np.concatenate([contrast[:, None, :] * d[:, :, None] for d in directions], axis=2).reshape(-1, 4)
    residual = (target - adjusted).ravel()
    return matrix.T @ matrix / len(residual), matrix.T @ residual / len(residual)


def fit(path):
    manifest = json.loads(path.read_text())
    if manifest['control'] != 'Highlights2012' or manifest['space'] != 'extended-linear Display-P3 D65':
        raise ValueError('Expected common-input negative Highlights captures in linear Display P3')
    cases = manifest['cases']
    provenance = ['sourceSHA256', 'xmpSHA256', 'iccSHA256', 'referenceSHA256', 'neutralReferenceSHA256']
    for case in cases:
        if not all(len(case[field]) == 64 and all(c in '0123456789abcdef' for c in case[field]) for field in provenance):
            raise ValueError(f"Incomplete registration for {case['id']}")
    keys = {(c['sourceSHA256'], c['amount']) for c in cases}
    if len(keys) != len(cases) or {v for _, v in keys} != {-50, -100}:
        raise ValueError('Expected both calibrated strengths and one capture per source and strength')
    equations = [sample_equations(path, c) for c in cases]
    gram = sum(a for a, _ in equations)
    right = sum(b for _, b in equations)
    scale = np.diag(gram)
    if np.any(scale <= 0):
        raise ValueError('The captures do not excite both contrast signals in each interval')
    ridge = .05 * np.maximum(scale, .02 * scale.max()) + 1e-12
    coefficients = np.linalg.solve(gram + np.diag(ridge), right).reshape(2, 2)
    return dict(halfGain=coefficients[0].tolist(), extraGain=coefficients[1].tolist(),
                weakSources=sum(c['amount'] == -50 for c in cases),
                strongSources=sum(c['amount'] == -100 for c in cases),
                manifestSHA256=digest(path), baselineKernel=manifest['baselineKernel'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path, help='Registered paired Lightroom exports and baseline GPU samples')
    print(json.dumps(fit(parser.parse_args().manifest), indent=2, allow_nan=False))
