"""Rebuild the negative Shadows color response from registered, post-development −50 and neutral exports."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

import numpy as np
from PIL import Image

from adaptive_data import FrozenSet
from error_metrics import nearest_rank


def read(path):
    return json.loads(Path(path).read_text())


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def encode(linear):
    return np.where(linear <= .0031308, linear * 12.92, 1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def scene_centers(positions, weights):
    """Cluster source statistics using weighted farthest-point seeding and Lloyd updates."""
    centers = [np.average(positions, axis=0, weights=weights)]
    while len(centers) < 5:
        distances = ((positions[:, None] - centers) ** 2).sum(axis=2).min(axis=1)
        centers.append(positions[np.argmax(weights * distances)])
    centers = np.array(centers)
    for _ in range(100):
        cluster = ((positions[:, None] - centers) ** 2).sum(axis=2).argmin(axis=1)
        new = np.stack([np.average(positions[cluster == i], axis=0, weights=weights[cluster == i])
                        for i in range(len(centers))])
        if np.max(abs(new - centers)) < 1e-6:
            break
        centers = new
    return centers[np.argsort(centers[:, 0])]


def observation(guide, neutral, before, target, adobe_zero):
    """Regress the missing RGB loss on the spatial prediction and the original RGB direction."""
    rgb = guide[:, :3]
    mean, deviation = guide[0, 3:5]
    scene = np.clip(([mean, deviation] - np.array([.74, .12])) / [.12, .07], -3, 3)
    loss = neutral - before
    error = (adobe_zero - target) - loss
    y = rgb @ [.22897456, .69173852, .07928692]
    code = encode(y)
    peak = rgb.max(axis=1)
    relative = np.clip(5 * loss.max(axis=1) / (peak + .025), 0, 3)
    terms = np.column_stack([np.ones(len(guide)), (rgb[:, 0] - y) / (peak + .035),
                             (rgb[:, 2] - y) / (peak + .035), relative])
    knots = np.maximum(0, 1 - abs(code[:, None] * 3 - np.arange(4)))
    chroma = np.ptp(encode(rgb), axis=1)
    basis = (knots[:, :, None] * terms[:, None, :]).reshape(len(guide), 16)
    basis *= (chroma / (chroma + .06) * min(deviation / .015, 1))[:, None]
    source_direction = rgb * (.15 * (1 - .65 * code) / (peak + .035))[:, None]
    directions = [loss, source_direction]
    tail = abs(error).max(axis=1)
    p95 = nearest_rank(tail, .95)
    weights = np.minimum(1, (p95 + .001) / np.maximum(tail, .0001))
    weights /= len(guide) * (p95 + .012) ** 2
    gram = np.block([[basis.T @ (basis * (weights * (a * b).sum(axis=1))[:, None])
                      for b in directions] for a in directions])
    rhs = np.concatenate([basis.T @ (weights * (a * error).sum(axis=1)) for a in directions])
    return scene, gram, rhs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path, help='registered spatial comparison cases')
    parser.add_argument('baseline', type=Path, help='pre-correction public directory with png/ and signed.json')
    parser.add_argument('cube', type=Path, help='Lightroom neutral and −50 lattice registration')
    parser.add_argument('cube_renders', type=Path, help='pre-correction lattice samples.json and png/')
    parser.add_argument('cube_metrics', type=Path, help='corresponding whole-chart gamut metrics.json')
    parser.add_argument('decoder', type=Path, help='compiled Light/decode.swift')
    parser.add_argument('capture', type=Path, help='compiled Light/capture-tone-range.swift')
    parser.add_argument('metallib', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--check', type=Path, help='verify the centers and coefficients in the Metal kernel')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    calibration = read(Path(__file__).with_name('highlights-strength-calibration.json'))
    sources = {r['sourceSHA256'] for r in calibration['samples']}
    rows = [c for c in read(args.cases) if c['control'] == 'Shadows2012' and c['amount'] == -50
            and c['source'] in sources and (c['kind'] == 'photo' or c['sourceId'].startswith('color-layout-'))]
    if Counter(r['kind'] for r in rows) != {'photo': 9, 'chart': 4} or len({r['source'] for r in rows}) != 13:
        raise ValueError('Expected nine photographs and four color layouts from the original calibration')
    previous = {r['id']: r for r in read(args.baseline / 'signed.json')}
    requests = []
    for c in rows:
        r = previous[c['id']]
        if r['source'] != c['source'] or r['control'] != c['control'] or r['amount'] != -50:
            raise ValueError(f"Unexpected public baseline for {c['id']}")
        requests.append((c, r, args.baseline / 'png' / (c['id'] + '.png'),
                         args.baseline / 'png' / (c['neutralPublic'] + '.png')))

    cube_key = 'adjust-chart-Shadows2012--50'
    cube_zero = 'adjust-chart-neutral'
    metrics = {r['id']: r for r in read(args.cube_metrics)['rows'] if r['control'] == 'Shadows2012'}
    specs = {r['amount']: r for r in read(args.cube_renders / 'samples.json') if r['control'] == 'Shadows2012'}
    r = metrics[cube_key]
    for amount in (0, -50):
        spec = specs[amount]
        if digest(unquote(urlsplit(spec['input']).path)) != r['source'] or digest(unquote(urlsplit(spec['icc']).path)) != r['icc']:
            raise ValueError('Mismatched lattice source or output profile')
    cube = dict(id=cube_key, source=r['source'], root=str(args.cube), neutralRoot=str(args.cube),
                neutralID=cube_zero, kind='cube', referenceSHA256=r['reference']['referenceSHA256'],
                neutralReferenceSHA256=metrics[cube_zero]['reference']['referenceSHA256'])
    measured = dict(after=r['p95'], reference=r['reference'], neutralReference=metrics[cube_zero]['reference'], icc=r['icc'])
    requests.append((cube, measured, args.cube_renders / 'png' / (specs[-50]['id'] + '.png'),
                     args.cube_renders / 'png' / (specs[0]['id'] + '.png')))

    roots = {p for c, *_ in requests for p in (c['root'], c['neutralRoot'])}
    catalogs = {p: FrozenSet(p) for p in roots}
    registrations = {p: {r['id']: r for r in read(Path(p) / 'cases.json')['cases']} for p in roots}
    decoded = args.output / 'pixels'
    inputs = sorted({f for _, _, a, b in requests for f in (a, b)})
    subprocess.run([args.decoder.resolve(), decoded, *inputs], check=True)
    public = {Path(r['input']).resolve(): r for r in read(decoded / 'manifest.json')}

    def pixels(file):
        entry = public[file.resolve()]
        if entry['space'] != 'extended-linear Display-P3 D65' or digest(file) != entry['sha256']:
            raise ValueError(f'Unverified public pixels for {file}')
        image = np.memmap(decoded / entry['output'], '<f4', 'r', shape=(entry['height'], entry['width'], 4))
        if not np.isfinite(image).all() or not np.all(image[..., 3] == 1):
            raise ValueError(f'Invalid public baseline for {file}')
        return image[..., :3]

    captures, positions = [], {}
    for c, _, file, _ in requests:
        h = c['source']
        source = registrations[c['root']][c['id']]['input']
        if digest(source) != h:
            raise ValueError(f'Changed calibration TIFF for {h}')
        dims = pixels(file).shape[:2]
        if c['kind'] == 'cube':
            if dims != (256, 1024):
                raise ValueError('Expected the original 32³ RGB lattice and two grayscale ramps')
            positions[h] = np.arange(256 * 1024, dtype='<u4').reshape(dims)[128::4].ravel()
        else:
            size = int(np.prod(dims))
            positions[h] = np.random.default_rng(int(h[:16], 16)).choice(size, min(size, 12288), replace=False).astype('<u4')
        ids = args.output.resolve() / (h + '.indices')
        positions[h].tofile(ids)
        captures.append(dict(source=h, input=source, indices=str(ids)))
    manifest = args.output / 'requests.json'
    manifest.write_text(json.dumps(captures, indent=2) + '\n')
    guides = args.output / 'guides'
    subprocess.run([args.capture.resolve(), args.metallib.resolve(), manifest, guides, '--source-color'], check=True)

    blue, green, red = np.indices((32, 32, 32))
    block = ((red // 8 + 2 * (green // 8) + blue // 8) % 4).ravel()
    systems, weights, evidence = [], [], []
    for c, baseline, output_file, zero_file in requests:
        key, h = c['id'], c['source']
        refs = []
        for root, name, parameters, expected in [
                (c['root'], key, {'Shadows2012': -50}, c['referenceSHA256']),
                (c['neutralRoot'], c['neutralID'], {}, c['neutralReferenceSHA256'])]:
            rec = catalogs[root].references[name]
            registration = registrations[root][name]
            with Image.open(Path(root) / rec['reference']) as exported:
                profile = hashlib.sha256(exported.info['icc_profile']).hexdigest()
            inspection = rec['inspection']
            if 'icc' in inspection and digest(inspection['icc']) != inspection['iccSHA256']:
                raise ValueError(f'Changed extracted ICC for {name}')
            if (registration['parameters'] != parameters or registration['inputSHA256'] != h
                    or digest(registration['input']) != h or digest(registration['settings']) != registration['settingsSHA256']
                    or rec['settingsSHA256'] != registration['settingsSHA256'] or rec['referenceSHA256'] != expected
                    or float(rec['resolvedSettings']['Shadows2012']) != parameters.get('Shadows2012', 0)
                    or baseline['icc'] != profile or inspection.get('iccSHA256', profile) != profile):
                raise ValueError(f'Mismatched input, XMP, reference or ICC for {name}')
            refs.append(catalogs[root].read(name)[..., :3])
        before, neutral = pixels(output_file), pixels(zero_file)
        if not before.shape == neutral.shape == refs[0].shape == refs[1].shape:
            raise ValueError(f'Mismatched dimensions for {key}')
        p95 = nearest_rank(abs(before - refs[0]).max(axis=2).ravel(), .95)
        if (abs(p95 - baseline['after']) > 1e-8 or baseline['reference'] != catalogs[c['root']].evidence[key]
                or baseline['neutralReference'] != catalogs[c['neutralRoot']].evidence[c['neutralID']]):
            raise ValueError(f'Changed baseline or paired Lightroom response for {key}')
        ids = positions[h]
        guide_file = guides / (h + '-color.f32')
        guide = np.fromfile(guide_file, '<f4').reshape(len(ids), 6).astype('f8')
        if not np.isfinite(guide).all():
            raise ValueError(f'Invalid source coordinates for {key}')
        groups = [np.flatnonzero(block == i) for i in range(4)] if c['kind'] == 'cube' else [np.arange(len(ids))]
        for group in groups:
            sample = group[::9]
            arrays = [v.reshape(-1, 3)[ids[sample]].astype('f8') for v in (neutral, before, *refs)]
            systems.append(observation(guide[sample], *arrays))
            weights.append({'cube': .35 / 4, 'chart': 1 / 4, 'photo': 1.6 / 9}[c['kind']])
        evidence.append(dict(id=key, source=h, guide=digest(guide_file), baseline=digest(output_file),
                             neutral=digest(zero_file), icc=baseline['icc'], reference=baseline['reference'],
                             neutralReference=baseline['neutralReference']))

    scenes = np.stack([scene for scene, _, _ in systems])
    centers = scene_centers(scenes, np.array(weights))
    support = np.exp(-((scenes[:, None] - centers) ** 2).sum(axis=2) / (2 * .55 ** 2))
    gram = sum(w * np.kron(np.outer(f, f), matrix) for w, f, (_, matrix, _) in zip(weights, support, systems))
    rhs = sum(w * np.outer(f, vector).ravel() for w, f, (_, _, vector) in zip(weights, support, systems))
    coefficients = np.linalg.solve(gram + np.eye(len(rhs)) * .012, rhs).reshape(5, 8, 4)
    result = dict(centers=centers.tolist(), coefficients=coefficients.tolist(), evidence=evidence)
    (args.output / 'fit.json').write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
    if args.check:
        metal = args.check.read_text()
        for name, count, expected in [('shadowSceneCenters', 2, centers), ('shadowLossCoefficients', 4, coefficients)]:
            data = metal.split(name, 1)[1].split('};', 1)[0]
            vectors = re.findall(rf'float{count}\(([^)]+)\)', data)
            actual = np.array([[float(v.strip().removesuffix('f')) for v in row.split(',')] for row in vectors])
            np.testing.assert_allclose(actual, expected.reshape(-1, count), atol=2e-6, rtol=0)
    print(f'Fit {len(centers)} scene centers and {coefficients.size} coefficients from {len(requests)} signed pairs.')


if __name__ == '__main__':
    main()
