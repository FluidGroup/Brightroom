"""Rebuild Brightroom and compare its candidate with frozen post-development XMP cases.

The loop keeps absolute RGB error and the previous adapter's error separately.
It never converts those measurements into a Lightroom compatibility pass.
"""
import argparse
import atexit
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from reference_pack import case_id, file_hash as digest, profile_of, registration
from xmp_settings import read_adjustments

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('references', type=Path, help='registered directory or portable Lightroom reference ZIP')
parser.add_argument('output', type=Path)
parser.add_argument('--developer-dir', help='override the active Xcode (DEVELOPER_DIR or xcode-select)')
parser.add_argument('--additional-references', type=Path, action='append', default=[],
  help='also read a registered set, for example another strength acquired for the same photographs')
parser.add_argument('--scope', choices=['point', 'partial', 'groups', 'ablation', 'adjustments', 'mixer', 'light', 'grain', 'presence'], default='point',
  help='choose the registered control, group, or full-preset cases to render')
parser.add_argument('--calibrated-mixer', action='store_true',
  help='measure the explicit Lightroom approximation while retaining the previous adapter')
parser.add_argument('--modes', nargs='+', choices=['point', 'legacy', 'partial', 'legacy-partial', 'calibrated', 'calibrated-light', 'tonal', 'adaptive', 'adaptive-no-grain'],
  help='explicit render modes, for a focused rerun against already retained baselines')
parser.add_argument('--light-calibration', nargs=2, type=Path, metavar=('COARSE', 'FINE'),
  help='frozen chart sets for the experimental Whites/Blacks/Saturation adapter')
parser.add_argument('--case-id', action='append',
  help='restrict the chosen scope to this case; repeat to select multiple cases')
parser.add_argument('--include-calibration', action='store_true',
  help='in the light scope, also measure the cases registered for calibration')
parser.add_argument('--paired-neutral', action='store_true',
  help='also measure adjustment-response error against the same input with neutral settings')
parser.add_argument('--metrics-only', action='store_true',
  help='discard generated PNGs after comparison and keep settings, source snapshots, hashes and metrics')
parser.add_argument('--response-axes', action='store_true',
  help='report luminance, chroma and hue-direction components of the paired response error')
parser.add_argument('--middle-channel-error', action='store_true',
  help='measure the middle-channel color error using the original 16-bit developed input')
args = parser.parse_args()
if args.response_axes and not args.paired_neutral:
  parser.error('--response-axes requires --paired-neutral')
if args.include_calibration and args.scope != 'light':
  parser.error('--include-calibration applies to --scope light')
repo = Path(__file__).resolve().parents[3]
root = args.references.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
env = os.environ.copy()
if args.developer_dir:
  env['DEVELOPER_DIR'] = args.developer_dir
products = repo / '.tmp/xmp-derived-data/Build/Products/Debug'
work = dict(renderedImages=0, comparedImages=0, comparedPixels=0, failures=0)


def report_failure(kind, error, traceback):
  # Integrity refusals must not look like a successful run with zero work.
  failure = out/'failure.json'
  if not failure.exists():
    work['failures'] += 1
    failure.write_text(json.dumps(dict(status='failed; no comparison verdict',
      error=str(error), work=work), indent=2)+'\n')
  print(json.dumps(work), file=sys.stderr)
  sys.__excepthook__(kind, error, traceback)


sys.excepthook = report_failure
light_model = None
if args.light_calibration:
  spec = importlib.util.spec_from_file_location('point_model', Path(__file__).parent.parent/'Light/point_model.py')
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  light_model = module.PointModel(*args.light_calibration)


def require(condition, message):
  # Evidence checks must also run under python -O and PYTHONOPTIMIZE.
  if not condition:
    raise ValueError(message)


