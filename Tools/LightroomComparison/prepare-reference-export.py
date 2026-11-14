"""Prepare a local Lightroom SDK plugin job from an existing case manifest.

Loading the plugin does not run it. Invoke its Library / Plug-in Extras menu
item in the exact research catalog. Registration remains a separate step that
verifies all resolved XMP settings, precision, profile, geometry and hashes.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cases', type=Path)
parser.add_argument('catalog', type=Path)
parser.add_argument('plugin', type=Path)
args = parser.parse_args()
cases = json.loads(args.cases.read_text())['cases']
root = args.cases.resolve().parent
destination = args.plugin.resolve()
assert destination.suffix == '.lrplugin'
assert not (root/'inputs/adobe-references').exists(), 'Do not overwrite references'
assert args.catalog.is_file()


def lua_string(value):
  """Quote UTF-8 paths as Lua long strings without interpreting their contents."""
  assert '\n' not in value and '\r' not in value
  equals = ''
  while ']' + equals + ']' in value:
    equals += '='
  return '[' + equals + '[' + value + ']' + equals + ']'


rows = []
for case in cases:
  source = Path(case['prepared']).resolve()
  assert source.parent == root/'inputs' and source.is_file()
  assert source.stem == case['id']
  assert hashlib.sha256(Path(case['settings']).read_bytes()).hexdigest() == case['settingsSHA256']
  # Only authored numeric probe parameters are checked in-process. The existing
  # register.py verifies the complete root XMP packet after export.
  assert all(isinstance(v, (int, float)) and math.isfinite(v) for v in case.get('parameters', {}).values())
  parameters = ', '.join(f'[ {lua_string(k)} ] = {v}' for k, v in case.get('parameters', {}).items())
  rows.append('  { id = %s, input = %s, sha256 = %s, parameters = { %s } },' % (
    lua_string(case['id']), lua_string(str(source)),
    lua_string(hashlib.sha256(source.read_bytes()).hexdigest()), parameters))
destination.mkdir(parents=True, exist_ok=True)
for name in ['Info.lua', 'Run.lua']:
  shutil.copyfile(Path(__file__).parent/'ReferenceExporter.lrplugin'/name, destination/name)
job = 'return {\n  catalog = %s,\n  inputs = %s,\n  output = %s,\n  cases = {\n%s\n  },\n}\n' % (
  lua_string(str(args.catalog.resolve())), lua_string(str(root/'inputs')),
  lua_string(str(root/'inputs/adobe-references')), '\n'.join(rows))
(destination/'Job.lua').write_text(job)
print(json.dumps({'plugin': str(destination), 'cases': len(cases), 'catalog': str(args.catalog.resolve()),
  'output': str(root/'inputs/adobe-references')}, indent=2))
