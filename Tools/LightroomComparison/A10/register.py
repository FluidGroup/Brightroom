"""Verify every root Camera Raw setting and freeze an acquired reference set.

ImageIO metadata packets and images.json must already have been extracted with
inspect.swift. Repeated measurements validate frozen hashes; they must not run
this registration step over changed evidence.
"""
import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cases', type=Path)
parser.add_argument('metadata_directory', type=Path)
args = parser.parse_args()
root = args.cases.resolve().parent
output = root / 'references.json'
if output.exists():
  raise FileExistsError('Reference registration already exists')
crs = '{http://ns.adobe.com/camera-raw-settings/1.0/}'
rdf = '{http://www.w3.org/1999/02/22-rdf-syntax-ns#}'


def digest(path):
  with path.open('rb') as stream:
    return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
  # Registration verifies external evidence even when Python is optimized.
  if not condition:
    raise ValueError(message)


def value(node):
  if len(node):
    return [(child.tag, value(child)) for child in node]
  text = node.text or ''
  try:
    return str(Decimal(text).normalize())
  except InvalidOperation:
    return text


def settings(data):
  description = ET.fromstring(data).find('.//' + rdf + 'Description')
  result = {}
  for key, text in description.attrib.items():
    if key.startswith(crs):
      child = ET.Element(key)
      child.text = text
      result[key[len(crs):]] = value(child)
  for child in description:
    if child.tag.startswith(crs):
      result[child.tag[len(crs):]] = value(child)
  return result


records = []
inspected = {str(Path(record['input']).resolve()): record
  for record in json.loads((args.metadata_directory/'images.json').read_text())}
for case in json.loads(args.cases.read_text())['cases']:
  identity = case['id']
  requested = Path(case['settings'])
  require(digest(requested) == case['settingsSHA256'], f'Changed settings: {identity}')
  reference = root / 'inputs/adobe-references' / (identity + '.tif')
  evidence = inspected[str(reference.resolve())]
  require(evidence['sha256'] == digest(reference), f'Stale metadata extraction: {identity}')
  require(evidence['bits'] == 16 and evidence['profile'] == 'ProPhoto RGB',
    f'Expected 16-bit ProPhoto RGB reference: {identity}')
  require(evidence['alphaInfo'] == 0, f'Reference must be opaque: {identity}')
  reinspect = 'Run inspect.swift into a NEW directory before registration'
  require(evidence.get('metadata') and evidence.get('metadataSHA256'),
    f'Metadata binding missing: {identity}. {reinspect}')
  metadata = Path(evidence['metadata'])
  require(metadata.is_file(), f'Bound metadata sidecar is missing: {identity}. {reinspect}')
  data = metadata.read_bytes()
  require(hashlib.sha256(data).hexdigest() == evidence['metadataSHA256'],
    f'Metadata sidecar changed: {identity}. {reinspect}')
  # Parse the same bytes that passed the binding check, without reopening them.
  actual = settings(data)
  expected = settings(requested.read_bytes())
  require(actual['AlreadyApplied'] == 'True', f'Settings have not been applied: {identity}')
  # Rendering state, file identity, and Adobe's minimum-reader-version marker
  # are not authored controls. Their resolved values remain in the manifest.
  ignored = {'AlreadyApplied', 'RawFileName', 'CompatibleVersion'}
  # Lightroom omits dependent fields when their controlling amount is neutral.
  # Accept absence only, and retain the exact omission in the evidence record.
  inactive = set()
  for amount, dependent in [
    ('Sharpness', ['SharpenRadius', 'SharpenDetail', 'SharpenEdgeMasking']),
    ('LuminanceSmoothing', ['LuminanceNoiseReductionDetail', 'LuminanceNoiseReductionContrast']),
    ('ColorNoiseReduction', ['ColorNoiseReductionDetail', 'ColorNoiseReductionSmoothness']),
    ('PostCropVignetteAmount', ['PostCropVignetteStyle', 'PostCropVignetteMidpoint',
      'PostCropVignetteFeather', 'PostCropVignetteRoundness', 'PostCropVignetteHighlightContrast']),
  ]:
    if expected[amount] == actual[amount] == '0':
      inactive.update(key for key in dependent if key not in actual)
  identity_curve = [(rdf + 'Seq', [(rdf + 'li', '0, 0'), (rdf + 'li', '255, 255')])]
  if expected['ToneCurvePV2012'] == actual['ToneCurvePV2012'] == identity_curve:
    if 'CurveRefineSaturation' not in actual:
      inactive.add('CurveRefineSaturation')
  mismatch = {key: [expected.get(key), actual.get(key)]
    for key in expected.keys() | actual.keys()
    if key not in ignored | inactive and expected.get(key) != actual.get(key)}
  require(not mismatch, f'Reference settings do not match {identity}: {mismatch}')
  records.append({'id': identity, 'kind': case['kind'], 'group': case['group'],
    'reference': str(reference.relative_to(root)), 'referenceSHA256': digest(reference),
    'settingsSHA256': digest(requested), 'resolvedSettings': actual,
    'inspection': evidence,
    'omittedInactiveSettings': sorted(inactive)})
with output.open('x') as stream:
  stream.write(json.dumps({'export': {'format': 'TIFF', 'bits': 16,
    'profile': 'ProPhoto RGB', 'resize': False, 'outputSharpening': False,
    'watermark': False, 'HDR': False}, 'references': records}, indent=2) + '\n')
print(f'Verified all requested and neutral settings in {len(records)} references')
