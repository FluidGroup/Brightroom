"""Find which public Brightroom slider setting most closely reproduces a registered Lightroom edit."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory

import numpy as np
from paired_light import HERE, acquire, decode, p95, read
from tone_chart import digest

REPO = HERE.parents[2]


def sweep(acquired, renderer, decoder, output, env):
    case, target, icc, packet, metrics, control, amount = acquired
    identity = case['id']
    out = output / identity
    out.mkdir()
    with TemporaryDirectory() as temp:
        tmp = Path(temp)
        adobe = decode(target, decoder, tmp / 'reference')
        frozen = decode(metrics['candidate']['path'], decoder, tmp / 'native')
        paired = metrics['adjustmentResponseError']
        zero = decode(paired['referenceBaseline']['path'], decoder, tmp / 'reference-neutral')
        native_zero = decode(paired['candidateBaseline']['path'], decoder, tmp / 'native-neutral')
        if not adobe.shape == frozen.shape == zero.shape == native_zero.shape:
            raise ValueError(f'Unpaired dimensions for {identity}')
        count = int(np.prod(adobe.shape[:2]))
        if count < 2:
            raise ValueError('At least two independent pixels are needed for fitting and checking')
        half = min(8192, count // 2)
        rng = np.random.default_rng(int(case['inputSHA256'][:16], 16))
        fit, check = np.split(rng.choice(count, 2 * half, replace=False), 2)
        reference = adobe.reshape(-1, 3)

        def score(rgb):
            return dict(fullP95=p95(rgb, adobe), checkP95=p95(rgb.reshape(-1, 3)[check], reference[check]),
                        responseP95=p95(rgb, adobe, (native_zero, zero)))
        baseline = score(frozen)
        if (baseline['fullP95'] != metrics['pixelMaxChannelError']['p95']
                or baseline['responseP95'] != paired['pixelMaxChannelError']['p95']):
            raise ValueError(f'Could not reproduce the original whole-image comparison for {identity}')
        best = None
        probes = []
        upper_whites = {}
        # Include the supplied XMP position first. Exact ties prefer the nearest authored integer.
        direction = 1 if amount > 0 else -1
        amounts = sorted(range(0, 101 * direction, direction), key=lambda v: (abs(v - amount), v))
        for value in amounts:
            with TemporaryDirectory(dir=tmp) as run:
                run = Path(run)
                settings = run / 'settings.json'
                packet['settings'][control] = str(value)
                settings.write_text(json.dumps(packet))
                subprocess.run([renderer, case['input'], settings, run / 'native', 'adaptive'],
                               check=True, env=env, stdout=subprocess.DEVNULL)
                rendered = run / 'native/brightroom.png'
                proof = read(run / 'native/render.json')
                if (proof['inputSHA256'] != case['inputSHA256'] or proof['settingsSHA256'] != digest(settings)
                        or proof['outputSHA256'] != digest(rendered) or proof['outputICCSHA256'] != icc
                        or proof['workingFormat'] != 'RGBAh' or proof['mode'] != 'adaptive'):
                    raise ValueError(f'Mismatched public render at {identity} {value:+}')
                rgb = decode(rendered, decoder, run / 'decoded')
                if control == 'Whites2012' and value >= 75:
                    upper_whites[value] = rgb.reshape(-1, 3)[check]
                if rgb.shape != adobe.shape or (value == amount and not np.array_equal(rgb, frozen)):
                    raise ValueError(f'Public renderer differs from the recorded candidate for {identity} {value:+}')
                if value == 0 and not np.array_equal(rgb, native_zero):
                    raise ValueError(f'Zero does not reproduce the paired public neutral for {identity}')
                error = p95(rgb.reshape(-1, 3)[fit], reference[fit])
                probes.append(dict(amount=value, fitP95=error))
                if best is None or error < best['fitP95']:
                    best = dict(amount=value, fitP95=error, pngSHA256=proof['outputSHA256'])
                    shutil.copyfile(rendered, out / 'closest.png')
        best.update(score(decode(out / 'closest.png', decoder, tmp / 'closest')))
        result = dict(id=identity, control=control, authored=amount, sourceSHA256=case['inputSHA256'],
                      xmpSHA256=case['settingsSHA256'], referenceSHA256=digest(target), referenceICC=icc,
                      pixels=count, fitPixels=half, checkPixels=half, baseline=baseline, closest=best,
                      curve=sorted(probes, key=lambda r: r['amount']))
        if upper_whites:
            # Compare the same check pixels in slider order, independently of which
            # integer the Lightroom reference selected as the closest match.
            steps = []
            for value in range(76, 101):
                decrease = (upper_whites[value - 1] - upper_whites[value]).max(axis=1)
                steps.append(dict(fromAmount=value - 1, toAmount=value,
                                  largestChannelDecrease=max(0.0, float(decrease.max())),
                                  pixelsWithChannelDecrease=int(np.count_nonzero(decrease > 0.0001))))
            result['upperWhitesTransitions'] = dict(checkPixels=half, decreaseThreshold=0.0001, steps=steps)
        print(identity, amount, '->', best['amount'], baseline['fullP95'], '->', best['fullP95'], flush=True)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path, help='paired report.json from A10/run.py')
    parser.add_argument('output', type=Path, help='new directory for the measured curves and closest renders')
    parser.add_argument('--case-id', required=True, action='append')
    parser.add_argument('--renderer', type=Path, default=REPO / '.tmp/xmp-derived-data/Build/Products/Debug/render-a10')
    args = parser.parse_args()
    if len(set(args.case_id)) != len(args.case_id):
        parser.error('Case IDs must be unique')
    report = args.report.resolve()
    renderer = args.renderer.resolve(strict=True)
    products = Path(os.environ.get('PACKAGE_RESOURCE_BUNDLE_PATH', renderer.parent)).resolve()
    env = dict(os.environ, PACKAGE_RESOURCE_BUNDLE_PATH=str(products))
    resources = [products / 'Brightroom_BrightroomColorAdjustmentKernels.bundle/Contents/Resources/BrightroomColorAdjustments-macos.metallib',
                 *sorted((products / 'Brightroom_BrightroomParametric.bundle/Contents/Resources').glob('*'))]
    if len(resources) < 2 or not all(p.is_file() for p in resources):
        raise ValueError(f'Expected the macOS comparison renderer and its package resources in {products}')
    fingerprints = {str(p): digest(p) for p in [renderer, *resources]}
    cases = [acquire(report, key) for key in args.case_id]
    if args.output.exists():
        parser.error(f'Output already exists: {args.output}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=args.output.parent) as temp:
        staged = Path(temp) / 'result'
        staged.mkdir()
        decoder = Path(temp) / 'decode'
        subprocess.run(['xcrun', 'swiftc', '-O', HERE / 'decode.swift', '-o', decoder], check=True)
        rows = [sweep(case, renderer, decoder, staged, env) for case in cases]
        if not all(digest(p) == value for p, value in fingerprints.items()):
            raise ValueError('Comparison renderer or package resources changed during the sweep')
        (staged / 'report.json').write_text(json.dumps(dict(
            method='Public adaptive GPU renders at every same-sign integer setting including zero. Selection on fit pixels only.',
            units='Nearest-rank p95 of max-channel absolute error in linear Display P3, white = 1.',
            report=str(report), reportSHA256=digest(report), buildSHA256=fingerprints, rows=rows),
            indent=2, allow_nan=False) + '\n')
        staged.rename(args.output)


if __name__ == '__main__':
    main()
