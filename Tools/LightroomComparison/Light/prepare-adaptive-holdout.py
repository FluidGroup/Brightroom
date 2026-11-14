"""Prepare new scene/strength validation after freezing the synthetic fit.

The reduced photograph is the existing photograph at a new resolution, not an
independent photographic scene. No reference from this set belongs in a fit.
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
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
(out / 'settings').mkdir()
ns = {'x': 'adobe:ns:meta/', 'rdf': 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
      'crs': 'http://ns.adobe.com/camera-raw-settings/1.0/'}
for key, value in ns.items():
    ET.register_namespace(key, value)
baseline = ET.parse(args.research / 'cases/neutral.xmp').getroot()
cases = []
for name in ['photo', 'color-scene']:
    source = (args.fixtures / (name + '.tiff')).resolve()
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    parameters = [(None, 0), ('Whites2012', 42), ('Whites2012', 75),
                  ('Highlights2012', -37), ('Highlights2012', 23),
                  ('Shadows2012', 17), ('Shadows2012', -32)]
    for key, amount in parameters:
        identity = 'holdout-' + name + '-' + (f'{key}-{amount}' if key else 'neutral')
        packet = copy.deepcopy(baseline)
        if key:
            packet.find('rdf:RDF/rdf:Description/crs:' + key, ns).text = str(amount)
        path = out / 'settings' / (identity + '.xmp')
        path.write_bytes(ET.tostring(packet, encoding='utf-8', xml_declaration=True))
        cases.append(dict(
            id=identity, kind='photo' if name == 'photo' else 'chart',
            group='light' if key else 'neutral', role='validation' if key else 'control',
            parameters={key: amount} if key else {}, input=str(source),
            inputSHA256=source_hash, settings=str(path),
            settingsSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
            prepared=str(out / 'inputs' / (identity + '.tiff'))))
(out / 'cases.json').write_text(json.dumps(dict(
    purpose='Prospective validation, unused strengths and a new color scene', cases=cases), indent=2) + '\n')
print(len(cases), 'cases')
