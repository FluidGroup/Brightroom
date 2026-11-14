"""Measure the contribution of each omitted group in a registered full-preset export.

Run after A10/run.py --scope ablation. The comparison for each group is
(Brightroom full - Brightroom without group) - (Lightroom full - Lightroom without group).
"""
import argparse
from functools import cache
import hashlib
import json
import math
from pathlib import Path
import subprocess

from xmp_settings import read_adjustments


def read(path):
    return json.loads(path.read_text())


@cache
def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path, help='a completed ablation run including the full preset')
    parser.add_argument('full_case', help='registered full-preset case ID')
    parser.add_argument('output', type=Path, help='new directory for the comparisons')
    parser.add_argument('--mode', default='adaptive')
    parser.add_argument('--explain-omission', metavar='CASE_ID',
                        help='measure which other group response errors point along or against this one')
    default_comparator = Path(__file__).resolve().parents[3] / '.tmp/xmp-derived-data/Build/Products/Debug/compare-a10'
    parser.add_argument('--comparator', type=Path, default=default_comparator)
    args = parser.parse_args()
    run = read(args.run / 'report.json')
    if run['scope'] != 'ablation' or run['work']['failures']:
        raise ValueError('A successful ablation run is required')
    results = {r['id']: r['metrics'] for r in run['cases'] if r['mode'] == args.mode}
    # An ablation belongs to its full preset's own registration and source photo.
    matches = []
    for snapshot in [args.run, *(args.run / 'registrations').glob('*')]:
        cases = {c['id']: c for c in read(snapshot / 'cases.json')['cases']}
        if args.full_case in cases:
            matches.append((cases, {r['id']: r for r in read(snapshot / 'references.json')['references']}))
    if len(matches) != 1:
        raise ValueError('The full preset must belong to exactly one registration')
    cases, references = matches[0]
    full = cases[args.full_case]
    if full['group'] != 'full' or full['id'] not in results:
        raise ValueError('The selected full preset must have a measured output in this mode')
    omitted = [c for c in cases.values() if c['id'] in results and c['group'].startswith('minus-')
               and c['inputSHA256'] == full['inputSHA256']]
    if not omitted:
        raise ValueError('No same-input omissions were measured in this mode')
    if args.explain_omission is not None and args.explain_omission not in {c['id'] for c in omitted}:
        raise ValueError('The omission to explain must belong to the measured full preset')

    def checked(case):
        key = case['id']
        ref, metrics = references[key], results[key]
        rendered = read(args.run / key / args.mode / 'render.json')
        settings_file = Path(case['settings'])
        configuration = args.run / key / 'settings.json'
        if (digest(case['input']) != case['inputSHA256'] or digest(settings_file) != case['settingsSHA256']
                or ref['settingsSHA256'] != case['settingsSHA256'] or rendered['inputSHA256'] != case['inputSHA256']
                or digest(configuration) != rendered['settingsSHA256']
                or not digest(metrics['reference']['path']) == metrics['reference']['sha256'] == ref['referenceSHA256']
                or not digest(metrics['candidate']['path']) == metrics['candidate']['sha256'] == rendered['outputSHA256']):
            raise ValueError(f'Source, settings or export changed for {key}')
        settings, curves = read_adjustments(settings_file)
        packet = read(configuration)
        if packet['settings'] != settings or packet['curves'] != curves or rendered['mode'] != args.mode:
            raise ValueError(f'The rendered configuration differs from the authored XMP in {key}')
        return settings | curves

    full_settings = checked(full)
    verified = []
    for case in omitted:
        settings = checked(case)
        kept = set(case['keys'])
        removed = set(full['keys']) - kept
        changed = {key for key in full_settings.keys() | settings.keys() if full_settings.get(key) != settings.get(key)}
        # The named preset changes between Custom and Linear with the master curve.
        allowed = removed | ({'ToneCurveName2012'} if 'ToneCurvePV2012' in removed else set())
        if not kept <= set(full['keys']) or not changed & removed or changed - allowed:
            raise ValueError(f'Unexpected changes in the group omission {case["id"]}: {sorted(changed)}')
        verified.append((case, sorted(changed)))

    args.output.mkdir(parents=True, exist_ok=False)
    def paired(adjusted, baseline, destination):
        subprocess.run([args.comparator, adjusted['reference']['path'], adjusted['candidate']['path'], destination,
                        baseline['reference']['path'], baseline['candidate']['path']], check=True, stdout=subprocess.DEVNULL)
        return read(destination / 'comparison.json')['adjustmentResponseError']

    def mse(metrics):
        return math.fsum(v * v for v in metrics['allPixels']['channelRMSE']) / 3

    summary = []
    response_mse = {}
    all_on = results[full['id']]
    for case, changed in verified:
        without = results[case['id']]
        dest = args.output / case['id']
        delta = paired(all_on, without, dest)
        response_mse[case['id']] = mse(delta)
        row = dict(id=case['id'], changedSettings=changed, sourceSHA256=case['inputSHA256'],
                   fullSettingsSHA256=full['settingsSHA256'], omissionSettingsSHA256=case['settingsSHA256'],
                   pixels=delta['allPixels']['pixels'], fullAbsolute=all_on['pixelMaxChannelError'],
                   withoutAbsolute=without['pixelMaxChannelError'], groupResponse=delta['pixelMaxChannelError'])
        if 'errorEnergy' in delta:
            row['errorEnergy'] = delta['errorEnergy']
        summary.append(row)
    report = dict(full=full['id'], mode=args.mode, comparison=__doc__, groups=summary)
    if args.explain_omission is not None:
        anchor = args.explain_omission
        base = results[anchor]
        anchor_mse = response_mse[anchor]
        # The difference between two full-minus-group responses is the difference of their two baselines.
        # Its squared length gives their dot product from three measured RGB energies.
        alignment = []
        for case, _ in verified:
            other = case['id']
            if other == anchor:
                continue
            delta = paired(results[other], base, args.output / 'alignment' / other)
            difference_mse = mse(delta)
            other_mse = response_mse[other]
            norm_product = math.sqrt(anchor_mse * other_mse)
            product = math.fsum((anchor_mse, other_mse, -difference_mse)) / 2 if norm_product else 0.0
            alignment.append(dict(id=other, differenceMSE=difference_mse, meanProduct=product,
                                  cosine=max(-1, min(1, product / norm_product)) if norm_product else None))
        # One-at-a-time omissions can overlap. Keep the unexplained projection as its own term.
        baseline_product = math.fsum((mse(all_on), -mse(base), -anchor_mse)) / 2 if anchor_mse else 0.0
        report['alignment'] = dict(omission=anchor, responseMSE=anchor_mse, baselineMeanProduct=baseline_product,
                                   groups=alignment, remainingMeanProduct=baseline_product - math.fsum(r['meanProduct'] for r in alignment))
    (args.output / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
