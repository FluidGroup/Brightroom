"""Refit the signed Clarity response from complete calibration scenes in a registered study."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

import numpy as np
from scipy.ndimage import gaussian_filter

TOOLS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(TOOLS / 'A10'), str(TOOLS / 'Light')]
from adaptive_data import P3_TO_ROMM
from paired_light import decode, read
from presence_reference import changes, registered

LEVELS = (-100, -50, 4, 50, 100)
LUMA = np.array([.22897457, .69173855, .07928692])


def encode(value):
    return np.where(value < .0031308, value * 12.92, 1.055 * np.maximum(value, 0) ** (1 / 2.4) - .055)


def basis(features, code, knots):
    """Interpolate each feature's gain at equally spaced encoded luminances."""
    weights = np.maximum(0, 1 - np.abs(code[:, None] * (knots - 1) - np.arange(knots)))
    return np.concatenate([field[:, None] * weights for field in features], axis=1)


def scene_equations(zero, edits):
    """Measure local contrast first, then sample the same locations at all five strengths."""
    source = np.clip(zero, 0, 1)
    luminance = source @ LUMA
    code = encode(luminance)
    radius = max(code.shape) * 8 / 1024
    detail = code - gaussian_filter(code.astype('f4'), radius, mode='nearest')
    contrast = gaussian_filter(np.abs(detail).astype('f4'), radius, mode='nearest')
    # The signed mean distinguishes a dark patch beside a bright edge from
    # the opposite edge. Negative Clarity uses this additional guide.
    signed_mean = gaussian_filter(detail.astype('f4'), radius, mode='nearest')
    indices = np.random.default_rng(606).choice(code.size, min(18000, code.size), replace=False)

    def sample(image):
        return image.reshape((-1,) + image.shape[2:])[indices].astype(float)

    rgb, y, value, difference, energy = map(sample, (source, luminance, code, detail, contrast))
    romm = rgb @ P3_TO_ROMM.T
    saturation = np.ptp(romm, axis=1) / (romm.max(axis=1) + .05)
    light = basis((difference, energy, difference * saturation), value, 5)
    softening = np.column_stack((light, basis((sample(signed_mean),), value, 5)))
    color = basis((difference, energy), value, 3)
    chroma = rgb - y[:, None]
    width = (chroma ** 2).sum(axis=1)
    rows = {}
    for amount, target in edits.items():
        luminance = softening if amount < 0 else light
        delta = sample(target - zero)
        normalization = max(.001, np.quantile(np.abs(delta).max(axis=1), .95)) ** 2 * len(y)
        dy = encode(np.maximum(sample(target) @ LUMA, 0)) - value
        dc = ((delta - (delta @ LUMA)[:, None]) * chroma).sum(axis=1)
        rows[amount] = (luminance.T @ luminance / normalization, luminance.T @ dy / normalization,
                        (color.T * width) @ color / normalization, color.T @ dc / normalization)
    return rows


def fit(gram, right):
    penalty = .3 * np.diag(gram).mean() + 1e-13
    return np.linalg.solve(gram + np.eye(len(right)) * penalty, right)


def calibrate(root, decoder):
    cases = {r['id']: r for r in read(root / 'cases.json')['cases']}
    refs = {r['id']: r for r in read(root / 'references.json')['references']}
    grouped = defaultdict(list)
    for case in cases.values():
        if case['group'] == 'presence-clarity':
            grouped[case['inputSHA256']].append(case)
    samples, evidence = [], []
    for source, group in grouped.items():
        roles = {c['role'] for c in group}
        if roles == {'evaluate'}:
            continue
        if roles != {'fit'} or sorted(c['parameters'].get('Clarity2012') for c in group) != list(LEVELS):
            raise ValueError(f'Expected a complete calibration scene: {source}')
        neutral, = [c for c in cases.values() if c['group'] == 'neutral' and c['inputSHA256'] == source]
        control = registered(root, cases, refs, neutral['id'])
        if (control['declared'] or any(float(control['applied'][k]) != 0 for k in ('Clarity2012', 'Texture', 'Dehaze'))
                or control['proof']['processVersion'] != '15.4'):
            raise ValueError('Expected a neutral Process Version 15.4 reference')
        with TemporaryDirectory() as tmp:
            zero = decode(control['path'], decoder, Path(tmp) / 'neutral')
            edits = {}
            for case in group:
                row = registered(root, cases, refs, case['id'])
                amount = case['parameters']['Clarity2012']
                if changes(control, row) != {'Clarity2012': amount}:
                    raise ValueError(f'Expected one applied Clarity change for {case["id"]}')
                edits[amount] = decode(row['path'], decoder, Path(tmp) / str(amount))
                evidence.append(row['proof'])
            evidence.append(control['proof'])
            samples.append(scene_equations(zero, edits))
    if not samples:
        raise ValueError('No calibration scenes')
    endpoints = {}
    for amount in LEVELS:
        a, b, c, d = (sum(parts) for parts in zip(*(scene[amount] for scene in samples), strict=True))
        light = fit(a, b).reshape(-1, 5).T
        if amount > 0:
            light = np.column_stack((light, np.zeros(5)))
        endpoints[amount] = {'light': light.tolist(),
                             'color': fit(c, d).reshape(2, 3).T.tolist()}
    return dict(endpoints=endpoints, sources=evidence)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registration', type=Path)
    parser.add_argument('decoder', type=Path, help='Compiled Light/decode.swift')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    calibration = calibrate(args.registration, args.decoder.resolve())
    with args.output.open('x') as stream:
        stream.write(json.dumps(calibration, indent=2, allow_nan=False) + '\n')