def run(command, log):
  with log.open('w') as stream:
    result = subprocess.run(list(map(str, command)), cwd=repo, env=env,
      stdout=stream, stderr=subprocess.STDOUT)
  if result.returncode:
    work['failures'] += 1
    failure = dict(status='failed; no comparison verdict', command=list(map(str, command)),
      exitCode=result.returncode, log=str(log), work=work)
    (out/'failure.json').write_text(json.dumps(failure, indent=2)+'\n')
    raise RuntimeError(f'Command failed with {result.returncode}: {log}')


def modes_for(case):
  if args.modes:
    return args.modes
  modes = ['point', 'legacy'] if case['group'] != 'neutral' else ['point']
  if args.scope in ['partial', 'ablation']:
    modes = ['adaptive', 'partial', 'legacy-partial']
  elif args.scope == 'grain':
    modes = ['adaptive', 'adaptive-no-grain']
  elif args.scope == 'presence':
    modes = ['adaptive']
  elif args.scope in ['groups', 'adjustments', 'mixer']:
    modes = ['adaptive', 'partial']
  elif args.scope == 'light':
    modes = ['tonal', 'adaptive']
  if args.calibrated_mixer:
    modes.append('calibrated')
  return modes


sources = [root, *(directory.resolve() for directory in args.additional_references)]
temporary = ExitStack()
atexit.register(temporary.close)
registrations = [registration(source, temporary) for source in sources]
cases, references, reference_paths, reference_roots = [], {}, {}, {}
case_ids = set()
for directory in registrations:
  local_ids = set()
  for case in json.loads((directory/'cases.json').read_text())['cases']:
    case_id(case['id'])
    require(case['id'] not in case_ids, f"Duplicate registered case: {case['id']}")
    case_ids.add(case['id'])
    local_ids.add(case['id'])
    cases.append(dict(case, input=str(directory/case['input']), settings=str(directory/case['settings'])))
  for reference in json.loads((directory/'references.json').read_text())['references']:
    identity = reference['id']
    require(identity not in references, f'Duplicate registered reference: {identity}')
    references[identity] = reference
    if identity in local_ids:
      reference_paths[identity] = directory/reference['reference']
      reference_roots[identity] = directory


def output_profile(reference):
  profile = profile_of(reference)
  if profile is not None:
    return dict(profile, path=reference_roots[reference['id']]/profile['path'])
  return None
selected = [c for c in cases if c['group'] in ['neutral', 'curve-master', 'curve-red', 'curve-green',
  'curve-blue', 'curve-rgb', 'curve-point', 'curve-mid-up', 'curve-mid-down', 'curve-quarter-up', 'curve-endpoints']]
if args.scope == 'partial':
  selected = [c for c in cases if c['kind'] == 'photo' and c['group'] == 'full']
elif args.scope == 'ablation':
  selected = [c for c in cases if c['kind'] == 'photo'
    and (c['group'] == 'full' or c['group'].startswith('minus-'))]
elif args.scope == 'groups':
  selected = [c for c in cases if
    (c['kind'] == 'chart' and c['group'] in ['neutral', 'light-highlights', 'light-shadows',
      'light-saturation', 'light', 'mixer-hue', 'mixer-saturation', 'mixer-luminance', 'mixer']) or
    (c['kind'] == 'photo' and c['group'] in ['neutral', 'light', 'mixer', 'detail', 'vignette', 'color-stack'])]
elif args.scope == 'adjustments':
  selected = [c for c in cases if c['group'] == 'neutral' or c.get('role') == 'validation']
elif args.scope == 'mixer':
  selected = [c for c in cases if c['group'] == 'neutral' or
    (c['group'].startswith('mixer') and c.get('role', 'validation') == 'validation')]
elif args.scope == 'grain':
  selected = [c for c in cases if c['group'] in ['neutral', 'grain', 'minus-grain', 'full']]
elif args.scope == 'presence':
  selected = [c for c in cases if c['group'] in ['presence', 'presence-texture', 'presence-clarity', 'presence-dehaze']]
elif args.scope == 'light':
  selected = [c for c in cases if c['group'].startswith('light') and
    (c.get('role', 'validation') == 'validation'
      or (args.include_calibration and c.get('role') == 'calibration') or c['id'] in (args.case_id or []))]
