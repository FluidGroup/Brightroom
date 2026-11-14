"""Refit Highlights beyond −50 from registered weak Lightroom settings and the preceding macOS renderer."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory

import numpy as np
from PIL import Image
from scipy.optimize import least_squares
from scipy.special import expit

from adaptive_data import P3_TO_ROMM, FrozenSet
from error_metrics import nearest_rank
from tone_chart import digest, registered_chart


CONTROL = 'Highlights2012'
LEVELS = np.array([0, .4, .7, .85, .95, .99, 1])
KERNEL = Path('Brightroom_BrightroomColorAdjustmentKernels.bundle/Contents/Resources/BrightroomColorAdjustments-macos.metallib')


def read(path):
    return json.loads(Path(path).read_text())


def extrema(rgb, source):
    """Select the endpoints of the original hue line even if the adjusted channels meet."""
    indices = np.stack([source.argmin(axis=1), source.argmax(axis=1)], axis=1)
    return np.take_along_axis(rgb, indices, axis=1)


def move(source, endpoint, scale, limits):
    """Extend the two linear ProPhoto endpoints by a common fraction of their log-odds changes."""
    original = source @ P3_TO_ROMM.T
    start = extrema(original, original)
    end = extrema(endpoint @ P3_TO_ROMM.T, original)
    black, white = limits

    def coordinate(v):
        return np.log(np.maximum(v + black, 1e-10)) - np.log(np.maximum(white - v, 1e-10))

    displaced = expit(coordinate(end) + (scale - 1) * (coordinate(end) - coordinate(start)))
    delta = displaced * (white + black) - black - end
    position = (source - start[:, :1]) / np.maximum(start[:, 1:] - start[:, :1], 1e-8)
    return endpoint + delta[:, :1] + np.diff(delta, axis=1) * position


def fit_limits(research):
    intervals, evidence = [], []
    # Both charts use the same locations across settings. No full-strength Adobe image enters the fit.
    for chart in ('lattice', 'ramp'):
        pixels, identities = {}, set()
        for amount in (0, -10, -25, -50):
            weak = amount in (-10, -25)
            if chart == 'lattice':
                folder, prefix = ('response-model-001' if weak else 'adjustments-001'), 'adjust-chart-'
            else:
                folder, prefix = ('adaptive-calibration-001', 'adaptcal-ramp-') if weak else ('adaptive-002', 'adaptive-ramp-')
            rgba, proof = registered_chart(research / folder, prefix, CONTROL, amount)
            identities.add((proof['source'], proof['profile']))
            indices = np.random.default_rng(42).choice(rgba.shape[0] * rgba.shape[1], 8192, replace=False)
            pixels[amount] = rgba[..., :3].reshape(-1, 3)[indices].astype('f8')
            evidence.append(proof)
        if len(identities) != 1:
            raise ValueError(f'Changed {chart} source or output ICC across the range fit')
        for a, b in ((-10, -25), (-25, -50)):
            intervals.append((pixels[0], pixels[a], b / a, pixels[b]))

    def errors(parameters):
        limits = np.exp(parameters) + [0, 1]
        return np.concatenate([(move(x, y, strength, limits) - goal).ravel() for x, y, strength, goal in intervals])

    result = least_squares(errors, np.log([.001, .1]), bounds=(np.log([1e-7, 1e-7]), np.log([1., 3.])),
                           loss='soft_l1', f_scale=.001)
    if not result.success:
        raise ValueError(result.message)
    return np.exp(result.x) + [0, 1], evidence


def equations(source, halfway, full, neutral, adjusted, limits):
    """Fit two endpoint losses. Balance intensity bins and give each calibration image one vote in its family."""
    target = move(neutral, adjusted, 2, limits) + (source - neutral)
    source = np.clip(source, 0, 1)
    romm = source @ P3_TO_ROMM.T
    levels = np.clip(extrema(romm, romm), 0, 1)
    position = np.interp(levels, LEVELS, np.arange(len(LEVELS)))
    basis = np.maximum(1 - abs(position[:, :, None] - np.arange(len(LEVELS))), 0)

    half = extrema(halfway, source)
    spatial = np.maximum(half - extrema(full, source), 0)
    extrapolated = np.maximum(half - extrema(move(source, halfway, 2, limits), source), 0)
    black, white = limits
    derivative = np.maximum(half + black, 0) * np.maximum(white - half, 0) / (white + black)
    cross = extrapolated[:, ::-1] * np.clip(derivative / (derivative[:, ::-1] + .025), 0, 8)
    chroma = np.ptp(source, axis=1, keepdims=True) / (source.max(axis=1, keepdims=True) + .05)
    speed = np.clip(((extrema(source, source) - half) / (derivative + .025) - .35) / .5, -2, 2)
    terms = (spatial, extrapolated, cross, chroma * extrapolated, chroma * spatial, derivative * speed ** 2)
    design = np.concatenate([basis * term[:, :, None] for term in terms], axis=2)

    error = abs(target - full).max(axis=1)
    p95 = nearest_rank(error, .95)
    count = len(error)
    bins = np.searchsorted([.15, .35, .55, .75, .9, .96, .99], levels[:, 1])
    frequencies = np.bincount(bins, minlength=8)[bins]
    weights = (2 / 3 + (count / 24) / np.maximum(frequencies, count * .008)) / (count * max(.025, p95))
    weights *= 1 + np.minimum(error / max(p95, .02), 2)
    change = half - extrema(target, source) - spatial
    gram = np.stack([bound.T @ (bound * weights[:, None]) for bound in design.transpose(1, 0, 2)])
    return gram, np.einsum('nej,ne,n->ej', design, change, weights)


def capture(case, score, args):
    """Rerender the old 0/−50/−100 endpoints and bind them to the whole-image signed −50 comparison."""
    source = Path(case['file'])
    if digest(source) != case['source'] or any(case[k] != score[k] for k in
            ('id', 'source', 'icc', 'xmp', 'referenceSHA256', 'neutralReferenceSHA256')):
        raise ValueError(f"Unpaired source or historical public score for {case['id']}")
    adobe = []
    for root, key, target, amount in [(case['neutralRoot'], case['neutralID'], case['neutralReferenceSHA256'], 0),
                                      (case['root'], case['id'], case['referenceSHA256'], -50)]:
        folder = Path(root)
        frozen = FrozenSet(folder)
        row = next(r for r in read(folder / 'cases.json')['cases'] if r['id'] == key)
        ref = frozen.references[key]
        if (row['parameters'] != ({CONTROL: amount} if amount else {})
                or row['inputSHA256'] != case['source'] or digest(row['input']) != case['source']
                or not digest(row['settings']) == row['settingsSHA256'] == ref['settingsSHA256']
                or (amount and row['settingsSHA256'] != case['xmp'])
                or float(ref['resolvedSettings'][CONTROL]) != amount or ref['referenceSHA256'] != target
                or ref['inspection']['bits'] != 16 or frozen.decoded[key]['space'] != 'extended-linear Display-P3 D65'):
            raise ValueError(f'Invalid reference or resolved settings for {key}')
        with Image.open(folder / ref['reference']) as image:
            profile = image.info['icc_profile']
        if hashlib.sha256(profile).hexdigest() != case['icc']:
            raise ValueError(f'Changed output profile for {key}')
        adobe.append(frozen.read(key)[..., :3])

    with TemporaryDirectory() as temp:
        work = Path(temp)
        icc = work / 'output.icc'
        icc.write_bytes(profile)
        request = work / 'request.json'
        request.write_text(json.dumps([dict(id=str(-a), control=CONTROL, amount=a,
                                           input=source.resolve().as_uri(), icc=icc.as_uri()) for a in (0, -50, -100)]))
        png, decoded = work / 'png', work / 'decoded'
        png.mkdir()
        env = dict(os.environ, PACKAGE_RESOURCE_BUNDLE_PATH=str(args.bundle.resolve()))
        subprocess.run([args.renderer.resolve(), request, png, args.kernel, 'half'], env=env,
                       check=True, stdout=subprocess.DEVNULL)
        subprocess.run([args.decoder.resolve(), decoded, *sorted(png.glob('*.png'))], check=True, stdout=subprocess.DEVNULL)
        native = {}
        for r in read(decoded / 'manifest.json'):
            if digest(r['input']) != r['sha256'] or r['space'] != 'extended-linear Display-P3 D65':
                raise ValueError(f"Invalid public decode for {r['input']}")
            rgba = np.fromfile(decoded / r['output'], '<f4').reshape(r['height'], r['width'], 4)
            if not np.isfinite(rgba).all() or not np.all(rgba[..., 3] == 1):
                raise ValueError(f"Nonfinite or transparent public output in {r['input']}")
            native[Path(r['input']).stem] = rgba[..., :3]
        x, e, b = [native[k] for k in ('0', '50', '100')]
        n, t = adobe
        if not x.shape == e.shape == b.shape == n.shape == t.shape:
            raise ValueError('Reference and public image dimensions disagree')
        if (hashlib.sha256(np.ascontiguousarray(e).data).hexdigest() != score['samples']
                or nearest_rank(abs(e - t).max(axis=2).ravel(), .95) != score['p95']
                or nearest_rank(abs((e - x) - (t - n)).max(axis=2).ravel(), .95) != score['response']):
            raise ValueError(f"Public −50 image does not reproduce the baseline for {case['id']}")
        count = x.shape[0] * x.shape[1]
        indices = np.random.default_rng(int(case['source'][:12], 16)).choice(count, min(count, 10000), replace=False)
        return [rgb.reshape(-1, 3)[indices].astype('f8') for rgb in (x, e, b, n, t)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name, help_text in [('research', 'parent of the registered chart acquisitions'),
                            ('cases', 'registered experiment cases, including neutral and source identities'),
                            ('scores', 'whole-image scores from the baseline macOS half-float run'),
                            ('renderer', 'macOS public feature renderer used for the baseline'),
                            ('bundle', 'folder containing the baseline Metal and Parametric resource bundles'),
                            ('decoder', 'macOS Light/decode.swift executable')]:
        parser.add_argument(name, type=Path, help=help_text)
    parser.add_argument('--check', type=Path, help='check the bounds, levels and 84 weights against Metal')
    args = parser.parse_args()
    limits, charts = fit_limits(args.research)
    scores = read(args.scores)
    args.kernel = scores['kernel']
    if digest(args.bundle / KERNEL) != args.kernel:
        raise ValueError('Renderer resources differ from the baseline')
    scores = {r['id']: r for r in scores['rows']}
    registered = read(Path(__file__).with_name('highlights-strength-calibration.json'))['samples']
    sources = {r['sourceSHA256']: r['adjustedReferenceSHA256'] for r in registered}
    lattice = next(p for p in charts if p['id'] == 'adjust-chart-Highlights2012--50')
    sources[lattice['source']] = lattice['reference']['referenceSHA256']
    cases = [c for c in read(args.cases)['cases'] if c['control'] == CONTROL and c['amount'] == -50 and c['source'] in sources]
    if len(cases) != 34 or {c['source'] for c in cases} != sources.keys():
        raise ValueError('Expected 34 distinct calibration sources')
    systems = []
    for case in cases:
        if case['referenceSHA256'] != sources[case['source']]:
            raise ValueError(f"Wrong signed reference for {case['id']}")
        pixels = capture(case, scores[case['id']], args)
        group = case['kind']
        if group == 'chart':
            group = 'color' if (np.ptp(pixels[0], axis=1) > .01).any() else 'gray'
            if case['sourceId'] in ('adaptive-ramp', 'adaptcal-low-ramp', 'adaptcal-high-ramp'):
                group = 'ramp'
        systems.append((group, *equations(*pixels, limits)))
    counts = Counter(g for g, _, _ in systems)
    if counts != {'gray': 17, 'color': 4, 'ramp': 3, 'photo': 9, 'cube': 1} or digest(args.bundle / KERNEL) != args.kernel:
        raise ValueError('Unexpected image families or changed renderer resources')
    gram = sum(matrix / counts[group] for group, matrix, _ in systems)
    rhs = sum(target / counts[group] for group, _, target in systems)
    diag = gram.diagonal(axis1=1, axis2=2)
    penalty = .03 * np.maximum(diag, .006 * diag.max(axis=1, keepdims=True)) + 1e-8
    coefficients = np.stack([np.linalg.solve(g + np.diag(p), r) for g, p, r in zip(gram, penalty, rhs)])
    table = coefficients.reshape(2, 6, 7).transpose(2, 1, 0)
    if args.check:
        metal = args.check.read_text()
        bounds = [float(re.search(rf'const float {name} = ([.\d]+)f;', metal)[1])
                  for name in ('highlightBlackRoom', 'highlightWhiteLimit')]
        np.testing.assert_allclose(bounds, limits, atol=1e-6, rtol=0)
        levels = re.search(r'const float level\[7\] = \{ ([^}]+) \};', metal)[1]
        np.testing.assert_allclose([float(v.strip().removesuffix('f')) for v in levels.split(',')], LEVELS)
        # The two chroma-weighted columns can be interchanged without affecting any gray-ramp test.
        terms = re.search(r'float2 terms\[6\] = \{([^}]+)\};', metal)[1].split(',')
        if [' '.join(term.split()) for term in terms] != [
                'spatialLoss', 'extrapolated', 'cross', 'chroma * extrapolated',
                'chroma * spatialLoss', 'derivative * speed * speed']:
            raise ValueError('The shader weights and fitted response columns have different meanings')
        block = metal.split('strongHighlightLossWeights[7][6] = {', 1)[1].split('};', 1)[0]
        stored = [[float(v.strip().removesuffix('f')) for v in pair.split(',')] for pair in re.findall(r'float2\(([^)]+)\)', block)]
        np.testing.assert_allclose(np.array(stored).reshape(7, 6, 2), table, atol=2e-6, rtol=0)
    print(json.dumps(dict(kernel=args.kernel, blackRoom=limits[0], whiteLimit=limits[1], weights=table.tolist(),
                          groups=counts, sources=sources, charts=charts), indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
