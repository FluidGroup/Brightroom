"""Exercise evidence refusals through the real Python entry points.

Run with the analysis environment's Python and a new output directory. Fixtures
contain synthetic bytes and metadata: this checks validation, not image decoding.
A sentinel replaces xcodebuild, so no GPU, compiler or Lightroom work can start.
Optional tool directories allow the same checks against a retained old snapshot.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--a10-dir', type=Path, default=Path(__file__).parent)
parser.add_argument('--light-dir', type=Path, default=Path(__file__).parent.parent/'Light')
parser.add_argument('--kind', action='append', choices=['run', 'register', 'pair', 'point', 'run-point', 'decoded'],
  help='limit a retained-source regression check to these entry points; repeat as needed')
parser.add_argument('--keep-fixtures', action='store_true',
  help='keep temporary synthetic inputs for all checks, including successful checks')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)


def digest(path):
  return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
  path.write_text(json.dumps(value, indent=2)+'\n')


def fixture(root):
  """A valid registration/preflight fixture with one opaque decoded pixel."""
  root.mkdir()
  (root/'inputs/adobe-references').mkdir(parents=True)
  (root/'metadata').mkdir()
  (root/'decoded').mkdir()
  source = root/'source.bin'
  source.write_bytes(b'original pixels')
  requested = root/'settings.xmp'
  xml = '''<x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"><rdf:RDF><rdf:Description>
    <crs:AlreadyApplied>True</crs:AlreadyApplied><crs:Whites2012>42</crs:Whites2012>
    <crs:Sharpness>0</crs:Sharpness><crs:LuminanceSmoothing>0</crs:LuminanceSmoothing>
    <crs:ColorNoiseReduction>0</crs:ColorNoiseReduction><crs:PostCropVignetteAmount>0</crs:PostCropVignetteAmount>
    <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
    </rdf:Description></rdf:RDF></x:xmpmeta>'''
  requested.write_text(xml)
  case = dict(id='test', kind='photo', group='light-whites', role='validation',
    input=str(source), inputSHA256=digest(source), settings=str(requested), settingsSHA256=digest(requested))
  reference = root/'inputs/adobe-references/test.tif'
  reference.write_bytes(b'frozen reference bytes')
  ref = dict(id='test', reference=str(reference.relative_to(root)), referenceSHA256=digest(reference),
    settingsSHA256=digest(requested))
  metadata = root/'metadata/test.tif.metadata.xmp'
  metadata.write_text(xml)
  profile = root/'metadata/test.tif.icc'
  profile.write_bytes(b'synthetic ICC evidence, not a decodable profile')
  inspection = dict(input=str(reference), sha256=digest(reference), bits=16,
    profile='ProPhoto RGB', alphaInfo=0, width=1, height=1,
    metadata=str(metadata), metadataSHA256=digest(metadata),
    icc=str(profile), iccSHA256=digest(profile))
  write_json(root/'cases.json', dict(cases=[case]))
  write_json(root/'references.json', dict(references=[ref]))
  write_json(root/'metadata/images.json', [inspection])
  write_json(root/'decoded/manifest.json', [dict(input=str(reference), sha256=digest(reference), width=1, height=1)])
  (root/'decoded/test.rgba32f').write_bytes(np.array([.2, .3, .4, 1], dtype='<f4').tobytes())
  return case, ref, inspection


point_pixels = out/'point-pixels.rgba32f'
point_pixels.write_bytes(np.tile(np.array([.2, .3, .4, 1], dtype='<f4'), (256, 1024, 1)).tobytes())


def point_fixture(root):
  """Use real chart dimensions; hard links keep repeated fixtures small."""
  roots = [root/'coarse', root/'fine']
  for index, directory in enumerate(roots):
    (directory/'decoded').mkdir(parents=True)
    references, decoded = [], []
    names = ['neutral'] + [f'{key}-{amount}'
      for key in ['Whites2012', 'Blacks2012', 'Saturation']
      for amount in ([-100, -50, 50, 100] if index == 0 else [-25, -10, 10, 25])]
    for name in names:
      identity = 'adjust-chart-'+name
      reference = directory/(identity+'.tif')
      reference.write_bytes(b'synthetic point reference, not image bytes')
      references.append(dict(id=identity, reference=reference.name, referenceSHA256=digest(reference)))
      decoded.append(dict(input=str(reference), sha256=digest(reference), width=1024, height=256))
      (directory/'decoded'/(identity+'.rgba32f')).hardlink_to(point_pixels)
    write_json(directory/'references.json', dict(references=references))
    write_json(directory/'decoded/manifest.json', decoded)
  return roots


sentinel = out/'bin'
sentinel.mkdir()
build = sentinel/'xcodebuild'
build.write_text(f'#!{sys.executable}\nimport os\nfrom pathlib import Path\n'
  'Path(os.environ["BRIGHTROOM_BUILD_SENTINEL"]).write_text("reached")\nraise SystemExit(77)\n')
build.chmod(0o755)
checks = []
for mode in ['normal', 'optimized-flag', 'optimized-environment']:
  prefix = [sys.executable] + (['-O'] if mode == 'optimized-flag' else [])
  env = dict(os.environ, PATH=str(sentinel)+os.pathsep+os.environ.get('PATH', ''),
    PYTHONPATH=str(args.light_dir.resolve()), PYTHONDONTWRITEBYTECODE='1')
  env.pop('PYTHONOPTIMIZE', None)
  if mode == 'optimized-environment':
    env['PYTHONOPTIMIZE'] = '1'
  for kind, mutation, expected in [
    ('run', 'valid', 'Command failed with 77'),
    ('run', 'empty', 'No cases selected'),
    ('run', 'missing-neutral', 'Expected one same-input neutral'),
    ('run', 'duplicate-set', 'Duplicate registered case'),
    ('run', 'orphan-reference', "Missing reference in the case's own registration"),
    ('run', 'inspection-reference', 'ICC inspection belongs to a different image'),
    ('run', 'settings-binding', 'Reference settings do not match'),
    ('run', 'input-hash', 'Frozen evidence changed'),
    ('run', 'reference-hash', 'Frozen evidence changed'),
    ('register', 'valid', 'Verified all requested'),
    ('register', 'existing', 'Reference registration already exists'),
    ('register', 'settings-hash', 'Changed settings'),
    ('register', 'metadata-hash', 'Stale metadata extraction'),
    ('register', 'profile', 'Expected 16-bit ProPhoto RGB'),
    ('register', 'alpha', 'Reference must be opaque'),
    ('register', 'settings-values', 'Reference settings do not match'),
    ('register', 'metadata-recorded-path', 'Verified all requested'),
    ('register', 'metadata-missing-binding', 'Metadata binding missing'),
    ('register', 'metadata-missing-path', 'Metadata binding missing'),
    ('register', 'metadata-missing-hash', 'Metadata binding missing'),
    ('register', 'metadata-sidecar-missing', 'Bound metadata sidecar is missing'),
    ('register', 'metadata-sidecar-stale', 'Metadata sidecar changed'),
    ('register', 'metadata-sidecar-swapped', 'Metadata sidecar changed'),
    ('pair', 'valid', 'Frozen supplied pair'),
    ('pair', 'existing-cases', 'Already registered'),
    ('pair', 'existing-references', 'Already registered'),
    ('pair', 'input-hash', 'Stale inspection'),
    ('pair', 'metadata-hash', 'Stale inspection'),
    ('pair', 'bits', 'Expected 16-bit opaque image'),
    ('pair', 'alpha', 'Expected 16-bit opaque image'),
    ('pair', 'source-bits', 'Expected 16-bit opaque image'),
    ('pair', 'source-alpha', 'Expected 16-bit opaque image'),
    ('pair', 'geometry', 'Geometry differs'),
    ('pair', 'applied', 'Reference must already contain the rendered edit'),
    ('pair', 'controls', 'Preset has no authored controls'),
    ('pair', 'settings-values', 'Reference settings do not match'),
    ('pair', 'icc', 'ICC evidence changed'),
    ('pair', 'metadata-recorded-path', 'Frozen supplied pair'),
    ('pair', 'metadata-missing-binding', 'Metadata binding missing'),
    ('pair', 'metadata-missing-path', 'Metadata binding missing'),
    ('pair', 'metadata-missing-hash', 'Metadata binding missing'),
    ('pair', 'metadata-sidecar-missing', 'Bound metadata sidecar is missing'),
    ('pair', 'metadata-sidecar-stale', 'Metadata sidecar changed'),
    ('pair', 'metadata-sidecar-swapped', 'Metadata sidecar changed'),
    ('pair', 'source-metadata-missing', 'Metadata binding missing'),
    ('pair', 'source-metadata-stale', 'Metadata sidecar changed'),
    ('point', 'valid', 'verified point table'),
    ('point', 'empty-keys', 'Unsupported calibration keys'),
    ('point', 'unknown-key', 'Unsupported calibration keys'),
    ('point', 'original-hash', 'Changed or stale point reference'),
    ('point', 'decoded-hash', 'Changed or stale point reference'),
    ('point', 'alpha', 'Nonfinite or nonopaque point samples'),
    ('point', 'nonfinite', 'Nonfinite or nonopaque point samples'),
    ('point', 'amount-low', 'Point amount must be finite and within'),
    ('point', 'amount-high', 'Point amount must be finite and within'),
    ('point', 'amount-nan', 'Point amount must be finite and within'),
    ('point', 'amount-inf', 'Point amount must be finite and within'),
    ('run-point', 'valid', 'Command failed with 77'),
    ('run-point', 'original-hash', 'Changed or stale point reference'),
    ('run-point', 'nonfinite', 'Nonfinite or nonopaque point samples'),
    ('decoded', 'valid', 'verified decoded pixel'),
    ('decoded', 'reference-hash', 'Changed or stale reference'),
    ('decoded', 'alpha', 'Nonfinite or nonopaque'),
    ('decoded', 'nonfinite', 'Nonfinite or nonopaque'),
  ]:
    if args.kind and kind not in args.kind:
      continue
    root = out/f'{mode}-{kind}-{mutation}'
    case, ref, inspection = fixture(root)
    source_record = dict(inspection, input=case['input'], sha256=case['inputSHA256'])
    source_metadata = root/'metadata/source.bin.metadata.xmp'
    source_metadata.write_bytes(Path(inspection['metadata']).read_bytes())
    source_record.update(metadata=str(source_metadata), metadataSHA256=digest(source_metadata))
    registration = root/'pair-output' if kind == 'pair' else root
    if kind in ['point', 'run-point']:
      coarse, fine = point_fixture(root)
      point_references = json.loads((coarse/'references.json').read_text())
      point_decoded = json.loads((coarse/'decoded/manifest.json').read_text())
      if mutation == 'original-hash':
        (coarse/point_references['references'][0]['reference']).write_bytes(b'changed original reference')
      elif mutation == 'decoded-hash':
        point_decoded[0]['sha256'] = '0'*64
        write_json(coarse/'decoded/manifest.json', point_decoded)
      elif mutation in ['alpha', 'nonfinite']:
        pixels = np.frombuffer(point_pixels.read_bytes(), '<f4').copy()
        pixels[3 if mutation == 'alpha' else 0] = 0 if mutation == 'alpha' else np.nan
        path = coarse/'decoded/adjust-chart-neutral.rgba32f'
        path.unlink()
        path.write_bytes(pixels.tobytes())
    if mutation == 'input-hash':
      case['inputSHA256'] = '0'*64
      source_record['sha256'] = '0'*64
    elif mutation == 'settings-binding':
      ref['settingsSHA256'] = '0'*64
    elif mutation == 'inspection-reference':
      ref['inspection'] = {**inspection, 'sha256': '0'*64}
    elif mutation == 'settings-hash':
      case['settingsSHA256'] = '0'*64
    elif mutation == 'reference-hash':
      ref['referenceSHA256'] = '0'*64
    elif mutation == 'metadata-hash':
      inspection['sha256'] = '0'*64
    elif mutation == 'profile':
      inspection['profile'] = 'Display P3'
    elif mutation == 'bits':
      inspection['bits'] = 8
    elif mutation == 'source-bits':
      source_record['bits'] = 8
    elif mutation == 'source-alpha':
      source_record['alphaInfo'] = 1
    elif mutation == 'geometry':
      source_record['width'] = 2
    elif mutation == 'icc':
      Path(inspection['icc']).write_bytes(b'changed ICC evidence')
    elif mutation == 'alpha':
      inspection['alphaInfo'] = 1
      (root/'decoded/test.rgba32f').write_bytes(np.array([.2, .3, .4, 0], dtype='<f4').tobytes())
    elif mutation == 'nonfinite':
      (root/'decoded/test.rgba32f').write_bytes(np.array([np.nan, .3, .4, 1], dtype='<f4').tobytes())
    elif mutation == 'settings-values':
      path = root/'metadata/test.tif.metadata.xmp'
      path.write_text(path.read_text().replace('>42<', '>75<'))
      inspection['metadataSHA256'] = digest(path)
    elif mutation == 'applied':
      path = Path(inspection['metadata'])
      path.write_text(path.read_text().replace('>True<', '>False<'))
      inspection['metadataSHA256'] = digest(path)
    elif mutation == 'controls':
      requested = Path(case['settings'])
      requested.write_text('<root xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description/></root>')
    elif mutation == 'metadata-recorded-path':
      path = Path(inspection['metadata'])
      recorded = path.with_name('recorded-sidecar.xmp')
      path.rename(recorded)
      inspection['metadata'] = str(recorded)
    elif mutation in ['metadata-missing-binding', 'metadata-missing-path']:
      inspection.pop('metadata')
      if mutation == 'metadata-missing-binding':
        inspection.pop('metadataSHA256')
    elif mutation == 'metadata-missing-hash':
      inspection.pop('metadataSHA256')
    elif mutation == 'metadata-sidecar-missing':
      Path(inspection['metadata']).unlink()
    elif mutation == 'metadata-sidecar-stale':
      path = Path(inspection['metadata'])
      path.write_bytes(path.read_bytes()+b'\n')
    elif mutation == 'metadata-sidecar-swapped':
      path = root/'metadata/other-image.metadata.xmp'
      path.write_bytes(Path(inspection['metadata']).read_bytes()+b'\n<!-- another image packet -->')
      inspection['metadata'] = str(path)
    elif mutation == 'source-metadata-missing':
      source_record.pop('metadataSHA256')
    elif mutation == 'source-metadata-stale':
      source_metadata.write_bytes(source_metadata.read_bytes()+b'\n')
    write_json(root/'cases.json', dict(cases=[] if mutation == 'empty' else [case]))
    write_json(root/'references.json', dict(references=[ref]))
    write_json(root/'metadata/images.json', [source_record, inspection])
    marker = root/'build-started'
    command_env = dict(env, BRIGHTROOM_BUILD_SENTINEL=str(marker))
    if kind in ['run', 'run-point']:
      command = prefix + [str(args.a10_dir.resolve()/'run.py'), str(root), str(root/'result'),
        '--developer-dir', '/unused', '--scope', 'light', '--modes', 'adaptive']
      if mutation == 'missing-neutral':
        command.append('--paired-neutral')
      elif mutation == 'duplicate-set':
        command.extend(['--additional-references', str(root)])
      elif mutation == 'orphan-reference':
        second = root/'second-registration'
        second.mkdir()
        write_json(root/'references.json', dict(references=[]))
        write_json(second/'cases.json', dict(cases=[]))
        write_json(second/'references.json', dict(references=[ref]))
        command.extend(['--additional-references', str(second)])
      if kind == 'run-point':
        command.extend(['--light-calibration', str(coarse), str(fine)])
    elif kind == 'register':
      if mutation != 'existing':
        (root/'references.json').unlink()
      command = prefix + [str(args.a10_dir.resolve()/'register.py'), str(root/'cases.json'), str(root/'metadata')]
    elif kind == 'pair':
      if mutation in ['existing-cases', 'existing-references']:
        registration.mkdir()
        (registration/('cases.json' if mutation == 'existing-cases' else 'references.json')).write_bytes(b'existing registration must survive')
      command = prefix + [str(args.a10_dir.resolve()/'register-pair.py'),
        case['input'], str(root/ref['reference']), case['settings'], str(root/'metadata'), str(registration)]
    elif kind == 'point':
      keys = '[]' if mutation == 'empty-keys' else "['unsupported']" if mutation == 'unknown-key' else "['Whites2012']"
      amount = {'amount-low': '-101', 'amount-high': '101', 'amount-nan': 'nan', 'amount-inf': 'inf'}.get(mutation, '42')
      command = prefix + ['-c', 'from point_model import PointModel; import hashlib, sys; '
        f'model = PointModel(sys.argv[1], sys.argv[2], keys={keys}); '
        'table = model.compile({"Whites2012": sys.argv[3]}); '
        'print("verified point table", len(table), hashlib.sha256(table).hexdigest())', str(coarse), str(fine), amount]
    else:
      command = prefix + ['-c', 'from adaptive_data import FrozenSet; import sys; '
        'FrozenSet(sys.argv[1]).read("test"); print("verified decoded pixel")', str(root)]
    before = {name: digest(registration/name) for name in ['cases.json', 'references.json'] if (registration/name).exists()}
    result = subprocess.run(command, env=command_env, capture_output=True, text=True)
    log = result.stdout+result.stderr
    (root/'process.log').write_text(log)
    success_expected = kind not in ['run', 'run-point'] and mutation in ['valid', 'metadata-recorded-path']
    passed = expected in log and ((result.returncode == 0) == success_expected)
    passed = passed and marker.exists() == (kind in ['run', 'run-point'] and mutation == 'valid')
    if kind in ['run', 'run-point'] and mutation != 'valid':
      failure = json.loads((root/'result/failure.json').read_text())
      passed = passed and failure['work'] == dict(renderedImages=0, comparedImages=0, comparedPixels=0, failures=1)
    if kind in ['register', 'pair'] and not success_expected:
      after = {name: digest(registration/name) for name in ['cases.json', 'references.json'] if (registration/name).exists()}
      passed = passed and before == after
    if kind in ['register', 'pair'] and success_expected and result.returncode == 0:
      registered = json.loads((registration/'references.json').read_text())['references'][0]
      passed = passed and registered['inspection'] == inspection
      if kind == 'pair':
        supplied = json.loads((registration/'cases.json').read_text())
        passed = passed and supplied['inputInspection'] == source_record
        # The Lightroom output authenticates the request. The candidate itself
        # must read the authored preset, including when its controls are attributes.
        passed = passed and supplied['cases'][0]['settings'] == case['settings']
        passed = passed and supplied['cases'][0]['settingsSHA256'] == digest(Path(case['settings']))
    if kind == 'point' and mutation == 'valid':
      neutral = np.tile(np.array([0, 0, 0, 1], dtype='<f4'), (32768, 1)).tobytes()
      passed = passed and f'{len(neutral)} {hashlib.sha256(neutral).hexdigest()}' in log
    checks.append(dict(mode=mode, kind=kind, mutation=mutation, passed=passed,
      exitCode=result.returncode, buildStarted=marker.exists(), command=command,
      log=str(root/'process.log')))
    if passed and not args.keep_fixtures:
      for path in root.iterdir():
        if path.name == 'process.log':
          continue
        if path.is_dir() and not path.is_symlink():
          shutil.rmtree(path)
        else:
          path.unlink()

report = dict(purpose='Evidence guards only; synthetic bytes, no image-decoding claim',
  checks=checks, failures=sum(not c['passed'] for c in checks),
  tools={str(path): digest(path) for path in [args.a10_dir/'run.py', args.a10_dir/'register.py',
    args.a10_dir/'register-pair.py', args.a10_dir/'inspect.swift',
    args.light_dir/'adaptive_data.py', args.light_dir/'point_model.py', Path(__file__)]})
write_json(out/'report.json', report)
if not args.keep_fixtures and report['failures'] == 0:
  point_pixels.unlink()
print(json.dumps(dict(checks=len(checks), failures=report['failures'])))
raise SystemExit(bool(report['failures']))
