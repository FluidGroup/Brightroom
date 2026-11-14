"""Render a DNG through Brightroom's iOS engine with explicitly partial XMP mappings.

Creates a temporary test driver, executes it on a local simulator, then removes
only that driver. The input files are read-only. Output must be a new directory.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
from A10.xmp_settings import read_adjustments

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('raw', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('xmp', type=Path, nargs='+')
parser.add_argument('--simulator', help='Simulator UUID; omit with --catalyst')
parser.add_argument('--catalyst', action='store_true')
parser.add_argument('--developer-dir', required=True)
parser.add_argument('--derived-data', type=Path, help='Xcode build directory for this render')
parser.add_argument('--light-calibration', nargs=2, type=Path, metavar=('COARSE', 'FINE'),
    help='optional frozen chart sets for the experimental Whites/Blacks/Saturation model')
args = parser.parse_args()
if not args.catalyst and not args.simulator:
    parser.error('--simulator or --catalyst is required')
repo = Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
presets = []
light_model = None
if args.light_calibration:
    spec = importlib.util.spec_from_file_location('point_model', Path(__file__).parent/'Light/point_model.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    light_model = module.PointModel(*args.light_calibration)
for path in args.xmp:
    settings, curves = read_adjustments(path)
    presets.append(dict(name=path.stem, xmp=str(path.resolve()), xmpSHA256=sha(path), settings=settings, curves=curves))
    if light_model:
        tables = out/(path.stem+'-light-tables.bin')
        tables.write_bytes(light_model.compile(settings))
        presets[-1]['lightTables'] = str(tables)
        presets[-1]['lightTablesSHA256'] = sha(tables)
# Give the test process its own fixture. A file open in the user's Downloads
# can wait for a macOS privacy prompt in an unhosted test runner.
fixture = out/'input.DNG'
shutil.copy2(args.raw, fixture)
assert sha(fixture) == sha(args.raw)
config = dict(raw=str(fixture), originalRaw=str(args.raw.resolve()), rawSHA256=sha(args.raw), output=str(out), presets=presets,
    mappings={
        'RAW': 'Apple defaults through production SourceImage, eager 16-bit float extended-linear Display-P3. Adobe profile and Look are not reproduced.',
        'Exposure2012': 'direct EV; neutral in these files; non-neutral Adobe parity not established',
        'Highlights2012/Shadows2012': 'Public HighlightsShadowsFeature(highlights:shadows:) with signed XMP slider units and measured interaction',
        'Whites2012/Blacks2012': 'Public WhitesFeature and BlacksFeature with signed XMP slider amounts',
        'Texture': 'Public TextureFeature on developed RGB, signed XMP amount before Clarity',
        'Clarity2012': 'Public ClarityFeature on developed RGB, signed XMP amount before Dehaze',
        'Dehaze': 'Public DehazeFeature on developed RGB, signed XMP amount after the point curve',
        'Saturation': 'Public SaturationFeature(lightroomAmount:), measured signed SDR response',
        'ToneCurvePV2012*/CurveRefineSaturation': 'PointCurveFeature v2, normalized XMP coordinates in sRGB-encoded ProPhoto primaries. The master samples the spline according to the middle channel. Refine Saturation uses the XMP value (0 through 100, default 100) before the independent RGB curves.',
        'Hue/Saturation/LuminanceAdjustment*': 'ColorMixerFeature.lightroomApproximation v1: measured PV 15.4 SDR response; not exact Adobe compatibility',
        'ColorGrade*/SplitToning*': 'ColorGradingFeature; zero saturation and luminance in supplied presets',
        'Crop': 'normalized top-left coordinates snapped inward to source pixels; angle must be zero',
        'Sharpness/SharpenRadius': 'approximation: unsharp intensity /100, absolute radius',
        'GrainAmount/GrainSize/GrainFrequency/GrainSeed': 'GrainFeature.CameraRaw after crop and vignette. Texture statistics measured at 20/42/70; other slider combinations estimated. Brightroom seed defaults to zero.',
        'PostCropVignetteAmount': 'approximation: -amount/50 with Brightroom fixed circular falloff'},
    unsupported=['CameraProfile', 'Look/Adobe Color/LookTable',
        'Parametric curve', 'noise reduction',
        'Lens profile/distortion/CA', 'SharpenDetail/SharpenEdgeMasking', 'Vignette shape controls'],
    status='Partial interpretation; not a complete Adobe XMP renderer')
if light_model:
    config['mappings']['Highlights2012/Shadows2012'] = 'CIHighlightShadowAdjust: -highlights/100, shadows/100'
    config['mappings'].pop('Whites2012/Blacks2012')
    config['mappings']['Whites2012/Blacks2012/Saturation'] = 'Experimental chart-measured RGB responses; piecewise linear parameter interpolation, 32-cubed tetrahedral RGB interpolation, Whites then Blacks then Saturation'
    config['mappings'].pop('Saturation')
    config['mappings'].pop('Clarity2012')
    config['mappings'].pop('Texture')
    config['mappings'].pop('Dehaze')
    config['unsupported'].extend(['Texture', 'Clarity2012', 'Dehaze'])
    config['lightCalibration'] = light_model.evidence
for preset in presets:
    if float(preset['settings'].get('CropAngle', 0)) != 0:
        raise ValueError('Non-zero CropAngle is unsupported by this research adapter')
configuration = out/'configuration.json'
configuration.write_text(json.dumps(config, indent=2)+'\n')
driver = repo/'Dev/Tests/BrightroomEngineTests/XMPResearchExportTests.swift'
if driver.exists():
    raise FileExistsError(driver)
template = Path(__file__).with_name('DevelopXMP.swift.template').read_text()
text = template.replace('__CONFIGURATION__', json.dumps(str(configuration), ensure_ascii=False))
text = (Path(__file__).parent/'Light/MeasuredLightFeature.swift').read_text()+'\n'+text
(out/'driver.swift').write_text(text)
driver.write_text(text)
try:
    with (out/'xcodebuild.log').open('w') as log:
        subprocess.run(['xcodebuild', '-project', 'Dev/Brightroom.xcodeproj', '-scheme', 'BrightroomEngineTests',
            '-destination', 'platform=macOS,variant=Mac Catalyst' if args.catalyst else 'platform=iOS Simulator,id='+args.simulator,
            '-derivedDataPath', str(args.derived_data or (
                '.tmp/grading-catalyst-derived' if args.catalyst else '.tmp/grading-ios-derived')),
            '-only-testing:BrightroomEngineTests/XMPResearchExportTests', '-parallel-testing-enabled', 'NO',
            '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
            '-skipMacroValidation', '-skipPackagePluginValidation', 'CODE_SIGNING_ALLOWED=NO',
            '-resultBundlePath', str(out/'result.xcresult'),
            *(['SUPPORTS_MACCATALYST=YES', 'MACOSX_DEPLOYMENT_TARGET=14.0', 'IPHONEOS_DEPLOYMENT_TARGET=17.0'] if args.catalyst else []), 'test'], cwd=repo,
            env=dict(os.environ, DEVELOPER_DIR=args.developer_dir), stdout=log, stderr=subprocess.STDOUT, check=True)
finally:
    if driver.read_text() == text:
        driver.unlink()
# Confirm originals did not change and require observed output, not test exit alone.
assert sha(args.raw) == config['rawSHA256']
for path, preset in zip(args.xmp, presets):
    assert sha(path) == preset['xmpSHA256']
result = json.loads((out/'render.json').read_text())
assert len(result['outputs']) == len(presets) + 1
print(json.dumps(result, indent=2))
