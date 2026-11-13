"""Read the Camera Raw controls consumed by the two post-development adapters."""
import math
from pathlib import Path
from typing import BinaryIO
import xml.etree.ElementTree as ET


RDF = '{http://www.w3.org/1999/02/22-rdf-syntax-ns#}'
CRS = '{http://ns.adobe.com/camera-raw-settings/1.0/}'
POINT_CURVES = {'ToneCurvePV2012', 'ToneCurvePV2012Red', 'ToneCurvePV2012Green', 'ToneCurvePV2012Blue'}


def read_adjustments(path: Path | BinaryIO):
  """Collect scalar attributes, scalar elements and explicit RGB curves on the image.

  Lightroom presets often write slider values as attributes, while exported
  TIFF metadata uses elements. A Look or mask can have its own nested settings.
  Missing curves stay absent so the host supplies its identity curve.
  """
  root = ET.parse(path).getroot()
  rdf = root if root.tag == RDF + 'RDF' else root.find(RDF + 'RDF')
  descriptions = [] if rdf is None else rdf.findall(RDF + 'Description')
  if not descriptions:
    raise ValueError(f'Missing root RDF description in {path}')
  subject = descriptions[0].get(RDF + 'about', '')
  settings, curves = {}, {}

  def store(mapping, key, value):
    if key in mapping and mapping[key] != value:
      raise ValueError(f'Conflicting {key} settings in {path}')
    mapping[key] = value

  for description in descriptions:
    if description.get(RDF + 'about', '') != subject:
      continue
    for tag, value in description.attrib.items():
      if tag.startswith(CRS):
        key = tag[len(CRS):]
        if key in POINT_CURVES:
          raise ValueError(f'Expected an RDF sequence for {key} in {path}')
        store(settings, key, value.strip())
    for child in description:
      if not child.tag.startswith(CRS):
        continue
      key = child.tag[len(CRS):]
      if key in POINT_CURVES:
        points = []
        for item in child.findall(f'{RDF}Seq/{RDF}li'):
          pair = [float(v) for v in (item.text or '').split(',')]
          if len(pair) != 2 or not all(map(math.isfinite, pair)):
            raise ValueError(f'Invalid {key} point in {path}')
          points.append(pair)
        if not points:
          raise ValueError(f'Empty {key} in {path}')
        store(curves, key, points)
      elif len(child) == 0 and child.text is not None:
        store(settings, key, child.text.strip())
  return settings, curves
