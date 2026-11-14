"""Pair a signed Light chart with its neutral source, embedded ICC and public render."""
import hashlib
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit

import numpy as np
from PIL import Image

from adaptive_data import FrozenSet
from error_metrics import nearest_rank


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def registered_chart(root, prefix, control, amount):
    """Return the verified linear-P3 pixels and their source, profile and reference identity."""
    catalog = FrozenSet(root)
    cases = {r['id']: r for r in json.loads((root / 'cases.json').read_text())['cases']}
    neutral = prefix + 'neutral'
    key = prefix + (f'{control}-{amount}' if amount else 'neutral')
    case, reference = cases[key], catalog.references[key]
    inspection = reference['inspection']
    expected = {control: amount} if amount else {}
    other = 'Shadows2012' if control == 'Highlights2012' else 'Highlights2012'
    if (case['parameters'] != expected or digest(case['input']) != case['inputSHA256']
            or case['inputSHA256'] != cases[neutral]['inputSHA256']
            or digest(case['settings']) != case['settingsSHA256'] or reference['settingsSHA256'] != case['settingsSHA256']
            or float(reference['resolvedSettings'][control]) != amount or float(reference['resolvedSettings'][other]) != 0
            or inspection['profile'] != 'ProPhoto RGB' or inspection['bits'] != 16
            or catalog.decoded[key]['space'] != 'extended-linear Display-P3 D65'):
        raise ValueError(f'Changed source, XMP or color space for {key}')
    with Image.open(root / reference['reference']) as image:
        profile = hashlib.sha256(image.info['icc_profile']).hexdigest()
    if 'icc' in inspection and not (digest(inspection['icc']) == inspection['iccSHA256'] == profile):
        raise ValueError(f'Changed output profile for {key}')
    pixels = catalog.read(key)
    if pixels.shape != (256, 1024, 4):
        raise ValueError(f'Expected the original chart dimensions for {key}')
    return pixels, dict(id=key, source=case['inputSHA256'], xmp=case['settingsSHA256'],
                        profile=profile, reference=catalog.evidence[key])


def public_chart(sample, record, decoded, metric, control, amount, target, evidence):
    """Authenticate the paired 16-bit output and reproduce its whole-chart p95 before sampling."""
    if (sample['control'] != control or sample['amount'] != amount
            or digest(unquote(urlsplit(sample['input']).path)) != evidence['source']
            or digest(unquote(urlsplit(sample['icc']).path)) != evidence['profile']
            or metric['source'] != evidence['source'] or metric['icc'] != evidence['profile']
            or metric['xmp'] != evidence['xmp'] or metric['reference'] != evidence['reference']
            or digest(record['input']) != record['sha256']
            or record['space'] != 'extended-linear Display-P3 D65'
            or (record['height'], record['width']) != target.shape[:2]):
        raise ValueError(f"Unpaired public render for {evidence['id']}")
    pixels = np.fromfile(decoded / record['output'], '<f4').reshape(target.shape)
    p95 = nearest_rank(abs(pixels[..., :3] - target[..., :3]).max(axis=2).ravel(), .95)
    if not np.isfinite(pixels).all() or not np.all(pixels[..., 3] == 1) or abs(p95 - metric['p95']) > 1e-8:
        raise ValueError(f"Unexpected public pixels for {evidence['id']}")
    return pixels


def color_lattice(pixels):
    """Take one sample of each 32³ input code from the first scanline of every four-row strip."""
    return pixels[128::4, :, :3].reshape(32768, 3).astype('f8')
