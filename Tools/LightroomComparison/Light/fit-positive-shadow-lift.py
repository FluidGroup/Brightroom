"""Recover the positive Shadows slider coordinate and regional lift from registered Lightroom TIFFs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

import numpy as np
from PIL import Image

from adaptive_data import FrozenSet, P3_TO_ROMM
from shadow_interval import extrema, fit_range
from tone_chart import color_lattice, digest, registered_chart


CONTROL = 'Shadows2012'
LUMA = np.array([.22897457, .69173855, .07928692])
GRAY_VALIDATION = {'adaptcal-mid-ramp', 'scene-fit-scene-02', 'scene-fit-scene-07',
                   'scene-fit-scene-08', 'scene-fit-scene-13'}


def strength_coordinate(research):
    """Find the distances outside black and white using only the +10, +25 and +50 intervals."""
    charts, evidence = [], []
    for chart in ('ramp', 'lattice'):
        levels = {}
        identity = None
        for amount in (0, 10, 25, 50):
            weak = amount in (10, 25)
            if chart == 'lattice':
                root, prefix = ('response-model-001' if weak else 'adjustments-001'), 'adjust-chart-'
            else:
                root, prefix = ('adaptive-calibration-001', 'adaptcal-ramp-') if weak else ('adaptive-002', 'adaptive-ramp-')
            pixels, proof = registered_chart(research / root, prefix, CONTROL, amount)
            pair = (proof['source'], proof['profile'])
            if identity is not None and pair != identity:
                raise ValueError(f'Unpaired {chart} source or ICC at +{amount}')
            identity = pair
            evidence.append(proof)
            levels[amount] = color_lattice(pixels) if chart == 'lattice' else pixels[128, :, :3].astype(float)
        charts.append(levels)
    black, white = fit_range(charts, (10, 25, 50))
    return black, 1 + white, evidence


def calibration_sources(research, layouts, working, photographs=None):
    """Pair each training chart or photograph with its neutral and original sampling grid."""
    sources = []
    roots = [research/'adjustments-001', research/'adaptive-002', research/'adaptive-calibration-001',
             research/'adaptive-scenes-001', layouts]
    if photographs:
        roots.append(photographs)
    for root in roots:
        catalog = FrozenSet(root)
        cases = json.loads((root/'cases.json').read_text())['cases']
        for case in cases:
            amount = -50 if root == photographs else 50
            if case['parameters'] != {CONTROL: amount} or case['kind'] != ('photo' if root == photographs else 'chart'):
                continue
            if root in (layouts, photographs) and case['split'] != 'calibration':
                continue
            key = case['id']
            name = key.removesuffix('-Shadows2012-50')
            if name in GRAY_VALIDATION:
                continue
            neutral = next(c for c in cases if c['inputSHA256'] == case['inputSHA256'] and c['parameters'] == {})
            profile = None
            shape = None
            for row, setting in [(neutral, 0), (case, amount)]:
                ref = catalog.references[row['id']]
                decoded = catalog.decoded[row['id']]
                inspection = ref['inspection']
                with Image.open(root/ref['reference']) as image:
                    icc = hashlib.sha256(image.info['icc_profile']).hexdigest()
                if (digest(row['input']) != row['inputSHA256'] or digest(row['settings']) != row['settingsSHA256']
                        or ref['settingsSHA256'] != row['settingsSHA256'] or float(ref['resolvedSettings'][CONTROL]) != setting
                        or float(ref['resolvedSettings']['Highlights2012']) != 0 or inspection['bits'] != 16
                        or inspection['profile'] != 'ProPhoto RGB' or decoded['space'] != 'extended-linear Display-P3 D65'
                        or profile and profile != icc):
                    raise ValueError(f'Changed source, strength or color space for {key}')
                profile = icc
                size = (decoded['height'], decoded['width'])
                if shape and size != shape:
                    raise ValueError(f'Unpaired dimensions for {key}')
                shape = size
            count = int(np.prod(shape))
            if root == research/'adjustments-001':
                if shape != (256, 1024) or name != 'adjust-chart':
                    raise ValueError('Unexpected color lattice')
                indices = np.arange(count).reshape(shape)[130::4].ravel()
            else:
                limit = 10000 if root == photographs else (12000 if root == layouts else 7500)
                indices = np.linspace(0, count - 1, min(count, limit), dtype=int)
            path = working/(case['inputSHA256'] + '.u32')
            indices.astype('<u4').tofile(path)
            sources.append((case, neutral, catalog, indices, path, profile))
    expected = 39 if photographs else 30
    if len(sources) != expected or len({s[0]['inputSHA256'] for s in sources}) != expected:
        raise ValueError('Expected 30 distinct chart inputs and nine additional pictures when fitting both signs')
    return sources


def encode(linear):
    return np.where(linear <= .0031308, 12.92 * linear, 1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def fit_lift(sources, captures, decoder, black, white):
    """Recover the chart rates and the common signed response of the photographic calibration set."""
    a = np.zeros((12, 12))
    b = np.zeros(12)
    signed_a = np.zeros((16, 16))
    signed_b = np.zeros(16)
    contrasts = {'layout': [], 'photo': []}
    evidence = []
    for case, neutral, catalog, indices, _, profile in sources:
        key, source = case['id'], case['inputSHA256']
        z = catalog.read(neutral['id'])[..., :3]
        t = catalog.read(key)[..., :3]
        if z.shape != t.shape:
            raise ValueError(f'Changed source dimensions for {key}')
        t = (t.reshape(-1, 3)[indices].astype(float) - z.reshape(-1, 3)[indices])
        with tempfile.TemporaryDirectory(dir=captures.parent) as tmp:
            decoded = Path(tmp)/'pixels'
            subprocess.run([decoder, decoded, Path(case['input']).resolve()], check=True, stdout=subprocess.DEVNULL)
            row, = json.loads((decoded/'manifest.json').read_text())
            if (row['sha256'] != source or row['space'] != 'extended-linear Display-P3 D65'
                    or (row['height'], row['width']) != z.shape[:2]):
                raise ValueError(f'Unexpected decoded input for {key}')
            raw = np.memmap(decoded/row['output'], '<f4', 'r').reshape(-1, 4)[indices]
        if not np.isfinite(raw).all() or not np.all(raw[:, 3] == 1):
            raise ValueError(f'Nonfinite or nonopaque input for {key}')
        x = raw[:, :3].astype(float)
        target = x + t
        rgb = np.clip(x, 0, 1)
        romm = np.clip(rgb @ P3_TO_ROMM.T, 0, 1)
        bounds = extrema(romm, romm)
        desired = extrema(target @ P3_TO_ROMM.T, romm).clip(0, 1)
        code = encode(rgb @ (LUMA / LUMA.sum()))
        path = captures/(source + '-lift.f32')
        guide = np.fromfile(path, '<f4').reshape(-1, 4).astype(float)
        if len(guide) != len(x) or not np.isfinite(guide).all():
            raise ValueError(f'Invalid spatial measurement for {key}')
        mean, contrast, activity, region = guide.T
        scene_brightness = encode(np.exp((mean - 1) * 9.3))
        relative_brightness = encode(np.exp((region - 1) * 9.3)) - scene_brightness
        weights = np.maximum(1 - abs(code[:, None] * 3 - np.arange(4)), 0)
        signals = np.column_stack((np.ones(len(x)), contrast, relative_brightness))
        design = (weights[:, :, None] * signals[:, None, :]).reshape(-1, 12) * np.minimum(activity / .015, 1)[:, None]
        # Weight each endpoint by the derivative that maps its log-odds error back into linear RGB.
        derivative = np.clip((bounds + black) * (white - bounds) / (white + black), .005, .5)
        change = np.log((desired + black) / (white - desired)) - np.log((bounds + black) / (white - bounds))
        squared = derivative ** 2 / len(x)
        amount = case['parameters'][CONTROL]
        if amount == 50:
            a += (design.T * squared.sum(axis=1)) @ design
            b += design.T @ (squared * change).sum(axis=1)
        if amount < 0:
            family, family_weight = 'photo', .45 / 9
        elif key.startswith('color-layout-'):
            family, family_weight = 'layout', .16 / 4
        elif key.startswith('adjust-chart-'):
            family, family_weight = 'cube', .20
        else:
            family, family_weight = 'gray', .16 / 25
        if family in contrasts:
            contrasts[family].append(float(contrast[0]))
        # A clipped endpoint no longer measures the magnitude of its signed step.
        cells = ((bounds + black) * (white - bounds) / (white + black)) ** 2
        cells *= (desired > .0005) & (desired < .992)
        cells *= family_weight / len(x)
        signals = np.column_stack((signals, scene_brightness))
        signed = (weights[:, :, None] * signals[:, None, :]).reshape(-1, 16) * np.minimum(activity / .015, 1)[:, None]
        signed_a += (signed.T * cells.sum(axis=1)) @ signed
        signed_b += signed.T @ ((cells * change).sum(axis=1) * (50 / amount))
        evidence.append(dict(case=key, input=source, xmp=case['settingsSHA256'], profile=profile,
                             adjusted=catalog.evidence[key], neutral=catalog.evidence[neutral['id']],
                             samples=len(x), guide=digest(path), family=family, amount=amount))
    diagonal = np.diag(a)
    penalty = .001 * np.maximum(diagonal, diagonal.max() * .02) + 1e-12
    chart = np.linalg.solve(a + np.diag(penalty), b).reshape(4, 3)
    signed_rates = None
    transition = None
    if contrasts['photo']:
        diagonal = np.diag(signed_a)
        penalty = .004 * np.maximum(diagonal, diagonal.max() * .015)
        signed_rates = np.linalg.solve(signed_a + np.diag(penalty), signed_b).reshape(4, 4)
        transition = [max(contrasts['layout']), min(contrasts['photo'])]
        if not 0 <= transition[0] < transition[1]:
            raise ValueError('Registered scene contrasts no longer separate the two calibration ranges')
    return chart, signed_rates, transition, evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('research', type=Path)
    parser.add_argument('layouts', type=Path, help='registered synthetic-001 color layouts')
    parser.add_argument('library', type=Path, help='built macOS color-adjustments metallib')
    parser.add_argument('--photographs', type=Path, help='acquisition containing the nine negative Shadows calibration photographs')
    parser.add_argument('--check', type=Path, help='verify the rates and interval bounds in Metal')
    args = parser.parse_args()
    research, layouts, library = [p.resolve() for p in (args.research, args.layouts, args.library)]
    black, white, intervals = strength_coordinate(research)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        sources = calibration_sources(research, layouts, work, args.photographs.resolve() if args.photographs else None)
        requests = [dict(source=c['inputSHA256'], input=c['input'], indices=str(path))
                    for c, _, _, _, path, _ in sources]
        packet = work/'requests.json'
        packet.write_text(json.dumps(requests))
        tools = Path(__file__).resolve().parent
        for name in ['capture-tone-range', 'decode']:
            subprocess.run(['xcrun', 'swiftc', '-O', tools/(name+'.swift'), '-o', work/name], check=True)
        captures = work/'guides'
        subprocess.run([work/'capture-tone-range', library, packet, captures, '--positive-shadows'], check=True)
        rates, signed_rates, transition, evidence = fit_lift(sources, captures, work/'decode', black, white)
    if args.check:
        shader = args.check.read_text()
        source = shader.split('static float sceneShadowRate(', 1)[1].split('\n}', 1)[0]
        values = source.split('const float3 rates[4] = {', 1)[1].split('};', 1)[0]
        compiled = [[float(v.strip().removesuffix('f')) for v in row.split(',')] for row in re.findall(r'float3\(([^)]+)\)', values)]
        limits = [float(re.search(rf'constant float {name} = ([.\d]+)f;', shader)[1])
                  for name in ('shadowLiftBlackRoom', 'shadowLiftWhiteLimit')]
        np.testing.assert_allclose(compiled, rates, rtol=0, atol=1e-6)
        np.testing.assert_allclose(limits, [black, white], rtol=0, atol=1e-7)
        if signed_rates is not None:
            values = source.split('const float4 signedRates[4] = {', 1)[1].split('};', 1)[0]
            compiled = [[float(v.strip().removesuffix('f')) for v in row.split(',')] for row in re.findall(r'float4\(([^)]+)\)', values)]
            np.testing.assert_allclose(compiled, signed_rates, rtol=0, atol=1e-6)
            limits = re.search(r'smoothstep\(([.\d]+)f, ([.\d]+)f, contrast\)', source)
            np.testing.assert_allclose([float(v) for v in limits.groups()], transition, rtol=0, atol=1e-6)
    print(json.dumps(dict(blackRoom=black, whiteLimit=white, rates=rates.tolist(), kernel=digest(library),
                          signedRates=signed_rates.tolist() if signed_rates is not None else None,
                          contrastTransition=transition, intervalReferences=intervals, calibration=evidence), indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
