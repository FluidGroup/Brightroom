"""Read a registered Light setting, both neutral images, and the corresponding rendered pixels."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
from PIL import Image

from error_metrics import nearest_rank
from tone_chart import digest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'A10'))
from xmp_settings import read_adjustments


def read(path):
    return json.loads(Path(path).read_text())


def p95(candidate, reference, baselines=None):
    """Match compare.swift's Double subtractions and Float pixel maxima, including neutral subtraction."""
    candidate = candidate.reshape(-1, 3)
    reference = reference.reshape(-1, 3)
    if baselines is not None:
        candidate_zero, reference_zero = (image.reshape(-1, 3) for image in baselines)
    maxima = np.empty(len(candidate), np.float32)
    for start in range(0, len(maxima), 262144):
        part = slice(start, start + 262144)
        if baselines is None:
            difference = np.subtract(candidate[part], reference[part], dtype=np.float64)
        else:
            difference = (np.subtract(candidate[part], candidate_zero[part], dtype=np.float64)
                          - np.subtract(reference[part], reference_zero[part], dtype=np.float64))
        maxima[part] = np.abs(difference).max(axis=1)
    return nearest_rank(maxima, .95)


def decode(path, decoder, directory):
    """Decode the actual 16-bit file, retaining the source row order and linear values outside sRGB."""
    subprocess.run([decoder, directory, path], check=True, stdout=subprocess.DEVNULL)
    record, = read(directory / 'manifest.json')
    if record['space'] != 'extended-linear Display-P3 D65' or record['sha256'] != digest(path):
        raise ValueError(f'Changed file or working space for {path}')
    pixels = np.memmap(directory / record['output'], '<f4', 'r', shape=(record['height'], record['width'], 4))
    if not np.isfinite(pixels).all() or not (pixels[..., 3] == 1).all():
        raise ValueError(f'Expected finite opaque pixels in {path}')
    return pixels[..., :3]


def acquire(report, identity):
    """Bind a single-control export to the source, XMP, output profile and neutral captured by A10/run.py."""
    results = read(report)
    rows = [r for r in results['cases'] if r['id'] == identity and r['mode'] == 'adaptive']
    if not results.get('pairedNeutral') or len(rows) != 1:
        raise ValueError(f'Expected one paired adaptive render for {identity}')
    metrics = rows[0]['metrics']
    registrations = []
    for i, root in enumerate(results['registrations']):
        snapshot = report.parent if i == 0 else report.parent / 'registrations' / str(i)
        references = {r['id']: r for r in read(snapshot / 'references.json')['references']}
        registrations.extend((Path(root), c, references[c['id']]) for c in read(snapshot / 'cases.json')['cases']
                             if c['id'] in references)
    matches = [(root, case, ref) for root, case, ref in registrations if case['id'] == identity]
    if len(matches) != 1:
        raise ValueError(f'Ambiguous registration for {identity}')
    root, case, ref = matches[0]
    parameters = case['parameters']
    if len(parameters) != 1 or next(iter(parameters)) not in {'Highlights2012', 'Shadows2012', 'Whites2012', 'Blacks2012'}:
        raise ValueError(f'{identity} must isolate one Light slider')
    control, amount = next(iter(parameters.items()))
    settings, curves = read_adjustments(Path(case['settings']))
    packet = read(report.parent / identity / 'settings.json')
    target = root / ref['reference']
    if (digest(case['input']) != case['inputSHA256'] or digest(case['settings']) != case['settingsSHA256']
            or ref['settingsSHA256'] != case['settingsSHA256'] or not digest(target) == ref['referenceSHA256'] == metrics['reference']['sha256']
            or not float(settings[control]) == float(ref['resolvedSettings'][control]) == amount
            or not float(amount).is_integer() or not 0 < abs(amount) <= 100
            or settings != packet['settings'] or curves != packet['curves']):
        raise ValueError(f'Unpaired Lightroom source, settings or reference for {identity}')
    with Image.open(target) as image:
        if image.format != 'TIFF' or image.mode != 'RGB' or tuple(image.tag_v2[258]) != (16, 16, 16):
            raise ValueError(f'Expected a registered 16-bit RGB TIFF for {identity}')
        icc = hashlib.sha256(image.info['icc_profile']).hexdigest()
    if ref['inspection']['iccSHA256'] != icc or metrics['reference']['bitsPerComponent'] != 16:
        raise ValueError(f'Reference format or embedded profile changed for {identity}')
    native = metrics['candidate']
    paired = metrics['adjustmentResponseError']
    neutral = paired['referenceBaseline']
    neutrals = [(c, r) for _, c, r in registrations if c['group'] == 'neutral' and not c['parameters']
                and c['inputSHA256'] == case['inputSHA256'] and r['referenceSHA256'] == neutral['sha256']]
    if (not any(float(r['resolvedSettings'][control]) == 0
                and r['settingsSHA256'] == c['settingsSHA256'] == digest(c['settings']) for c, r in neutrals)
            or any(v['bitsPerComponent'] != 16 or digest(v['path']) != v['sha256']
                   for v in (native, neutral, paired['candidateBaseline']))):
        raise ValueError(f'Changed public output or missing same-source neutral for {identity}')
    with Image.open(neutral['path']) as image:
        if hashlib.sha256(image.info['icc_profile']).hexdigest() != icc:
            raise ValueError(f'Neutral and adjusted Lightroom profiles differ for {identity}')
    return case, target, icc, packet, metrics, control, int(amount)
