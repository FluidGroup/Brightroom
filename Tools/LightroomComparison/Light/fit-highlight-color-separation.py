"""Fit the common change in the two ProPhoto extrema at a measured Highlights luminance."""
import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.optimize import least_squares

from adaptive_data import FrozenSet, P3_TO_ROMM
from tone_chart import digest


LUMINANCE = np.array([.22897456, .69173852, .07928692], dtype='f4')


@lru_cache(maxsize=None)
def catalog(folder):
    rows = json.loads((Path(folder) / 'cases.json').read_text())['cases']
    return FrozenSet(folder), {r['id']: r for r in rows}


def registered_pixels(case, *, neutral):
    """Verify the input, effective slider, XMP and export profile for either half of a pair."""
    folder = case['neutralRoot'] if neutral else case['root']
    key = case['neutralID'] if neutral else case['id']
    expected = case['neutralReferenceSHA256'] if neutral else case['referenceSHA256']
    frozen, rows = catalog(folder)
    row = rows[key]
    reference = frozen.references[key]
    parameters = {} if neutral else {'Highlights2012': -50}
    if (row['inputSHA256'] != case['source'] or row['parameters'] != parameters
            or digest(row['settings']) != reference['settingsSHA256']
            or row['settingsSHA256'] != reference['settingsSHA256']
            or (not neutral and case['xmp'] != reference['settingsSHA256'])
            or float(reference['resolvedSettings']['Highlights2012']) != parameters.get('Highlights2012', 0)
            or reference['referenceSHA256'] != expected
            or frozen.decoded[key]['space'] != 'extended-linear Display-P3 D65'):
        raise ValueError(f'Unpaired Highlights reference {key}')
    with Image.open(Path(folder) / reference['reference']) as image:
        if hashlib.sha256(image.info['icc_profile']).hexdigest() != case['icc']:
            raise ValueError(f'Changed reference profile for {key}')
    return frozen.read(key)[..., :3]


def sample(case):
    """Take the original hue line and measured separation at matching spatial positions."""
    if digest(case['file']) != case['source']:
        raise ValueError(f"Changed input for {case['id']}")
    neutral = registered_pixels(case, neutral=True)
    measured = registered_pixels(case, neutral=False)
    if neutral.shape != measured.shape:
        raise ValueError(f"Changed dimensions for {case['id']}")
    size = neutral.shape[0] * neutral.shape[1]
    rng = np.random.default_rng(int(case['source'][:12], 16))
    indices = rng.choice(size, min(size, 10_000), replace=False)
    source, target = [v.reshape(-1, 3)[indices].astype('f8') for v in (neutral, measured)]
    # Use the same transform precision as the public Metal kernel.
    transform = P3_TO_ROMM.astype('f4').T
    original, adjusted = source @ transform, target @ transform
    row = np.arange(len(source))
    low_index, high_index = original.argmin(axis=1), original.argmax(axis=1)
    low, high = original[row, low_index], original[row, high_index]
    luminance, target_luminance = source @ LUMINANCE, target @ LUMINANCE
    spread = np.ptp(source, axis=1)
    usable = (spread > .01) & (luminance - target_luminance > .002) & (low >= -.001) & (high <= 1.001)
    selected = np.flatnonzero(usable)[::3]
    position = (luminance - low) / np.maximum(high - low, 1e-8)
    target_span = adjusted[row, high_index] - adjusted[row, low_index]
    p3_scale = spread / np.maximum(high - low, 1e-8)
    return np.column_stack((low, high, position, target_luminance, target_span, p3_scale))[selected]


def fit(samples):
    low, high, position, target, target_span, p3_scale = np.concatenate(samples).T
    weights = np.concatenate([np.full(len(s), np.sqrt(1000 / len(s))) for s in samples])

    def residual(parameters):
        black, white = np.exp(parameters) + [0, 1]
        width = white + black
        left, right = (low + black) / width, (high + black) / width
        span = right - left
        level = (target + black) / width
        # At fixed target luminance, preserving the odds ratio between the two
        # channels gives a quadratic for the change in their separation.
        a = position * (1 - position) * span**2
        b = left * (1 - right) + span * (level + position * (1 - 2 * level))
        c = level * (1 - level)
        slope = 2 * c / np.maximum(b + np.sqrt(np.maximum(b * b - 4 * a * c, 0)), 1e-12)
        return ((high - low) * slope - target_span) * p3_scale * weights

    result = least_squares(residual, np.log([.03, .2]), bounds=(-14, 4), loss='soft_l1', f_scale=.002)
    if not result.success:
        raise ValueError(result.message)
    return np.exp(result.x) + [0, 1]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path, help='Signed comparison manifest with whole-image fit flags')
    args = parser.parse_args()
    samples = {}
    for case in json.loads(args.cases.read_text())['cases']:
        if (case['fit'] and case['control'] == 'Highlights2012' and case['amount'] == -50
                and (case['kind'] == 'photo' or 'color' in case['sourceId'])):
            pixels = sample(case)
            if len(pixels) >= 45:
                if case['source'] in samples:
                    raise ValueError(f"Duplicate calibration input for {case['id']}")
                samples[case['source']] = pixels
    if not samples:
        parser.error('No registered −50 calibration pairs with measurable color separation')
    black, white = fit(list(samples.values()))
    print(json.dumps(dict(blackRoom=black, whiteLimit=white,
                          pixelsBySource={key: len(s) for key, s in samples.items()}), indent=2))
