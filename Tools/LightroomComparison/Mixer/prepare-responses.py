"""Prepare independent Light and individual Mixer band/axis calibration cases.

The common RGB inputs and fixed neutral preset come from the prior acquisition.
A10 settings are not calibration samples: existing A10 exports remain validation.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('research', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
root = args.research.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
ns = {'x': 'adobe:ns:meta/', 'rdf': 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
  'crs': 'http://ns.adobe.com/camera-raw-settings/1.0/'}
for key, value in ns.items():
  ET.register_namespace(key, value)
crs = '{' + ns['crs'] + '}'
baseline = ET.parse(root/'cases/neutral.xmp').getroot()
cases = []
light = ['Highlights2012', 'Shadows2012', 'Whites2012', 'Blacks2012', 'Saturation']
bands = ['Red', 'Orange', 'Yellow', 'Green', 'Aqua', 'Blue', 'Purple', 'Magenta']
axes = ['Hue', 'Saturation', 'Luminance']

def add(kind, name, group, parameters, role):
  identity = f'adjust-{kind}-{name}'
  packet = copy.deepcopy(baseline)
  description = packet.find('rdf:RDF/rdf:Description', ns)
  for key, value in parameters.items():
    element = description.find(crs + key)
    assert element is not None, key
    element.text = str(value)
  source = root/('probe.tiff' if kind == 'chart' else 'fixtures/L1007620-developed.tiff')
  settings = out/'settings'/(identity+'.xmp')
  settings.parent.mkdir(exist_ok=True)
  settings.write_bytes(ET.tostring(packet, encoding='utf-8', xml_declaration=True))
  cases.append({'id': identity, 'kind': kind, 'group': group, 'role': role,
    'parameters': parameters, 'input': str(source),
    'inputSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'settings': str(settings), 'settingsSHA256': hashlib.sha256(settings.read_bytes()).hexdigest(),
    'prepared': str(out/'inputs'/(identity+'.tiff'))})

add('chart','neutral','neutral',{},'control')
for axis in axes:
  for value in [-100,-75,-50,-25,25,50,75,100]:
    add('chart',f'uniform-{axis}-{value}','uniform-mixer',{axis+'Adjustment'+band:value for band in bands},'calibration')
for key in light:
  for value in [-25,-10,10,25]:
    add('chart',f'{key}-{value}','light',{key:value},'calibration')
for name,params in [('hs',{'Highlights2012':-35,'Shadows2012':42}),('wb',{'Whites2012':-18,'Blacks2012':16}),('tone',{'Highlights2012':-35,'Shadows2012':42,'Whites2012':-18,'Blacks2012':16})]:
  add('chart',name,'light',params,'validation')
(out/'cases.json').write_text(json.dumps({'purpose':'Uniform Mixer response and Light parameter interpolation','cases':cases},indent=2)+'\n')
print(len(cases),'cases')
