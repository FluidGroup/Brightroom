"""Freeze a supplied developed bitmap and its Lightroom preset result.

Unlike a controlled SDK acquisition, this retains unknown export options and
additional resolved settings. It checks the preset's authored controls and uses
the reference's actual ICC profile for the candidate export.
"""
import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('input', type=Path)
parser.add_argument('reference', type=Path)
parser.add_argument('preset', type=Path)
parser.add_argument('inspection', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
crs = '{http://ns.adobe.com/camera-raw-settings/1.0/}'
rdf = '{http://www.w3.org/1999/02/22-rdf-syntax-ns#}'


def digest(path):
  with path.open('rb') as stream:
    return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
  # Supplied evidence must be checked even when Python is optimized.
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
      node = ET.Element(key)
      node.text = text
      result[key[len(crs):]] = value(node)
  for child in description:
    if child.tag.startswith(crs):
      result[child.tag[len(crs):]] = value(child)
  return result


root = args.output.resolve()
require(not (root/'cases.json').exists() and not (root/'references.json').exists(), 'Already registered')
source, reference, preset = [path.resolve() for path in [args.input, args.reference, args.preset]]
inspected = {str(Path(record['input']).resolve()): record
  for record in json.loads((args.inspection/'images.json').read_text())}
metadata_packets = {}
for path in [source, reference]:
  record = inspected[str(path)]
  require(digest(path) == record['sha256'], f'Stale inspection: {path}')
  require(record['bits'] == 16 and record['alphaInfo'] == 0, f'Expected 16-bit opaque image: {path}')
  reinspect = 'Run inspect.swift into a NEW directory before registration'
  require(record.get('metadata') and record.get('metadataSHA256'),
    f'Metadata binding missing: {path}. {reinspect}')
  metadata_path = Path(record['metadata'])
  require(metadata_path.is_file(), f'Bound metadata sidecar is missing: {path}. {reinspect}')
  data = metadata_path.read_bytes()
  require(hashlib.sha256(data).hexdigest() == record['metadataSHA256'],
    f'Metadata sidecar changed: {path}. {reinspect}')
  metadata_packets[path] = data
source_record, reference_record = inspected[str(source)], inspected[str(reference)]
require((source_record['width'], source_record['height']) == (reference_record['width'], reference_record['height']), 'Geometry differs')
# Parse only the packet bytes verified against this image's inspection record.
preset_bytes = preset.read_bytes()
preset_digest = hashlib.sha256(preset_bytes).hexdigest()
actual, expected = settings(metadata_packets[reference]), settings(preset_bytes)
require(actual['AlreadyApplied'] == 'True', 'Reference must already contain the rendered edit')
# Preset identity, UI availability and writer version do not author pixels.
metadata_keys = {'PresetType', 'Cluster', 'UUID', 'SupportsAmount2', 'SupportsAmount',
  'SupportsColor', 'SupportsMonochrome', 'SupportsHighDynamicRange',
  'SupportsNormalDynamicRange', 'SupportsSceneReferred', 'SupportsOutputReferred',
  'RequiresRGBTables', 'ShowInPresets', 'ShowInQuickActions', 'CameraModelRestriction',
  'Copyright', 'ContactInfo', 'Version', 'Name', 'ShortName', 'SortName', 'Group', 'Description'}
controls = expected.keys() - metadata_keys
require(controls, 'Preset has no authored controls')
mismatch = {key: [expected[key], actual.get(key)] for key in controls if expected[key] != actual.get(key)}
require(not mismatch, f'Reference settings do not match: {mismatch}')
profile = Path(reference_record['icc'])
require(digest(profile) == reference_record['iccSHA256'], 'ICC evidence changed')
identity = 'supplied-photo-full'
case = dict(id=identity, kind='photo', group='full', role='validation',
  input=str(source), inputSHA256=source_record['sha256'],
  settings=str(preset), settingsSHA256=preset_digest)
record = dict(id=identity, kind='photo', group='full', reference=str(reference),
  referenceSHA256=reference_record['sha256'], settingsSHA256=case['settingsSHA256'],
  resolvedSettings=actual, inspection=reference_record,
  outputICC=dict(path=str(profile), sha256=reference_record['iccSHA256']))
root.mkdir(parents=True, exist_ok=True)
cases_json = json.dumps(dict(preset=str(preset), presetSHA256=preset_digest,
  purpose='User-supplied post-development preset validation; no model fitting',
  verifiedPresetControls=sorted(controls), ignoredPresetMetadata=sorted(expected.keys() & metadata_keys),
  inputInspection=source_record, cases=[case]), indent=2)+'\n'
references_json = json.dumps(dict(export=dict(
  format='TIFF', bits=16, profile=reference_record['profile'],
  outputSharpening='unknown', watermark='unknown',
  neutralLightroomExport='not supplied',
  provenance='User states this is the supplied developed bitmap with the preset applied; embedded settings verified'),
  references=[record]), indent=2)+'\n'
# Exclusive creation also preserves a registration created after the first check.
with (root/'cases.json').open('x') as cases_stream, (root/'references.json').open('x') as references_stream:
  cases_stream.write(cases_json)
  references_stream.write(references_json)
print(f'Frozen supplied pair; {len(controls)} preset controls verified')
