"""Prepare gray scenes and parameter-axis probes; photographs remain holdouts."""
import argparse, copy, hashlib, json
from pathlib import Path
import xml.etree.ElementTree as ET
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('research',type=Path)
parser.add_argument('fixtures',type=Path)
parser.add_argument('ramp',type=Path)
parser.add_argument('output',type=Path)
args=parser.parse_args()
out=args.output.resolve();out.mkdir(parents=True,exist_ok=False);(out/'settings').mkdir()
ns={'x':'adobe:ns:meta/','rdf':'http://www.w3.org/1999/02/22-rdf-syntax-ns#','crs':'http://ns.adobe.com/camera-raw-settings/1.0/'}
for key,value in ns.items():ET.register_namespace(key,value)
baseline=ET.parse(args.research/'cases/neutral.xmp').getroot()
cases=[]
scenes=[(p.stem,p.resolve()) for p in sorted(args.fixtures.glob('*.tiff'))]+[('ramp',args.ramp.resolve())]
for name,source in scenes:
  settings=[(None,0)]
  for key in ['Highlights2012','Shadows2012']:
    settings += [(key,a) for a in ([-100,-25,-10,10,25,100] if name=='ramp' else [-50,50])]
  settings += [('Whites2012',a) for a in ([10,50,100] if name=='ramp' else [25,50])]
  for key,amount in settings:
    identity='adaptcal-'+name+'-'+(f'{key}-{amount}' if key else 'neutral')
    packet=copy.deepcopy(baseline)
    if key:packet.find('rdf:RDF/rdf:Description/crs:'+key,ns).text=str(amount)
    path=out/'settings'/(identity+'.xmp');path.write_bytes(ET.tostring(packet,encoding='utf-8',xml_declaration=True))
    cases.append(dict(id=identity,kind='chart',group='light' if key else 'neutral',role='calibration' if key else 'control',
      parameters={key:amount} if key else {},input=str(source),inputSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
      settings=str(path),settingsSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),prepared=str(out/'inputs'/(identity+'.tiff'))))
(out/'cases.json').write_text(json.dumps(dict(purpose='Synthetic adaptive tone calibration',cases=cases),indent=2)+'\n')
print(len(cases),'cases')
