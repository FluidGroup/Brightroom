"""Build and measure ColorGradingFeature against frozen Lightroom references.

No Lightroom UI is driven here. Acquisition is a separate, verified step.
The output directory must be new; failures are never recorded as passes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('research', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--developer-dir', required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
root = args.research.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
env = dict(os.environ, DEVELOPER_DIR=args.developer_dir)
products = repo / '.tmp/xmp-derived-data/Build/Products/Debug'

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def run(command, log):
    with log.open('w') as stream:
        subprocess.run(list(map(str, command)), cwd=repo, env=env,
                       stdout=stream, stderr=subprocess.STDOUT, check=True)

calibration = json.loads(Path(__file__).with_name('calibration.json').read_text())
if sha(root/'probe.tiff') != calibration['probeSHA256']:
    raise RuntimeError('Common input changed; reacquire references instead of reusing them')

references = {r['id']: r for r in json.loads((root/'grading-references.json').read_text())['references']}
cases = [c for c in json.loads((root/'grading-cases.json').read_text())['cases']
         if c['purpose'] in ('baseline', 'heldout')]
for case in cases:
    ref = references[case['id']]
    if sha(root/ref['reference']) != ref['referenceSHA256']:
        raise RuntimeError('Frozen reference changed: ' + case['id'])
# Capture all candidate sources, settings and reference provenance for this run.
shutil.copytree(repo/'Tools/LightroomComparison', out/'tools',
                ignore=shutil.ignore_patterns('__pycache__'))
for name in ['grading-cases.json', 'grading-references.json', 'grading-calibration-provenance.json']:
    shutil.copy2(root/name, out/name)
for source in ['Sources/BrightroomParametric/ColorGrading', 'Sources/BrightroomColorAdjustmentKernels', 'Plugins/BuildColorAdjustmentKernels']:
    shutil.copytree(repo/source, out/source)
run(['xcodebuild', '-project', 'Dev/Brightroom.xcodeproj', '-scheme', 'ParametricMacDemo',
     '-destination', 'platform=macOS', '-derivedDataPath', '.tmp/xmp-derived-data',
     '-skipMacroValidation', '-skipPackagePluginValidation', 'CODE_SIGNING_ALLOWED=NO', 'build'], out/'build.log')
run(['xcrun', 'swiftc', '-O', '-module-cache-path', '.tmp/swift-module-cache', '-I', products,
     repo/'Tools/LightroomComparison/render-grading.swift', products/'BrightroomParametric.o',
     products/'BrightroomColorAdjustmentKernels.o', '-o', products/'render-grading'], out/'compile.log')
run(['xcrun', 'swiftc', '-O', '-module-cache-path', '.tmp/swift-module-cache',
     repo/'Tools/LightroomComparison/compare.swift', '-o', products/'compare-grading'], out/'compile-compare.log')
results = []
for case in cases:
    directory = out/case['id']
    directory.mkdir()
    settings = directory/'settings.json'
    settings.write_text(json.dumps(case['changes'], indent=2)+'\n')
    reference = references[case['id']]
    run([products/'render-grading', root/'probe.tiff', settings, directory/'candidate', 'prophoto'], directory/'render.log')
    command = [products/'compare-grading', root/reference['reference'], directory/'candidate/brightroom.png', directory/'comparison']
    if case['purpose'] != 'baseline':
        command += [root/references['grading-neutral']['reference'], out/'grading-neutral/candidate/brightroom.png']
    run(command, directory/'compare.log')
    metrics = json.loads((directory/'comparison/comparison.json').read_text())
    results.append(dict(id=case['id'], purpose=case['purpose'], parameters=case['changes'],
                        status='measured; no compatibility threshold assigned', metrics=metrics))
    print(case['id'], metrics['pixelMaxChannelError'], flush=True)
(out/'report.json').write_text(json.dumps(dict(
    measurement='linear Display-P3 RGB; white = 1; not perceptual Delta E',
    inputSHA256=sha(root/'probe.tiff'), cases=results), indent=2)+'\n')
