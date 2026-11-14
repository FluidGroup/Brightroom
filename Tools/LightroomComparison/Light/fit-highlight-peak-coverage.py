"""Rebuild the Highlights −50 surround coefficients from paired Adobe exports and native GPU probes."""
import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re

import numpy as np
from PIL import Image

from adaptive_data import FrozenSet
from error_metrics import nearest_rank
from tone_chart import digest


LUMINANCE = np.array([.22897456, .69173852, .07928692], dtype='f4')


def read(path):
    return json.loads(Path(path).read_text())


def encode(linear):
    return np.where(linear <= .0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - .055)


def coverage_columns(neutral, indices):
    """Measure nearby brighter/darker peaks in two bands, then lift the three luma knots to each pixel."""
    height, width = neutral.shape[:2]
    scale = min(1, 256 / max(height, width))
    rows, columns = np.ceil(np.array([height, width]) * scale).astype(int)
    y, x = np.mgrid[:rows, :columns]

    def clamped_index(position, size):
        return np.clip(np.floor(position).astype(int), 0, size - 1)

    # Image arrays are top-down. Core Image places guide pixel centers from the lower left.
    input_y = np.clip(height - 1 - np.floor((y + .5) / scale).astype(int), 0, height - 1)
    rgb = np.clip(neutral[input_y, clamped_index((x + .5) / scale, width)], 0, 1)
    color = encode(rgb)
    peak = color.max(axis=2)
    luma = encode(rgb @ LUMINANCE)
    bands = []
    for distances in ((4, 16), (64, 256)):
        coverage = np.zeros((*peak.shape, 2), dtype='f4')
        for distance in distances:
            radius = distance * scale * max(height, width) / 1024
            for direction in range(8):
                angle = direction * np.pi / 4
                xx = clamped_index(x + .5 + radius * np.cos(angle), columns)
                yy = clamped_index(y + .5 + radius * np.sin(angle), rows)
                delta = peak - peak[yy, xx]
                pair = np.clip(np.stack([delta, -delta], axis=-1) / .25, 0, 1)
                coverage += pair * pair * (3 - 2 * pair)
        bands.append(coverage / 16)
    coverage = np.concatenate(bands, axis=2)
    iy, ix = np.unravel_index(indices, (height, width))
    center = encode(np.clip(neutral[iy, ix], 0, 1))
    xx, yy = (ix + .5) * scale - .5, (height - iy - .5) * scale - .5
    fx, fy = xx % 1, yy % 1
    features = np.concatenate([coverage * np.maximum(1 - abs(luma * 2 - k), 0)[..., None]
                               for k in range(3)], axis=2)
    result = np.zeros((len(ix), features.shape[-1]), dtype='f4')
    for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1)):
        gx = clamped_index(np.floor(xx) + dx, columns)
        gy = clamped_index(np.floor(yy) + dy, rows)
        area = (fx if dx else 1 - fx) * (fy if dy else 1 - fy)
        weight = (area * np.exp(-32 * np.sum((center - color[gy, gx]) ** 2, axis=1))).astype('f4')
        result += features[gy, gx] * weight[:, None]
    return result


def equations(columns, residual, jacobian):
    """Form one image's contribution to a joint fit of encoded light and chroma corrections."""
    size = len(columns)
    error = abs(residual).max(axis=1)
    p95 = nearest_rank(error, .95)
    weight = np.minimum(1, (p95 + .005) / np.maximum(error, 1e-5)) / size
    weighted = weight[:, None, None] * jacobian
    power = np.einsum('ncj,nck->njk', weighted, jacobian)
    target = np.einsum('ncj,nc->nj', weighted, residual)
    gram = np.block([[columns.T @ (columns * power[:, i, j, None]) for j in range(2)] for i in range(2)])
    rhs = np.r_[columns.T @ target[:, 0], columns.T @ target[:, 1]]
    return gram, rhs, p95


