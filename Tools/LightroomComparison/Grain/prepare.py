"""Prepare one-slider grain sweeps and held-out combinations for a Lightroom TIFF export.

Supply two charts with equal pixel area and different aspect ratios and a
separate photograph. Run A10/embed-inputs.swift on the resulting cases.json.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('neutral_xmp', type=Path)
parser.add_argument('chart', type=Path)
parser.add_argument('aspect_chart', type=Path)
parser.add_argument('photo', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
ns = dict(x='adobe:ns:meta/', rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#',
          crs='http://ns.adobe.com/camera-raw-settings/1.0/')
for prefix, namespace in ns.items():
    ET.register_namespace(prefix, namespace)
neutral = ET.parse(args.neutral_xmp).getroot()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
(output / 'settings').mkdir()
center = (20, 42, 70)
sidecar = (25, 73, 65)
off = (0, 42, 70)
sweep = [off, center, (5, 42, 70), (50, 42, 70), (100, 42, 70),
         (20, 0, 70), (20, 25, 70), (20, 73, 70), (20, 100, 70),
         (20, 42, 0), (20, 42, 35), (20, 42, 100), sidecar]
cases = []
for name, path, values in [('chart', args.chart, sweep), ('aspect', args.aspect_chart, [off, center]),
                           ('photo', args.photo, [off, center, sidecar])]:
    source = path.resolve()
    source_hash = digest(source)
    for amount, size, roughness in values:
        key = f'grain-axis-{name}-{amount}-{size}-{roughness}'
        controls = dict(GrainAmount=amount, GrainSize=size, GrainFrequency=roughness, GrainSeed=1729)
        packet = copy.deepcopy(neutral)
        description = packet.find('rdf:RDF/rdf:Description', ns)
        for prop, value in controls.items():
            tag = '{' + ns['crs'] + '}' + prop
            if tag in description.attrib:
                description.set(tag, str(value))
            else:
                element = description.find(tag)
                if element is None:
                    element = ET.SubElement(description, tag)
                element.text = str(value)
        settings = output / 'settings' / (key + '.xmp')
        settings.write_bytes(ET.tostring(packet, encoding='utf-8', xml_declaration=True))
        held_out = name != 'chart' or (amount, size, roughness) == sidecar
        cases.append(dict(id=key, kind='photo' if name == 'photo' else 'chart', sourceID=name,
            group='grain' if amount else 'neutral', role=('validation' if held_out else 'calibration') if amount else 'control',
            input=str(source), inputSHA256=source_hash, settings=str(settings), settingsSHA256=digest(settings),
            parameters=controls, prepared=str(output / 'inputs' / (key + '.tiff'))))
(output / 'cases.json').write_text(json.dumps(dict(purpose=__doc__.splitlines()[0], cases=cases), indent=2) + '\n')
print(len(cases), 'cases')
