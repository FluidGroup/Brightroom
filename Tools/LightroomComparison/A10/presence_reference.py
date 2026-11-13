"""Verify matching source pixels, profiles and applied XMP for isolated Presence controls."""
from hashlib import sha256
from io import BytesIO
from pathlib import Path
import sys

from PIL import Image

from xmp_settings import read_adjustments

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Light'))
from tone_chart import digest

CONTROLS = {'Clarity2012', 'Texture', 'Dehaze'}


def registered(root, cases, references, identity):
    """Bind the TIFF, requested XMP and applied XMP to the registered input."""
    case, ref = cases[identity], references[identity]
    source = Path(case['input'])
    xmp = Path(case['settings'])
    target = root / ref['reference']
    if (digest(source) != case['inputSHA256'] or digest(xmp) != case['settingsSHA256']
            or case['settingsSHA256'] != ref['settingsSHA256'] or digest(target) != ref['referenceSHA256']):
        raise ValueError(f'Changed source, settings or registered TIFF for {identity}')
    requested, curves = read_adjustments(xmp)
    with Image.open(source) as original, Image.open(target) as tiff:
        if (original.size != tiff.size or tiff.format != 'TIFF' or tiff.mode != 'RGB'
                or tuple(tiff.tag_v2[258]) != (16, 16, 16)):
            raise ValueError(f'Expected a same-size 16-bit RGB reference for {identity}')
        size = tiff.size
        profile = sha256(tiff.info['icc_profile']).hexdigest()
        applied, applied_curves = read_adjustments(BytesIO(tiff.tag_v2[700]))
    stored = ref['resolvedSettings']
    if (applied.get('AlreadyApplied') != 'True' or stored.get('AlreadyApplied') != 'True'
            or requested['ProcessVersion'] != applied['ProcessVersion'] or applied['ProcessVersion'] != stored['ProcessVersion']
            or any(not float(requested[k]) == float(applied[k]) == float(stored[k]) for k in CONTROLS)):
        raise ValueError(f'TIFF does not carry the requested applied Presence settings for {identity}')
    if 'inspection' in ref:
        inspection = ref['inspection']
        if (inspection['iccSHA256'] != profile or inspection['bits'] != 16 or inspection['sha256'] != ref['referenceSHA256']
                or (inspection['width'], inspection['height']) != size):
            raise ValueError(f'Stale reference inspection for {identity}')
    declared = set(case['parameters'] if 'parameters' in case else case['keys'])
    if not declared <= CONTROLS or ('parameters' in case and
            any(float(case['parameters'][k]) != float(applied[k]) for k in declared)):
        raise ValueError(f'Expected only registered Presence controls for {identity}')
    # RawFileName identifies the individual export and naturally differs between the two TIFFs.
    applied.pop('RawFileName', None)
    proof = dict(id=identity, inputSHA256=case['inputSHA256'], xmpSHA256=case['settingsSHA256'],
                 referenceSHA256=ref['referenceSHA256'], iccSHA256=profile,
                 processVersion=applied['ProcessVersion'], size=size)
    return dict(path=target, proof=proof, group=case['group'], declared=declared, requested=requested,
                applied=applied, curves=curves, appliedCurves=applied_curves)


def changes(neutral, edited):
    """Require that the requested and applied packets differ only by the declared sliders."""
    identity = edited['proof']['id']
    for key in ('inputSHA256', 'iccSHA256', 'size', 'processVersion'):
        if neutral['proof'][key] != edited['proof'][key]:
            raise ValueError(f'Mismatched {key} for {identity}')
    if neutral['curves'] != edited['curves'] or neutral['appliedCurves'] != edited['appliedCurves']:
        raise ValueError(f'Point curve changed for {identity}')
    for side in ('requested', 'applied'):
        a, b = neutral[side], edited[side]
        outside = (a.keys() | b.keys()) - edited['declared']
        if any(a.get(k) != b.get(k) for k in outside):
            raise ValueError(f'Additional {side} adjustment for {identity}')
    strengths = {k: float(edited['applied'][k]) for k in sorted(edited['declared'])}
    if any(not 0 < abs(v) <= 100 for v in strengths.values()):
        raise ValueError(f'Expected nonzero signed slider strengths for {identity}')
    return strengths
