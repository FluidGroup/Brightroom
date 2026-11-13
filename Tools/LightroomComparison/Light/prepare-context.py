"""Prepare identical-ramp/different-surround validation for Whites and Blacks.

Generate FIXTURES with context-inputs.swift first. RESEARCH supplies the frozen
neutral XMP and developed photo. This prepares files only; SDK export is separate.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('research', type=Path)
parser.add_argument('fixtures', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
root, fixtures, out = args.research.resolve(), args.fixtures.resolve(), args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
(out/'settings').mkdir()
ns = {'x': 'adobe:ns:meta/', 'rdf': 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
  'crs': 'http://ns.adobe.com/camera-raw-settings/1.0/'}
for key, value in ns.items():
  ET.register_namespace(key, value)
baseline = ET.parse(root/'cases/neutral.xmp').getroot()
cases = []
for name in ['ramp', 'dark', 'light', 'midgray', 'photo']:
  source = root/'fixtures/L1007620-developed.tiff' if name == 'photo' else fixtures/(name+'.tiff')
  source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
  settings = [(key, amount) for key in ['Whites2012', 'Blacks2012'] for amount in [-25, 25]]
  if name != 'photo':
    settings.insert(0, (None, 0))
  for key, amount in settings:
    identity = f'context-{name}-' + (f'{key}-{amount}' if key else 'neutral')
    packet = copy.deepcopy(baseline)
    if key:
      element = packet.find('rdf:RDF/rdf:Description/crs:'+key, ns)
      assert element is not None, key
      element.text = str(amount)
    path = out/'settings'/(identity+'.xmp')
    path.write_bytes(ET.tostring(packet, encoding='utf-8', xml_declaration=True))
    cases.append(dict(id=identity, kind='photo' if name == 'photo' else 'chart',
      group='light' if key else 'neutral', role='validation' if key else 'control',
      parameters={key: amount} if key else {}, input=str(source), inputSHA256=source_hash,
      settings=str(path), settingsSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
      prepared=str(out/'inputs'/(identity+'.tiff'))))
(out/'cases.json').write_text(json.dumps(dict(
  purpose='Tonal context validation; never calibration training', cases=cases), indent=2)+'\n')
print(len(cases), 'cases')
