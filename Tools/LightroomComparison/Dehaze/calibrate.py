"""Reproduce the measured Dehaze endpoint weights from a registered SDR reference set.

Run Light/decode.swift on the registered Lightroom TIFFs first. Calibration uses
whole sources marked 'calibration' in cases.json. The normal A10 runner measures
the public Metal implementation on both calibration and validation photographs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image
from scipy.linalg import solve
from scipy.ndimage import gaussian_filter, minimum_filter

TOOLS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(TOOLS / 'Light'), str(TOOLS / 'A10')]
from adaptive_data import FrozenSet
from tone_chart import digest
from xmp_settings import read_adjustments

LEVELS = (-100, -50, 9, 50, 100)
LUMA = np.array([0.22897457, 0.69173855, 0.07928692])
P3_TO_ROMM = np.array([
    [0.63169122, 0.21392818, 0.15438059],
    [0.08320432, 0.88585751, 0.03093817],
    [-0.00127273, 0.05075510, 0.95051763],
])


def reference(catalog, case, neutral, amount):
    """Read the registered TIFF in linear P3 after binding the scene, XMP and profile."""
    key = case['id']
    ref = catalog.references[key]
    expected = {'Dehaze': amount} if amount else {}
    settings, curves = read_adjustments(Path(case['settings']))
    zero, base_curves = read_adjustments(Path(neutral['settings']))
    with Image.open(catalog.root / ref['reference']) as image:
        icc = hashlib.sha256(image.info['icc_profile']).hexdigest()
        size = image.size
    inspection = ref['inspection']
    decoded = catalog.decoded[key]
    if (case['parameters'] != expected or curves != base_curves or
            any(settings.get(k) != zero.get(k) for k in settings.keys() | zero.keys() if k != 'Dehaze') or
            float(zero.get('Dehaze', 0)) != 0 or float(settings.get('Dehaze', 0)) != amount or
            float(ref['resolvedSettings'].get('Dehaze', 0)) != amount or
            digest(case['settings']) != case['settingsSHA256'] or ref['settingsSHA256'] != case['settingsSHA256'] or
            digest(case['input']) != case['inputSHA256'] or case['inputSHA256'] != neutral['inputSHA256'] or
            inspection['bits'] != 16 or inspection['profile'] != 'ProPhoto RGB' or
            inspection['iccSHA256'] != icc or catalog.references[neutral['id']]['inspection']['iccSHA256'] != icc or
            size != (decoded['width'], decoded['height']) or decoded['space'] != 'extended-linear Display-P3 D65'):
        raise ValueError(f'Expected one signed Dehaze change on the same registered source and profile: {key}')
    return catalog.read(key)[..., :3]


def sample_scene(catalog, neutral, cases):
    """Calculate neighborhood guides before drawing a repeatable, equally sized sample from each scene."""
    rgb = reference(catalog, neutral, neutral, 0).astype(np.float64)
    y = rgb @ LUMA
    dark = np.clip((rgb @ P3_TO_ROMM.T).min(axis=-1), 0, 1)
    radius = max(0.5, 16 * max(y.shape) / 1024)
    minimum = minimum_filter(dark, size=2 * round(radius) + 1, mode='nearest')
    local = gaussian_filter(minimum, radius / 3, mode='nearest')
    broad = gaussian_filter(dark, radius * 4, mode='nearest')
    air = np.clip(gaussian_filter(y, radius * 4, mode='nearest').max(), 1 / 255, 1)
    scene_dark = np.sqrt(local.mean() / air)
    indices = np.random.default_rng(918).choice(y.size, min(14000, y.size), replace=False)
    def sample(image):
        return image.reshape((-1,) + image.shape[2:])[indices]
    near = np.sqrt(np.clip(sample(local) / air, 0, 1))
    far = np.sqrt(np.clip(sample(broad) / air, 0, 1))
    source = sample(rgb)
    luminance = sample(y)
    root = np.sqrt(np.clip(luminance / air, 0, 3))
    base = np.column_stack((near, far * scene_dark, np.full_like(near, scene_dark), near * far,
                            scene_dark * root, near * root, far * scene_dark * root))
    chroma = source - luminance[:, None]
    rows = {}
    for case in cases:
        amount = case['parameters']['Dehaze']
        target = reference(catalog, case, neutral, amount)
        delta = sample(target) - source
        relative = root + (0.16 if amount == -100 else 0)
        if amount > 0:
            relative = np.maximum(relative, np.sqrt(0.00001))
        weight = max(0.001, np.quantile(np.abs(delta).max(axis=-1), 0.95)) ** 0.65
        light = ((air - luminance) * relative / (0.35 + relative))[:, None] * base
        color = (base[:, :, None] * chroma[:, None, :]).transpose(0, 2, 1).reshape(-1, base.shape[1])
        dy = delta @ LUMA
        rows[amount] = (light / weight, dy / weight, color / weight, (delta - dy[:, None]).ravel() / weight)
    return rows


def fit(designs, targets):
    """Ridge fit chosen by leaving one complete calibration scene out at a time."""
    a = np.concatenate(designs)
    b = np.concatenate(targets)
    gram = a.T @ a
    penalty = 0.2 * (np.diag(gram).mean() + 1e-9)
    return solve(gram + np.eye(a.shape[1]) * penalty, a.T @ b, assume_a='pos').tolist()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registration', type=Path)
    parser.add_argument('output', type=Path, help='new JSON file for the five measured endpoint weights and source identities')
    args = parser.parse_args()
    catalog = FrozenSet(args.registration)
    cases = json.loads((catalog.root / 'cases.json').read_text())['cases']
    controls = [case for case in cases if case['group'] == 'presence-dehaze']
    grouped = {}
    for case in controls:
        grouped.setdefault(case['inputSHA256'], []).append(case)
    samples = []
    for source, group in grouped.items():
        roles = {case['role'] for case in group}
        if roles == {'validation'}:
            continue
        if roles != {'calibration'} or sorted(case['parameters'].get('Dehaze') for case in group) != list(LEVELS):
            raise ValueError(f'Expected a whole calibration source with all five isolated endpoints: {source}')
        neutral, = [c for c in cases if c['group'] == 'neutral' and c['inputSHA256'] == source]
        samples.append(sample_scene(catalog, neutral, group))
    if not samples:
        raise ValueError('No registered calibration scenes')
    weights = {}
    for amount in LEVELS:
        light, luma_change, color, chroma_change = zip(*(scene[amount] for scene in samples))
        weights[amount] = [fit(light, luma_change), fit(color, chroma_change)]
    with args.output.open('x') as out:
        json.dump({'coefficients': weights, 'sources': catalog.evidence}, out, indent=2, allow_nan=False)
        out.write('\n')


if __name__ == '__main__':
    main()
