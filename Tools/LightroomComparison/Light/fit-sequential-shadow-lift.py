"""Fit the shadow attenuation in a sequential public Highlights/Shadows render of the registered −35/+42 chart."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

import numpy as np
from PIL import Image

from error_metrics import nearest_rank
from paired_light import decode, read, read_adjustments
from tone_chart import digest


def reference(study, name, neutral):
    """Bind the joint or neutral edit and its embedded export profile to the same chart."""
    case, = [c for c in read(study / 'cases.json')['cases'] if c['id'] == name]
    ref, = [r for r in read(study / 'references.json')['references'] if r['id'] == name]
    path = study / ref['reference']
    xmp = Path(case['settings'])
    settings, curves = read_adjustments(xmp)
    if (digest(case['input']) != case['inputSHA256'] or digest(xmp) != case['settingsSHA256']
            or ref['settingsSHA256'] != case['settingsSHA256'] or digest(path) != ref['referenceSHA256']):
        raise ValueError(f'Stale registration for {name}')
    expected = {} if neutral else {'Highlights2012': -35, 'Shadows2012': 42}
    if case['parameters'] != expected or (neutral and case['group'] != 'neutral'):
        raise ValueError(f'Expected the original neutral and isolated two-control chart at {name}')
    for key in ('Highlights2012', 'Shadows2012'):
        if not float(settings[key]) == float(ref['resolvedSettings'][key]) == expected.get(key, 0):
            raise ValueError(f'Unexpected slider amount for {name}')
    with Image.open(path) as tiff:
        if tiff.mode != 'RGB' or tuple(tiff.tag_v2[258]) != (16, 16, 16) or tiff.size != (1024, 256):
            raise ValueError(f'Expected the 16-bit two-ramp, color lattice TIFF for {name}')
        profile = tiff.info['icc_profile']
    return case, ref, path, profile, settings, curves


def fit(args, work):
    neutral = reference(args.registration, 'adjust-chart-neutral', True)
    joint = reference(args.registration, 'adjust-chart-hs', False)
    zero_case, zero_ref, zero_tiff, zero_icc, zero_settings, zero_curves = neutral
    case, ref, edited_tiff, profile, settings, curves = joint
    controls = {'Highlights2012', 'Shadows2012'}
    if (zero_case['inputSHA256'] != case['inputSHA256'] or profile != zero_icc or curves != zero_curves
            or any(settings.get(k) != zero_settings.get(k) for k in (settings.keys() | zero_settings.keys()) - controls)):
        raise ValueError('The pair must differ only in Highlights and Shadows on the same source and ICC')
    def applied(other):
        return {k: v for k, v in other['resolvedSettings'].items() if k not in controls | {'RawFileName'}}
    if applied(zero_ref) != applied(ref):
        raise ValueError('The applied Lightroom pair changes additional settings')

    decoder = args.decoder.resolve()
    products = args.products.resolve()
    icc_file = work / 'reference.icc'
    icc_file.write_bytes(profile)
    native = work / 'render'
    driver = Path(__file__).with_name('render-sequential-light.swift')
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-O', '-I', products, driver,
                    products / 'BrightroomParametric.o', products / 'BrightroomColorAdjustmentKernels.o',
                    '-o', native], check=True)
    env = dict(os.environ, PACKAGE_RESOURCE_BUNDLE_PATH=str(products))
    zero = decode(zero_tiff, decoder, work / 'adobe-neutral')
    target = decode(edited_tiff, decoder, work / 'adobe-joint')
    width = target.shape[1]
    indices = np.arange(0, width * target.shape[0], 4)
    # Reserve alternating 16-row by 128-column blocks of the same chart for the fit check.
    in_fit = ((indices // width // 16 + indices % width // 128) % 4) != 0

    def render(h, s):
        with TemporaryDirectory(dir=work) as tmp:
            tmp = Path(tmp)
            output = tmp / 'output.png'
            subprocess.run([native, case['input'], icc_file, output, str(h), str(s)], check=True, env=env)
            return decode(output, decoder, tmp / 'decoded').reshape(-1, 3)[indices].astype(np.float64)

    goal = (target.reshape(-1, 3)[indices].astype(np.float64)
            - zero.reshape(-1, 3)[indices] + render(0, 0))
    h, s = float(settings['Highlights2012']), float(settings['Shadows2012'])
    # The second-stage highlight attenuation comes from the separate Adobe-only slider sweeps.
    highlight = h / (1 + s * .029549)
    measurements = []

    def residual(coefficient):
        pixels = render(highlight, s / (1 + abs(h) * coefficient))
        difference = pixels - goal
        measurements.append(dict(coefficient=coefficient, fitMSE=float(np.mean(difference[in_fit] ** 2)),
                                 checkMSE=float(np.mean(difference[~in_fit] ** 2)),
                                 p95=nearest_rank(abs(difference).max(axis=1).astype('f4'), .95)))
        return difference[in_fit].ravel()

    # One bounded coefficient is estimated from measured changes between neighbouring renders.
    # A finite difference step avoids differentiating the quantization noise of a 16-bit export.
    coefficient = .011059
    error = residual(coefficient)
    for step in (.002, .001, .0006, .00035):
        lower = max(0., coefficient - step)
        higher = coefficient + step
        direction = (residual(higher) - residual(lower)) / (higher - lower)
        update = float(np.linalg.lstsq(direction[:, None], -error, rcond=None)[0][0])
        previous = coefficient
        for fraction in (1., .5):
            candidate = float(np.clip(previous + fraction * update, 0, .15))
            trial = residual(candidate)
            if np.mean(trial ** 2) < np.mean(error ** 2):
                coefficient, error = candidate, trial
    return dict(shadowsPerHighlight=coefficient, highlightsPerShadow=.029549,
                sourceSHA256=case['inputSHA256'], xmpSHA256=case['settingsSHA256'],
                referenceSHA256=ref['referenceSHA256'], neutralSHA256=zero_ref['referenceSHA256'],
                outputICC=sha256(profile).hexdigest(), rendererSHA256=digest(native),
                parametricObjectSHA256=digest(products / 'BrightroomParametric.o'),
                fitPixels=int(in_fit.sum()), checkPixels=int((~in_fit).sum()), trials=measurements)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registration', type=Path)
    parser.add_argument('output', type=Path, help='new JSON evidence file')
    parser.add_argument('--products', type=Path, required=True, help='Xcode macOS Debug products directory')
    parser.add_argument('--decoder', type=Path, required=True, help='compiled Light/decode.swift')
    args = parser.parse_args()
    with TemporaryDirectory() as tmp:
        report = fit(args, Path(tmp))
    with args.output.open('x') as stream:
        stream.write(json.dumps(report, indent=2, allow_nan=False) + '\n')
