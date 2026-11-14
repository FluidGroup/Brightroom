"""Fit signed Texture gains from registered calibration sources, using each original's decoded RGB."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

import numpy as np
from scipy.ndimage import gaussian_filter
from scipy.optimize import nnls

TOOLS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(TOOLS / 'Light'), str(TOOLS / 'A10')]
from adaptive_data import P3_TO_ROMM
from error_metrics import nearest_rank
from paired_light import read, decode
from presence_reference import CONTROLS, changes, registered
from measure_frequencies import measure, verify_input

LEVELS = (-100, -50, 4, 50, 100)


def encode(rgb):
    return np.where(rgb < .0031308, 12.92 * rgb, 1.055 * np.maximum(rgb, 0) ** (1 / 2.4) - .055)


def scene_equations(source, neutral, targets):
    """Measure each RGB channel relative to a 12-pixel Gaussian neighborhood."""
    rgb = np.clip(source @ P3_TO_ROMM.T, 0, 1)
    code = encode(rgb)

    def blur(values):
        return gaussian_filter(values.astype('f4'), (12, 12, 0), mode='nearest')

    mean = blur(code)
    deviation = np.sqrt(np.maximum(blur(code * code) - mean * mean, 0))
    # Retain identical spatial samples at every strength and equal weight per scene.
    indices = np.random.default_rng(295).choice(mean.shape[0] * mean.shape[1], 10000, replace=False)

    def sample(value):
        return value.reshape(-1, 3)[indices].astype('f8')

    detail = sample(code - mean) / (1 + 48 * sample(deviation))
    original = sample(rgb)
    value = encode(original)
    weights = np.maximum(1 - np.abs(2 * value[..., None] - np.arange(3)), 0)
    matrix = (detail[..., None] * weights).reshape(-1, 3)
    gram = matrix.T @ matrix
    result = {}
    for amount, target in targets.items():
        delta = sample(target - neutral)
        wanted = encode(np.clip(original + delta @ P3_TO_ROMM.T, 0, 1)) - value
        scale = max(.0001, nearest_rank(np.abs(delta).max(axis=1), .95))
        normalization = len(original) * scale * scale
        result[amount] = gram / normalization, matrix.T @ wanted.ravel() / normalization
    return result


def calibrate(root, decoder, frequency_neutral):
    cases = {c['id']: c for c in read(root / 'cases.json')['cases']}
    refs = {r['id']: r for r in read(root / 'references.json')['references']}
    sets = defaultdict(list)
    for c in cases.values():
        if c['group'] == 'presence-texture':
            sets[c['inputSHA256']].append(c)
    equations, receipts = [], []
    limits = {}
    for key, edits in sets.items():
        roles = {c['role'] for c in edits}
        if roles == {'evaluate'}:
            continue
        if roles != {'fit'} or sorted(c['parameters'].get('Texture') for c in edits) != list(LEVELS):
            raise ValueError(f'Incomplete Texture calibration scene for {key}')
        control, = [c for c in cases.values() if c['inputSHA256'] == key and c['group'] == 'neutral']
        neutral = registered(root, cases, refs, control['id'])
        if (neutral['declared'] or neutral['proof']['processVersion'] != '15.4'
                or any(float(neutral['applied'][k]) != 0 for k in CONTROLS)):
            raise ValueError(f'Expected neutral PV 15.4 reference for {key}')
        receipts.append(neutral['proof'])
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source = decode(Path(control['input']), decoder, directory / 'source')
            zero = decode(neutral['path'], decoder, directory / 'neutral')
            targets = {}
            for c in edits:
                edit = registered(root, cases, refs, c['id'])
                amount = c['parameters']['Texture']
                if changes(neutral, edit) != {'Texture': amount}:
                    raise ValueError(f'Expected an isolated Texture change in {c["id"]}')
                targets[amount] = decode(edit['path'], decoder, directory / str(amount))
                receipts.append(edit['proof'])
            equations.append(scene_equations(source, zero, targets))
            if control['id'] == frequency_neutral:
                verify_input(source)
                for amount, target in targets.items():
                    tiles = measure(zero, target)['tiles']
                    limits[amount] = max(abs(tile['relativeContrastChange']) for tile in tiles)
    if not equations:
        raise ValueError('No registered calibration scenes')
    if not limits:
        raise ValueError('Expected a registered calibration frequency chart and all five Texture strengths')
    gains = {}
    for amount in LEVELS:
        gram, right = (sum(parts) for parts in zip(*(scene[amount] for scene in equations), strict=True))
        factor = np.linalg.cholesky(gram + np.eye(3) * (.002 * np.diag(gram).mean() + 1e-15))
        sign = np.sign(amount)
        # Positive Texture amplifies detail at every tone, negative Texture attenuates it.
        gains[amount] = (sign * nnls(factor.T, np.linalg.solve(factor, right * sign))[0]).tolist()
    return dict(gains=gains, contrastLimits=limits, sources=receipts)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registration', type=Path)
    parser.add_argument('decoder', type=Path, help='compiled Light/decode.swift')
    parser.add_argument('output', type=Path)
    parser.add_argument('--frequency-neutral', required=True, help='neutral case for the calibration frequency chart')
    args = parser.parse_args()
    result = calibrate(args.registration.resolve(), args.decoder.resolve(), args.frequency_neutral)
    with args.output.open('x') as stream:
        stream.write(json.dumps(result, indent=2, allow_nan=False) + '\n')
