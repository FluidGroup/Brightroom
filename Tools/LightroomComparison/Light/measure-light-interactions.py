"""Measure how far a registered joint Light adjustment departs from the sum of its parts.

Each --joint or --part takes a registration directory, adjusted case ID and
matching neutral ID. Give all pairs the same ICC-decoded pixel grid. A part
may be a group of sliders if its controls are disjoint from the other parts.
"""
import argparse
from functools import cache
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


@cache
def registration(root):
    directory = Path(root)
    cases = json.loads((directory / 'cases.json').read_text())['cases']
    refs = json.loads((directory / 'references.json').read_text())['references']
    return {c['id']: c for c in cases}, {r['id']: r for r in refs}


def encode(rgb):
    return np.where(rgb <= .0031308, 12.92*rgb, 1.055*np.maximum(rgb, 0)**(1/2.4) - .055)


def decode(rgb):
    return np.where(rgb <= .04045, rgb/12.92, (np.maximum(rgb + .055, 0)/1.055)**2.4)


def lattice_delta(table, rgb):
    """Sample measured linear deltas at an encoded-P3 color, as TonalPointRecipe does."""
    position = np.clip(encode(rgb), 0, 1) * 31
    lower = np.minimum(np.floor(position), 30).astype(int)
    fraction = position - lower
    order = np.argsort(-fraction, axis=-1)
    high, middle, low = np.moveaxis(np.take_along_axis(fraction, order, axis=-1), -1, 0)
    strides = np.array([1, 32, 1024])
    first, _, last = np.moveaxis(strides[order], -1, 0)
    index = lower @ strides
    diagonal = strides.sum()
    return ((1 - high)[..., None] * table[index]
            + (high - middle)[..., None] * table[index + first]
            + (middle - low)[..., None] * table[index + diagonal - last]
            + low[..., None] * table[index + diagonal])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('decoded', type=Path, help='directory produced by decode.swift or decode-samples.swift')
    parser.add_argument('output', type=Path)
    parser.add_argument('--joint', nargs=3, required=True, metavar=('SET', 'ADJUSTED', 'NEUTRAL'))
    parser.add_argument('--part', nargs=3, required=True, action='append', metavar=('SET', 'ADJUSTED', 'NEUTRAL'))
    parser.add_argument('--sequential-tonal-points', action='store_true',
                        help='on the full calibration chart, apply the measured Whites/Blacks pair to the first part')
    parser.add_argument('--infer-before-point-controls', action='store_true',
                        help='estimate the H/S output from separate W, B and saturation measurements on the full chart')
    args = parser.parse_args()
    decoded = {d['output']: d for d in json.loads((args.decoded / 'manifest.json').read_text())}
    evidence = {}

    @cache
    def image(root, key):
        cases, refs = registration(root)
        c, r = cases[key], refs[key]
        row = decoded[key + '.rgba32f']
        reference_path = Path(root) / r['reference']
        reference_hash = digest(reference_path)
        if (reference_hash != r['referenceSHA256'] or reference_hash != row['sha256']
                or digest(c['input']) != c['inputSHA256']
                or digest(c['settings']) != c['settingsSHA256'] or r['settingsSHA256'] != c['settingsSHA256']):
            raise ValueError(f'Changed registration or decode for {key}')
        if row['space'] != 'extended-linear Display-P3 D65' or not row['format'].startswith('little-endian Float32 RGBA'):
            raise ValueError(f'Unexpected pixel format for {key}')
        with Image.open(reference_path) as image:
            icc = hashlib.sha256(image.info['icc_profile']).hexdigest()
            recorded_icc = (r.get('inspection') or {}).get('iccSHA256') or (r.get('outputICC') or {}).get('sha256')
            if (image.mode != 'RGB' or tuple(image.tag_v2[258]) != (16, 16, 16)
                    or (recorded_icc is not None and icc != recorded_icc)):
                raise ValueError(f'Unexpected reference precision or embedded profile for {key}')
        file = args.decoded / row['output']
        rgba = np.memmap(file, dtype='<f4', mode='r').reshape(row['height'], row['width'], 4)
        if not np.isfinite(rgba).all() or not np.all(abs(rgba[..., 3]-1) < 1e-6):
            raise ValueError(f'Nonfinite or nonopaque pixels for {key}')
        evidence[key] = dict(source=c['inputSHA256'], xmp=r['settingsSHA256'], tiff=reference_hash,
                             decoded=digest(file), iccSHA256=icc, stride=row.get('stride', 1))
        return rgba[..., :3].astype(np.float64)

    controls = {'Exposure2012', 'Contrast2012', 'Highlights2012', 'Shadows2012',
                'Whites2012', 'Blacks2012', 'Saturation', 'Vibrance'}

    def neutral_settings(settings):
        # Some neutral TIFFs retain the last grain size and frequency. They are
        # inactive at Amount zero. Keep every active setting in this comparison.
        ignored = {'RawFileName'}
        if float(settings.get('GrainAmount', 0)) == 0:
            ignored.update(['GrainSize', 'GrainFrequency', 'GrainSeed'])
        return {k: v for k, v in settings.items() if k not in ignored}

    def pair(root, adjusted, neutral):
        cases, refs = registration(root)
        if cases[neutral]['group'] != 'neutral':
            raise ValueError(f'Expected a registered neutral case for {neutral}')
        a, b = (refs[key]['resolvedSettings'] for key in [adjusted, neutral])
        if any(float(b.get(k, 0)) != 0 for k in controls):
            raise ValueError(f'Nonzero base Light slider in {neutral}')
        for k in (set(a) | set(b)) - controls - {'RawFileName'}:
            if a.get(k) != b.get(k):
                raise ValueError(f'{adjusted} also changes {k}')
        settings = {k: float(a[k]) for k in sorted(controls) if float(a.get(k, 0)) != 0}
        return image(root, adjusted), image(root, neutral), settings, neutral_settings(b)

    joint, base, settings, base_settings = pair(*args.joint)
    linear = base.copy()
    encoded = encode(base)
    combined = {}
    parts = []
    for spec in args.part:
        adjusted, neutral, values, part_base = pair(*spec)
        if base_settings != part_base:
            raise ValueError(f'Incompatible neutral settings in {spec[2]}')
        if not values or combined.keys() & values.keys():
            raise ValueError(f'Empty or overlapping controls in {spec[1]}')
        combined.update(values)
        parts.append((adjusted, neutral, values))
        if neutral.shape != joint.shape or adjusted.shape != joint.shape:
            raise ValueError('All exports must have the same dimensions')
        linear += adjusted - neutral
        encoded += encode(adjusted) - encode(neutral)
    if combined != settings:
        raise ValueError('The parts must exactly cover the joint slider values')
    if len({(r['source'], r['stride'], r['iccSHA256']) for r in evidence.values()}) != 1 or joint.shape != base.shape:
        raise ValueError('All exports must use the same source, output profile and pixel grid')

    def measure(prediction):
        error = prediction - joint
        return dict(p95=float(np.quantile(np.abs(error).max(-1), .95, method='inverted_cdf')),
                    rmse=float(np.mean(error**2)**.5), meanRGB=error.mean(axis=(0, 1)).tolist())

    result = dict(settings=settings, samples=joint.shape[0]*joint.shape[1], inputs=evidence,
                  linearSum=measure(linear), encodedSum=measure(decode(encoded)))
    if args.sequential_tonal_points or args.infer_before_point_controls:
        if (base.shape != (256, 1024, 3)
                or any(r['stride'] != 1 for r in evidence.values())
                or not all(np.array_equal(neutral, base) for _, neutral, _ in parts)):
            raise ValueError('Expected the same full calibration chart and neutral for each part')
        # Below the two 64-row ramps, each blue slice of the RGB cube repeats four times.
        # The neutral TIFF includes the small color conversion performed by Lightroom.
        nodes = base[128::4].reshape(-1, 3)
        axis = np.arange(32**3)
        grid = np.column_stack((axis % 32, axis // 32 % 32, axis // 1024)) / 31
        if np.max(abs(encode(nodes) - grid)) > .02:
            raise ValueError('Neutral colors do not follow the encoded-P3 lattice layout')
    if args.sequential_tonal_points:
        if (len(parts) != 2 or set(parts[0][2]) != {'Highlights2012', 'Shadows2012'}
                or set(parts[1][2]) != {'Whites2012', 'Blacks2012'} or parts[1][2]['Whites2012'] >= 0):
            raise ValueError('Expected Highlights/Shadows first, then negative Whites and Blacks')
        hs, wb = parts[0][0], parts[1][0]
        table = (wb - base)[128::4].reshape(-1, 3)
        result['sequentialMeasuredTonalPoints'] = measure(hs + lattice_delta(table, hs))
        # Subtract lookup error already present on the neutral input to isolate
        # the residual that changes when the first pair of sliders is active.
        result['sequentialAfterNeutralCorrection'] = measure(
            hs + lattice_delta(table, hs) - lattice_delta(table, base) + (wb - base))
    if args.infer_before_point_controls:
        sliders = ['Highlights2012', 'Shadows2012', 'Whites2012', 'Blacks2012', 'Saturation']
        if (len(parts) != len(sliders) or any(len(values) != 1 for _, _, values in parts)
                or set(settings) != set(sliders) or settings['Highlights2012'] >= 0
                or settings['Shadows2012'] <= 0 or settings['Whites2012'] >= 0):
            raise ValueError('Expected five single-slider references including negative Highlights/Whites and positive Shadows')
        adjusted = {next(iter(values)): pixels for pixels, _, values in parts}
        tables = [(adjusted[slider] - base)[128::4].reshape(-1, 3) for slider in sliders[2:]]

        def forward(pixels):
            for table in tables:
                pixels = pixels + lattice_delta(table, pixels)
            return pixels

        # Invert only this measured stack. Reject settings for which the fixed-point
        # iteration fails to recover the observed joint export at export precision.
        inferred = joint.copy()
        for _ in range(12):
            correction = joint - forward(inferred)
            if np.max(abs(correction)) < 1e-6:
                break
            inferred += correction
        uncertainty = measure(forward(inferred))
        if uncertainty['p95'] > 1e-6:
            raise ValueError('The measured point operations could not be inverted to the requested precision')
        axes = np.column_stack([(adjusted[slider] - base).ravel() for slider in sliders[:2]])
        coefficients = np.linalg.lstsq(axes, (inferred - base).ravel(), rcond=None)[0]
        prediction = base + (axes @ coefficients).reshape(base.shape)
        result['inferredBeforePointControls'] = dict(roundTrip=uncertainty,
            fractionOfSoloResponse=dict(zip(sliders[:2], coefficients.tolist())),
            recomposedFromSoloResponses=measure(forward(prediction)))
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')


if __name__ == '__main__':
    main()