def fit(cases_file, scores_file, native_file, probes_file):
    cases = read(cases_file)['cases']
    scores, native, probes = map(read, (scores_file, native_file, probes_file))
    if not scores['kernel'] == native['kernel'] == probes['baselineKernel']:
        raise ValueError('Captures have different baseline kernels')
    scores = {r['id']: r for r in scores['rows']}
    samples = read(Path(__file__).with_name('highlights-strength-calibration.json'))['samples']
    calibration = {s['sourceSHA256']: s for s in samples}
    cases = [c for c in cases if c['control'] == 'Highlights2012' and c['amount'] == -50 and c['source'] in calibration]
    if len(cases) != 33 or {c['source'] for c in cases} != calibration.keys():
        raise ValueError('Expected the 33 registered −50 calibration inputs')

    @lru_cache(maxsize=None)
    def acquisition(path):
        return FrozenSet(path), {r['id']: r for r in read(Path(path) / 'cases.json')['cases']}

    def adobe(folder, key, settings, source, expected, icc):
        frozen, registry = acquisition(folder)
        r, ref = registry[key], frozen.references[key]
        if (r['parameters'] != settings or r['inputSHA256'] != source or digest(r['input']) != source
                or not digest(r['settings']) == r['settingsSHA256'] == ref['settingsSHA256']
                or float(ref['resolvedSettings']['Highlights2012']) != settings.get('Highlights2012', 0)
                or ref['referenceSHA256'] != expected or frozen.decoded[key]['space'] != 'extended-linear Display-P3 D65'):
            raise ValueError(f'Unpaired Lightroom registration for {key}')
        with Image.open(Path(folder) / ref['reference']) as image:
            if hashlib.sha256(image.info['icc_profile']).hexdigest() != icc:
                raise ValueError(f'Unexpected reference ICC for {key}')
        return frozen.read(key)[..., :3]

    def public(key):
        entry = native['images'][key]
        row = entry['record']
        if digest(row['input']) != row['sha256'] or row['space'] != 'extended-linear Display-P3 D65':
            raise ValueError(f'Changed native output for {key}')
        pixels = np.memmap(Path(entry['folder']) / row['output'], '<f4', 'r', shape=(row['height'], row['width'], 4))
        if not np.isfinite(pixels).all() or not (pixels[..., 3] == 1).all():
            raise ValueError(f'Nonopaque or nonfinite native image for {key}')
        return pixels[..., :3]

    directions = {}
    for probe in probes['directions']:
        key = (probe['channel'], probe['step'])
        if key in directions or digest(probes_file.parent / probe['kernel']) != probe['kernelSHA256']:
            raise ValueError('Missing or duplicate probe kernel')
        directions[key] = probe['images']
    if set(directions) != {(channel, sign * .0125) for channel in ('light', 'chroma') for sign in (-1, 1)}:
        raise ValueError('Expected centered light and chroma probes at ±0.0125')

    systems = []
    for case in cases:
        key, source = case['id'], case['source']
        score = scores[key]
        if (score['source'] != source or score['icc'] != case['icc'] or score['xmp'] != case['xmp']
                or calibration[source]['adjustedReferenceSHA256'] != case['referenceSHA256']):
            raise ValueError(f'Source, XMP, ICC or reference mismatch for {key}')
        t = adobe(case['root'], key, {'Highlights2012': -50}, source, case['referenceSHA256'], case['icc'])
        z = adobe(case['neutralRoot'], case['neutralID'], {}, source, case['neutralReferenceSHA256'], case['icc'])
        n, b = public(case['neutralPublic']), public(case['public'])
        if not n.shape == b.shape == t.shape == z.shape:
            raise ValueError(f'Incompatible image dimensions for {key}')
        residual = (t - z) - (b - n)
        if (abs(nearest_rank(abs(residual).max(axis=2), .95) - score['response']) > 1e-8
                or abs(nearest_rank(abs(b - t).max(axis=2), .95) - score['p95']) > 1e-8
                or hashlib.sha256(np.ascontiguousarray(b).data).hexdigest() != score['samples']):
            raise ValueError(f'Changed decoded pixels for {key}')
        count = n.shape[0] * n.shape[1]
        indices = np.random.default_rng(int(source[:12], 16)).choice(count, min(count, 7149), replace=False)
        def probe(channel, step):
            entry = directions[channel, step][key]
            path = probes_file.parent / entry['path']
            if entry['source'] != source or digest(path) != entry['sha256']:
                raise ValueError(f'Unpaired {channel} probe for {key}')
            arr = np.load(path, allow_pickle=False)
            if arr.shape != (len(indices), 3) or not np.isfinite(arr).all():
                raise ValueError(f'Invalid {channel} probe samples for {key}')
            return arr
        jacobian = np.stack([(probe(ch, .0125) - probe(ch, -.0125)) / .025 for ch in ('light', 'chroma')], axis=2)
        family = 'photo' if case['kind'] == 'photo' else ('color' if case['sourceId'].startswith('color-layout-') else 'gray')
        gram, rhs, p95 = equations(coverage_columns(n, indices), residual.reshape(-1, 3)[indices], jacobian)
        systems.append((family, gram, rhs, p95))
    counts = Counter(family for family, *_ in systems)
    if counts != {'photo': 9, 'color': 4, 'gray': 20}:
        raise ValueError('Unexpected calibration families')
    gram, rhs = np.zeros((24, 24)), np.zeros(24)
    for family, matrix, target, p95 in systems:
        scale = 1 / (counts[family] * (p95 + .014) ** 1.25)
        gram += matrix.astype('f8') * scale
        rhs += target.astype('f8') * scale
    penalty = .1 * np.maximum(gram.diagonal(), gram.diagonal().max() * .015) + 1e-7
    coefficients = np.linalg.solve(gram + np.diag(penalty), rhs).reshape(2, 3, 4)
    return coefficients


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path, help='signed case ledger with calibration source hashes')
    parser.add_argument('scores', type=Path, help='native pre-correction per-image scores')
    parser.add_argument('native', type=Path, help='index of decoded public neutral and adjusted 16-bit PNGs')
    parser.add_argument('probes', type=Path, help='manifest of the signed native finite differences')
    parser.add_argument('--check', type=Path, help='verify the Metal coefficients')
    args = parser.parse_args()
    coefficients = fit(args.cases, args.scores, args.native, args.probes)
    if args.check:
        block = args.check.read_text().split('static float2 toneHighlightSurroundResponse(', 1)[1]
        table = block.split('  float position', 1)[0]
        values = [float(v) for v in re.findall(r'(-?\d+\.\d+)f', table)]
        if len(values) != coefficients.size or not np.allclose(values, coefficients.ravel(), atol=2e-6, rtol=0):
            raise ValueError('Metal coefficients disagree with the registered fit')
    print(json.dumps({'light': coefficients[0].tolist(), 'chroma': coefficients[1].tolist()}, indent=2))


if __name__ == '__main__':
    main()
