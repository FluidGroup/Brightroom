"""Fit the negative Highlights and Shadows luminance-range response at −50."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

import numpy as np

from adaptive_data import FrozenSet
from error_metrics import nearest_rank


def read(path):
    return json.loads(path.read_text())


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def normal_equations(guide, source, adjusted, adobe, adobe_neutral, highlights):
    """Fit a luminance change along the output's RGB ray to the difference in signed responses."""
    y, local16, local64, local256, global_range, deviation = guide.T
    code = np.where(y <= .0031308, 12.92 * y, 1.055 * np.maximum(y, 0) ** (1 / 2.4) - .055)
    value = np.maximum(.5 - code, 0) if highlights else np.clip(3 - 3 * code, 0, 1)
    output_y = np.clip(adjusted @ [.22897456, .69173852, .07928692], 0, 1)
    terms = np.column_stack([np.ones(len(y)), local16 - value, local64 - value,
                             local256 - value, global_range - value, deviation - .1,
                             (output_y - y) / (output_y + .05)])
    knots = np.maximum(1 - np.abs(np.clip(code[:, None], 0, 1) * 4 - np.arange(5)), 0)
    basis = (terms[:, :, None] * knots[:, None, :]).reshape(len(y), -1)
    direction = np.maximum(adjusted, 0) / (output_y[:, None] + .045)
    error = (adobe - adobe_neutral) - (adjusted - source)
    maximum = np.max(abs(error), axis=1)
    weight = 1 + np.minimum(maximum / max(.012, np.quantile(maximum, .8)), 3)
    weight /= len(y) * max(nearest_rank(maximum, .95), .025) ** 1.1
    matrix = basis.T @ (basis * (weight * (direction * direction).sum(axis=1))[:, None])
    return matrix, basis.T @ (weight * (direction * error).sum(axis=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path, help='signed cases manifest with paired Adobe neutrals')
    parser.add_argument('baseline', type=Path, help='decode.swift outputs for the pre-range public half-float baseline')
    parser.add_argument('capture', type=Path, help='compiled capture-tone-range.swift')
    parser.add_argument('metallib', type=Path, help='the product macOS CI Metal library')
    parser.add_argument('output', type=Path, help='new directory for captures and fitted observations')
    parser.add_argument('--check', type=Path, help='verify the constants in HighlightShadowKernels.metal')
    args = parser.parse_args()
    args.output.mkdir(exist_ok=False, parents=True)
    sources = {r['sourceSHA256'] for r in read(Path(__file__).with_name('highlights-strength-calibration.json'))['samples']}
    rows = [c for c in read(args.cases) if c['amount'] == -50 and c['source'] in sources]
    controls = ('Highlights2012', 'Shadows2012')
    if (len(rows) != 2 * len(sources) or
            {(r['source'], r['control']) for r in rows} != {(s, c) for s in sources for c in controls}):
        raise ValueError('Expected a −50 pair for each calibration source')
    public = {Path(r['input']).stem: r for r in read(args.baseline / 'manifest.json')}
    registries = {p: {r['id']: r for r in read(Path(p) / 'cases.json')['cases']}
                  for c in rows for p in (c['root'], c['neutralRoot'])}
    catalogs = {p: FrozenSet(p) for p in registries}

    def reference(path, key, source_hash, ref_hash, settings):
        registration = registries[path][key]
        catalog = catalogs[path]
        record = catalog.references[key]
        if not (registration['parameters'] == settings and registration['inputSHA256'] == source_hash
                and record['settingsSHA256'] == registration['settingsSHA256'] == digest(registration['settings'])
                and record['referenceSHA256'] == ref_hash
                and all(float(record['resolvedSettings'][control]) == settings.get(control, 0) for control in controls)
                and digest(record['inspection']['icc']) == record['inspection']['iccSHA256']):
            raise ValueError(f'Mismatched input, XMP, output ICC or reference for {key}')
        return catalog.read(key)[..., :3]

    def public_rgb(key, shape, indices):
        row = public[key]
        if row['space'] != 'extended-linear Display-P3 D65' or digest(row['input']) != row['sha256']:
            raise ValueError(f'Mismatched public baseline for {key}')
        image = np.memmap(args.baseline / row['output'], dtype='<f4', mode='r', shape=(row['height'], row['width'], 4))
        if image.shape[:2] != shape or not np.isfinite(image).all() or not np.all(image[..., 3] == 1):
            raise ValueError(f'Invalid public pixels for {key}')
        return image.reshape(-1, 4)[indices, :3].astype(np.float64)

    indices = {}
    requests = []
    for c in rows:
        source = c['source']
        if source in indices:
            continue
        inp = Path(registries[c['root']][c['id']]['input']).resolve()
        if digest(inp) != source:
            raise ValueError(f'Changed input TIFF for {source}')
        rec = public[c['neutralPublic']]
        count = rec['width'] * rec['height']
        indices[source] = np.random.default_rng(int(source[:16], 16)).choice(count, min(count, 12288), replace=False).astype('<u4')
        location = args.output.resolve() / (source + '.indices')
        indices[source].tofile(location)
        requests.append(dict(source=source, input=str(inp), indices=str(location)))
    manifest = args.output / 'requests.json'
    manifest.write_text(json.dumps(requests, indent=2) + '\n')
    guides = args.output / 'guides'
    subprocess.run([args.capture.resolve(), args.metallib, manifest, guides], check=True)

    tables = {}
    evidence = []
    for control in controls:
        systems = []
        for c in rows:
            if c['control'] != control:
                continue
            key, source = c['id'], c['source']
            samples = indices[source]
            reference_image = reference(c['root'], key, source, c['referenceSHA256'], {control: -50})
            zero = reference(c['neutralRoot'], c['neutralID'], source, c['neutralReferenceSHA256'], {})
            if reference_image.shape != zero.shape:
                raise ValueError(f'Mismatched Lightroom dimensions for {key}')
            shape = zero.shape[:2]
            neutral = public_rgb(c['neutralPublic'], shape, samples)
            adjusted = public_rgb(key, shape, samples)
            target = reference_image.reshape(-1, 3)[samples].astype(np.float64)
            initial = zero.reshape(-1, 3)[samples].astype(np.float64)
            path = guides / (source + '-' + control + '.f32')
            guide = np.fromfile(path, dtype='<f4').reshape(len(samples), 6).astype(np.float64)
            if not np.isfinite(guide).all():
                raise ValueError(f'Invalid captured range for {key}')
            gram, rhs = normal_equations(guide, neutral, adjusted, target, initial, control == 'Highlights2012')
            family = 'photo' if c['kind'] == 'photo' else 'color' if np.ptp(neutral, axis=1).max() > .005 else 'gray'
            systems.append((family, gram, rhs))
            evidence.append(dict(id=key, source=source, family=family, capture=digest(path), neutral=c['neutralReferenceSHA256'],
                                 reference=c['referenceSHA256'], baselineRGB=hashlib.sha256(adjusted.tobytes()).hexdigest()))
        sizes = Counter(family for family, _, _ in systems)
        gram = sum(matrix / sizes[family] for family, matrix, _ in systems)
        rhs = sum(vector / sizes[family] for family, _, vector in systems)
        penalty = 3 * np.maximum(gram.diagonal(), gram.diagonal().max() * .006) + 1e-8
        coefficients = np.linalg.solve(gram + np.diag(penalty), rhs).reshape(7, 5).T
        name = 'highlightRange' if control == 'Highlights2012' else 'shadowRange'
        tables[name] = coefficients[:, :4]
        tables[name + 'Scene'] = coefficients[:, 4:]

    (args.output / 'measurements.json').write_text(json.dumps(dict(cases=evidence,
        tables={k: v.tolist() for k, v in tables.items()}), indent=2, allow_nan=False) + '\n')
    for name, values in tables.items():
        if args.check:
            block = re.search(rf'\b{name}\[5\] = \{{([^}}]+)\}};', args.check.read_text())
            if not block:
                raise ValueError(f'Missing Metal table {name}')
            observed = np.array(re.findall(r'(-?\d+\.\d+)f', block[1]), dtype=np.float64)
            np.testing.assert_allclose(observed, values.ravel(), atol=5.1e-9, rtol=0)
            print(f'{name} matches all {values.size} coefficients')
        else:
            print(name, np.array2string(values, precision=9))


if __name__ == '__main__':
    main()