if args.case_id:
  requested = set(args.case_id)
  require(requested <= {c['id'] for c in selected}, 'Requested case is absent from the chosen scope')
  selected = [c for c in selected if c['id'] in requested]
require(selected, 'No cases selected; no measurement was performed')
selected_ids = {c['id'] for c in selected}
neutral_for = {}
neutral_modes = {}
if args.paired_neutral:
  for case in selected:
    matches = [c for c in cases if c['group'] == 'neutral' and
      c['inputSHA256'] == case['inputSHA256']]
    require(len(matches) == 1,
      f"Expected one same-input neutral for {case['id']}, found {len(matches)}")
    neutral = matches[0]
    neutral_for[case['id']] = neutral
    neutral_modes.setdefault(neutral['id'], set()).update(modes_for(case))
  # Baselines must be rendered before adjusted cases, including explicitly selected neutrals.
  baselines = {c['id']: c for c in neutral_for.values()}
  selected = list(baselines.values()) + [c for c in selected if c['id'] not in baselines]
# Validate everything this run will consume, before compiling or rendering.
for case in selected:
  require(case['id'] in reference_paths, f"Missing reference in the case's own registration: {case['id']}")
  ref = references[case['id']]
  require(ref['settingsSHA256'] == case['settingsSHA256'],
    f"Reference settings do not match case settings: {case['id']}")
  evidence = [(Path(case['input']), case['inputSHA256']),
    (Path(case['settings']), case['settingsSHA256']),
    (reference_paths[case['id']], ref['referenceSHA256'])]
  profile = output_profile(ref)
  if profile is not None:
    evidence.append((Path(profile['path']), profile['sha256']))
  for path, expected in evidence:
    require(digest(path) == expected, f'Frozen evidence changed: {path}')
shutil.copytree(Path(__file__).parent, out/'tools', ignore=shutil.ignore_patterns('__pycache__'))
shutil.copytree(Path(__file__).parent.parent/'Light', out/'Light', ignore=shutil.ignore_patterns('__pycache__'))
shutil.copy2(Path(__file__).with_name('render.swift'), out/'main.swift')
if light_model:
  (out/'light-calibration.json').write_text(json.dumps(light_model.evidence, indent=2)+'\n')
for index, directory in enumerate(registrations):
  snapshot = out if index == 0 else out/'registrations'/str(index)
  snapshot.mkdir(parents=True, exist_ok=True)
  for name in ['cases.json', 'references.json']:
    shutil.copy2(directory/name, snapshot/name)
shutil.copy2(repo/'Package.swift', out/'Package.swift')
shutil.copy2(Path(__file__).parent.parent/'compare.swift', out/'compare.swift')
for path in ['Sources/BrightroomParametric', 'Sources/BrightroomColorAdjustmentKernels',
  'Plugins/BuildColorAdjustmentKernels']:
  destination = out/path
  if sys.platform == 'darwin':
    # Keep independent snapshots of the binary calibration tables without
    # allocating their data again on APFS. cp also handles volumes without cloning.
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/bin/cp', '-cRLp', repo/path, destination], check=True)
  else:
    shutil.copytree(repo/path, destination)
run(['xcodebuild', '-project', 'Dev/Brightroom.xcodeproj', '-scheme', 'ParametricMacDemo',
  '-destination', 'platform=macOS', '-derivedDataPath', '.tmp/xmp-derived-data',
  '-skipMacroValidation', '-skipPackagePluginValidation', 'CODE_SIGNING_ALLOWED=NO', 'build'], out/'build.log')
run(['xcrun', 'swiftc', '-O', '-module-cache-path', '.tmp/swift-module-cache', '-I', products,
  out/'main.swift', out/'Light/MeasuredLightFeature.swift', products/'BrightroomParametric.o',
  products/'BrightroomColorAdjustmentKernels.o', '-o', products/'render-a10'], out/'compile.log')
run(['xcrun', 'swiftc', '-O', '-module-cache-path', '.tmp/swift-module-cache',
  Path(__file__).parent.parent/'compare.swift', '-o', products/'compare-a10'], out/'compile-compare.log')
