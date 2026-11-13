"""Prepare spatial/histogram probes, without starting Lightroom or fitting photos."""
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
(out/'settings').mkdir()
ns = {'x':'adobe:ns:meta/', 'rdf':'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
  'crs':'http://ns.adobe.com/camera-raw-settings/1.0/'}
for key,value in ns.items(): ET.register_namespace(key,value)
baseline = ET.parse(args.research/'cases/neutral.xmp').getroot()
cases = []
for name in ['ramp','permuted','near-dark','near-light','dark','light']:
  source = (args.fixtures/(name+'.tiff')).resolve()
  source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
  for key,amount in [(None,0),('Highlights2012',-50),('Highlights2012',50),
    ('Shadows2012',-50),('Shadows2012',50),('Whites2012',25)]:
    identity = 'adaptive-'+name+'-'+(f'{key}-{amount}' if key else 'neutral')
    packet = copy.deepcopy(baseline)
    if key:
      element = packet.find('rdf:RDF/rdf:Description/crs:'+key,ns)
      assert element is not None
      element.text = str(amount)
    path = out/'settings'/(identity+'.xmp')
    path.write_bytes(ET.tostring(packet,encoding='utf-8',xml_declaration=True))
    cases.append(dict(id=identity,kind='chart',group='light' if key else 'neutral',
      role='validation' if key else 'control',parameters={key:amount} if key else {},
      input=str(source),inputSHA256=source_hash,settings=str(path),
      settingsSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
      prepared=str(out/'inputs'/(identity+'.tiff'))))
(out/'cases.json').write_text(json.dumps(dict(purpose='Spatial and global adaptation diagnosis',cases=cases),indent=2)+'\n')
print(len(cases),'cases')
