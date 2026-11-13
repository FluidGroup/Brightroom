"""Prepare A10 group ablations over identical chart and developed-photo pixels."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('research', type=Path)
parser.add_argument('preset', type=Path)
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
rdf = '{' + ns['rdf'] + '}'
source = ET.parse(args.preset).find('rdf:RDF/rdf:Description', ns)
assert source is not None
preset = {}
for key, value in source.attrib.items():
  if key.startswith(crs):
    element = ET.Element(key)
    element.text = value
    preset[key[len(crs):]] = element
for child in source:
  if child.tag.startswith(crs):
    preset[child.tag[len(crs):]] = copy.deepcopy(child)
baseline = ET.parse(root/'cases/neutral.xmp').getroot()
base = baseline.find('rdf:RDF/rdf:Description', ns)
# Keep algorithm/shape defaults fixed even when their controlling amount is zero.
for key in ['CurveRefineSaturation', 'SharpenRadius', 'SharpenDetail', 'SharpenEdgeMasking',
  'LuminanceNoiseReductionDetail', 'LuminanceNoiseReductionContrast', 'ColorNoiseReductionDetail',
  'ColorNoiseReductionSmoothness', 'GrainSize', 'GrainFrequency', 'PostCropVignetteMidpoint',
  'PostCropVignetteFeather', 'PostCropVignetteRoundness', 'PostCropVignetteStyle', 'PostCropVignetteHighlightContrast']:
  old = base.find(crs + key)
  if old is not None:
    base.remove(old)
  base.append(copy.deepcopy(preset[key]))

master = ['ToneCurvePV2012']
rgb = ['ToneCurvePV2012' + c for c in ['Red', 'Green', 'Blue']]
parametric = ['ParametricShadows', 'ParametricDarks', 'ParametricLights', 'ParametricHighlights']
hue = [k for k in preset if k.startswith('HueAdjustment')]
saturation = [k for k in preset if k.startswith('SaturationAdjustment')]
luminance = [k for k in preset if k.startswith('LuminanceAdjustment')]
light = ['Contrast2012', 'Highlights2012', 'Shadows2012', 'Whites2012', 'Blacks2012', 'Vibrance', 'Saturation']
presence = ['Texture', 'Clarity2012', 'Dehaze']
detail = ['Sharpness', 'LuminanceSmoothing', 'ColorNoiseReduction']
curves = master + rgb + parametric
mixer = hue + saturation + luminance
color = light + curves + mixer
full = color + presence + detail + ['GrainAmount', 'PostCropVignetteAmount']
groups = {'neutral': [], 'curve-master': master, 'curve-red': rgb[:1], 'curve-green': rgb[1:2],
  'curve-blue': rgb[2:], 'curve-rgb': rgb, 'curve-point': master+rgb, 'curve-parametric': parametric,
  'curves': curves, 'mixer-hue': hue, 'mixer-saturation': saturation, 'mixer-luminance': luminance,
  'mixer': mixer, 'light-highlights': ['Highlights2012'], 'light-shadows': ['Shadows2012'],
  'light-whites': ['Whites2012'], 'light-blacks': ['Blacks2012'], 'light-saturation': ['Saturation'],
  'light': light, 'presence-texture': ['Texture'], 'presence-clarity': ['Clarity2012'],
  'presence-dehaze': ['Dehaze'], 'presence': presence, 'detail': detail,
  'grain': ['GrainAmount'], 'vignette': ['PostCropVignetteAmount'],
  'color-stack': color, 'full': full}
for name, keys in [('minus-curves', curves), ('minus-mixer', mixer), ('minus-light', light),
  ('minus-presence', presence), ('minus-detail', detail), ('minus-grain', ['GrainAmount']),
  ('minus-vignette', ['PostCropVignetteAmount'])]:
  groups[name] = [k for k in full if k not in keys]
# Point-curve domain/interpolation controls independent of A10's points.
controls = {
  'curve-mid-up': [[0,0],[128,160],[255,255]],
  'curve-mid-down': [[0,0],[128,96],[255,255]],
  'curve-quarter-up': [[0,0],[64,100],[255,255]],
  'curve-endpoints': [[0,32],[255,224]],
}
cases = []
for kind, input_path in [('chart', root/'probe.tiff'), ('photo', root/'fixtures/L1007620-developed.tiff')]:
  for name, keys in groups.items():
    if kind == 'chart' and name.startswith('minus-'):
      continue
    # Large photos target aggregate effects and ablations; detailed channel
    # identification uses the chart to keep reference acquisition tractable.
    if kind == 'photo' and name not in ['neutral','curve-point','curve-parametric','curves','mixer','light','presence','detail','grain','vignette','color-stack','full'] and not name.startswith('minus-'):
      continue
    packet = copy.deepcopy(baseline)
    description = packet.find('rdf:RDF/rdf:Description', ns)
    for key in keys:
      old = description.find(crs + key)
      if old is not None:
        description.remove(old)
      description.append(copy.deepcopy(preset[key]))
    if any(k.startswith('ToneCurvePV2012') for k in keys):
      description.find(crs + 'ToneCurveName2012').text = 'Custom'
    cases.append((kind, name, input_path, packet, keys))
  if kind == 'chart':
    for name, points in controls.items():
      packet = copy.deepcopy(baseline)
      description = packet.find('rdf:RDF/rdf:Description', ns)
      description.find(crs + 'ToneCurveName2012').text = 'Custom'
      sequence = description.find('crs:ToneCurvePV2012/rdf:Seq', ns)
      sequence.clear()
      for x,y in points:
        ET.SubElement(sequence, rdf+'li').text = f'{x}, {y}'
      cases.append((kind, name, input_path, packet, ['ToneCurvePV2012']))
manifest = {'preset': str(args.preset.resolve()), 'presetSHA256': hashlib.sha256(args.preset.read_bytes()).hexdigest(),
  'purpose': 'A10 group isolation, composition and leave-one-group-out measurement', 'cases': []}
for kind, name, input_path, packet, keys in cases:
  identity = f'a10-{kind}-{name}'
  directory = out/'settings'
  directory.mkdir(exist_ok=True)
  settings = directory/(identity+'.xmp')
  settings.write_bytes(ET.tostring(packet, encoding='utf-8', xml_declaration=True))
  manifest['cases'].append({'id': identity, 'kind': kind, 'group': name, 'keys': keys,
    'input': str(input_path), 'inputSHA256': hashlib.sha256(input_path.read_bytes()).hexdigest(),
    'settings': str(settings), 'settingsSHA256': hashlib.sha256(settings.read_bytes()).hexdigest(),
    'prepared': str(out/'inputs'/(identity+'.tiff'))})
(out/'cases.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(len(cases), 'cases')