results = []
runtime = {}
for case in selected:
  directory = out/case['id']
  directory.mkdir()
  settings, curves = read_adjustments(Path(case['settings']))
  config = directory/'settings.json'
  configuration = dict(settings=settings, curves=curves)
  ref = references[case['id']]
  reference_profile = output_profile(ref)
  if reference_profile is not None:
    profile = directory/'reference-output.icc'
    shutil.copy2(reference_profile['path'], profile)
    configuration['outputICC'] = str(profile)
  else:
    configuration['outputICCReference'] = str(reference_paths[case['id']])
    configuration['referenceSHA256'] = ref['referenceSHA256']
  config.write_text(json.dumps(configuration, indent=2)+'\n')
  if light_model:
    (directory/'light-tables.bin').write_bytes(light_model.compile(settings))
  modes = sorted(neutral_modes[case['id']]) if case['id'] in neutral_modes else modes_for(case)
  for mode in modes:
    command = [products/'render-a10', case['input'], config, directory/mode, mode]
    if mode == 'calibrated-light':
      require(light_model is not None, '--light-calibration is required')
      command.append(directory/'light-tables.bin')
    run(command, directory/(mode+'-render.log'))
    work['renderedImages'] += 1
    ref = references[case['id']]
    comparison = [products/'compare-a10', reference_paths[case['id']], directory/mode/'brightroom.png',
      directory/(mode+'-comparison')]
    if args.paired_neutral and case['group'] != 'neutral':
      neutral = neutral_for[case['id']]
      comparison += [reference_paths[neutral['id']],
        out/neutral['id']/mode/'brightroom.png']
      if args.response_axes:
        comparison.append('--response-axes')
    if args.middle_channel_error:
      comparison += ['--middle-channel-source', case['input']]
    run(comparison, directory/(mode+'-compare.log'))
    metrics = json.loads((directory/(mode+'-comparison')/'comparison.json').read_text())
    render = json.loads((directory/mode/'render.json').read_text())
    if not runtime:
      runtime = {k: render[k] for k in ('os', 'defaultMetalDevice', 'workingFormat', 'outputFormat')}
      runtime['xcode'] = subprocess.check_output(['xcodebuild', '-version'], env=env, text=True).strip()
    work['comparedImages'] += 1
    work['comparedPixels'] += metrics['allPixels']['pixels']
    results.append(dict(id=case['id'], mode=mode, metrics=metrics, sourceRole=case.get('role'),
      inputSHA256=case['inputSHA256'], settingsSHA256=case['settingsSHA256'], referenceSHA256=ref['referenceSHA256'],
      outputICCSHA256=render['outputICCSHA256'],
      neutralID=neutral_for[case['id']]['id'] if args.paired_neutral and case['group'] != 'neutral' else None,
      role='selected' if case['id'] in selected_ids else 'paired-neutral'))
    print(case['id'], mode, metrics['pixelMaxChannelError'], flush=True)
    if args.metrics_only:
      (directory/(mode+'-comparison')/'difference-x64.png').unlink()
      if case['id'] not in neutral_modes:
        (directory/mode/'brightroom.png').unlink()
if args.metrics_only:
  # Every paired edit reads the neutral for its own source and renderer.
  for identity, modes in neutral_modes.items():
    for mode in modes:
      (out/identity/mode/'brightroom.png').unlink()
(out/'report.json').write_text(json.dumps({'measurement': 'linear Display-P3; white = 1; not Delta E',
  'scope': args.scope,
  'runtime': runtime, 'comparatorSHA256': digest(out/'compare.swift'),
  'registrations': [str(source) for source in sources],
  'pairedNeutral': args.paired_neutral, 'responseAxes': args.response_axes,
  'retainedImages': not args.metrics_only, 'work': work,
  'status': 'measured; no overall compatibility threshold assigned', 'cases': results}, indent=2)+'\n')
print(json.dumps(work), flush=True)
