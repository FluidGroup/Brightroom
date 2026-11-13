"""Rebuild the Highlights −50 color response from paired 16-bit public and Lightroom exports."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

import numpy as np
from scipy.spatial.distance import cdist
from scipy.special import ndtri
from scipy.stats import qmc

from adaptive_data import FrozenSet
from error_metrics import nearest_rank


def read(path):
    return json.loads(Path(path).read_text())


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def encode(linear):
    return np.where(linear <= .0031308, 12.92 * linear,
                    1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def system(centers, guide, source, output, adobe, neutral):
    """Estimate the signed luminance residual in the direction of the calibrated output RGB."""
    rgb, scene, deviation, activity = guide[:, :3], guide[:, 3], guide[:, 4], guide[:, 5]
    luma = np.array([.22897456, .69173852, .07928692], dtype='f4')
    y = encode(rgb @ luma)
    output_y = np.maximum(output @ luma, 0)
    loss = (y - encode(output_y)) / np.maximum(.1, 2 * y * (1 - y))
    positions = np.column_stack([(y - .54) / .28, (loss - .13) / .15,
                                 (scene - .73) / .14, (deviation - .12) / .07]).clip(-3, 3)
    chroma = np.ptp(encode(rgb), axis=1)
    basis = np.exp(-cdist(positions, centers, 'sqeuclidean').astype('f4') / 4.5)
    basis *= (chroma / (chroma + .08))[:, None]
    direction = np.maximum(output, 0) / (output_y + .045)[:, None]
    direction *= ((activity >= .001) * np.minimum(activity / .015, 1))[:, None]
    error = (adobe - neutral) - (output - source)
    maximum = np.max(abs(error), axis=1)
    weight = .75 + np.minimum(maximum / max(.004, np.quantile(maximum, .8)), 4)
    weight /= len(output) * max(.014, nearest_rank(maximum, .95))
    basis = basis.astype('f8')
    direction = direction.astype('f8')
    gram = basis.T @ (basis * (weight * np.sum(direction * direction, axis=1))[:, None])
    return gram, basis.T @ (weight * np.sum(direction * error, axis=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path)
    parser.add_argument('baseline', type=Path, help='pre-correction public half-float directory with png/ and signed.json')
    parser.add_argument('decoder', type=Path, help='compiled Light/decode.swift')
    parser.add_argument('capture', type=Path, help='compiled Light/capture-tone-range.swift')
    parser.add_argument('metallib', type=Path)
    parser.add_argument('output', type=Path, help='new directory for captures and fitted measurements')
    parser.add_argument('--check', type=Path, help='verify the constants in HighlightShadowKernels.metal')
    args = parser.parse_args()
    args.output.mkdir(exist_ok=False, parents=True)

    calibration = read(Path(__file__).with_name('highlights-strength-calibration.json'))
    sources = {r['sourceSHA256'] for r in calibration['samples']}
    rows = [c for c in read(args.cases) if c['source'] in sources and c['amount'] == -50
            and c['control'] == 'Highlights2012' and (c['kind'] == 'photo' or c['sourceId'].startswith('color-layout-'))]
    families = Counter(c['kind'] for c in rows)
    if families != {'chart': 4, 'photo': 9} or len({c['source'] for c in rows}) != 13:
        raise ValueError('Expected the four calibrated color charts and nine photographs')
    registries = {p: {r['id']: r for r in read(Path(p) / 'cases.json')['cases']}
                  for c in rows for p in (c['root'], c['neutralRoot'])}
    catalogs = {p: FrozenSet(p) for p in registries}
    previous = {r['id']: r for r in read(args.baseline / 'signed.json')}
    keys = sorted({c[k] for c in rows for k in ('id', 'neutralPublic')})
    decoded = args.output / 'baseline'
    subprocess.run([args.decoder.resolve(), decoded, *[args.baseline / 'png' / (k + '.png') for k in keys]], check=True)
    public = {Path(r['input']).stem: r for r in read(decoded / 'manifest.json')}

    def pixels(key, expected_shape):
        r = public[key]
        if (r['space'] != 'extended-linear Display-P3 D65' or (r['height'], r['width']) != expected_shape
                or digest(r['input']) != r['sha256']):
            raise ValueError(f'Mismatched public render for {key}')
        return np.memmap(decoded / r['output'], '<f4', 'r', shape=(*expected_shape, 4))[..., :3]

    requests, positions = [], {}
    for c in rows:
        h, key = c['source'], c['id']
        path = registries[c['root']][key]['input']
        if digest(path) != h:
            raise ValueError(f'Changed input TIFF for {key}')
        size = public[key]['width'] * public[key]['height']
        indices = np.random.default_rng(int(h[:16], 16)).choice(size, min(size, 12288), replace=False).astype('<u4')
        positions[h] = indices[::2]
        file = args.output.resolve() / (h + '.indices')
        positions[h].tofile(file)
        requests.append(dict(source=h, input=path, indices=str(file)))
    manifest = args.output / 'requests.json'
    manifest.write_text(json.dumps(requests, indent=2) + '\n')
    guides = args.output / 'guides'
    subprocess.run([args.capture.resolve(), args.metallib, manifest, guides, '--highlight-color'], check=True)

    # A fixed, target-independent set of centers allows whole-source cross-validation.
    centers = np.clip(ndtri(qmc.Sobol(4, seed=144, scramble=True).random_base2(5)), -2.5, 2.5).astype('f4')
    gram = np.zeros((32, 32))
    rhs = np.zeros(32)
    evidence = []
    for c in rows:
        key, h = c['id'], c['source']
        ids = positions[h]
        refs = []
        for path, name, settings, expected in [(c['root'], key, {'Highlights2012': -50}, c['referenceSHA256']),
            (c['neutralRoot'], c['neutralID'], {}, c['neutralReferenceSHA256'])]:
            record, registration = catalogs[path].references[name], registries[path][name]
            if not (registration['parameters'] == settings and registration['inputSHA256'] == h
                    and digest(registration['settings']) == record['settingsSHA256'] == registration['settingsSHA256']
                    and record['referenceSHA256'] == expected
                    and float(record['resolvedSettings']['Highlights2012']) == settings.get('Highlights2012', 0)
                    and digest(record['inspection']['icc']) == record['inspection']['iccSHA256'] == previous[key]['icc']):
                raise ValueError(f'Input, settings, reference or ICC mismatch for {name}')
            refs.append(catalogs[path].read(name)[..., :3])
        if not (refs[0].shape == refs[1].shape and previous[key]['reference'] == catalogs[c['root']].evidence[key]
                and previous[key]['neutralReference'] == catalogs[c['neutralRoot']].evidence[c['neutralID']]):
            raise ValueError(f'Registration mismatch for {key}')
        shape = refs[0].shape[:2]
        source, output = (pixels(n, shape) for n in (c['neutralPublic'], key))
        p95 = nearest_rank(np.max(abs(output - refs[0]), axis=2).ravel(), .95)
        if abs(p95 - previous[key]['after']) > 1e-8:
            raise ValueError(f'Unexpected baseline response for {key}')
        file = guides / (h + '-color.f32')
        guide = np.fromfile(file, '<f4').reshape(len(ids), 6)
        if not np.isfinite(guide).all():
            raise ValueError(f'Nonfinite calibration coordinates for {key}')
        data = [img.reshape(-1, 3)[ids] for img in (source, output, *refs)]
        matrix, vector = system(centers, guide, *data)
        gram += matrix / families[c['kind']]
        rhs += vector / families[c['kind']]
        evidence.append(dict(id=key, input=h, indices=digest(args.output / (h + '.indices')),
                             guide=digest(file), source=public[c['neutralPublic']]['sha256'], output=public[key]['sha256'],
                             reference=c['referenceSHA256'], neutral=c['neutralReferenceSHA256'], p95=p95))
    weights = np.linalg.solve(gram + np.eye(32) * .05, rhs)
    result = dict(measurements=evidence, centers=centers.tolist(), weights=weights.tolist())
    (args.output / 'fit.json').write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
    if args.check:
        shader = args.check.read_text()
        for name, values in [('centers', centers.ravel()), ('weights', weights)]:
            block = re.search(rf'\b{name}\[32\] = \{{([^}}]+)\}};', shader)
            if not block:
                raise ValueError(f'Missing Metal table {name}')
            observed = np.array(re.findall(r'(-?\d+\.\d+)f', block[1]), dtype='f8')
            np.testing.assert_allclose(observed, values, rtol=0, atol=2e-6)
        print('Verified 32 color-response centers and weights on 13 registered sources.')


if __name__ == '__main__':
    main()
