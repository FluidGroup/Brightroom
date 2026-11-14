# A10 parameter comparison

For developed 16-bit inputs, add `--middle-channel-error` to a comparison run
to measure how the middle RGB channel moves relative to the two outer channels.
The comparator takes the middle channel's fractional position from the original
linear Display-P3 pixel. It subtracts the corresponding interpolation of the
outer channels' errors from the middle channel's error. The report contains the
95th percentile of its absolute value and the number of contributing pixels.
Pixels whose original channel span is at most 0.02 do not enter this statistic.
A grayscale input reports zero eligible pixels. The option also works with
`--paired-neutral`.

This experiment isolates A10's active adjustments after RAW development.
It produced 51 verified Lightroom references (32 chart cases and 19 photo
cases), then compared actual Brightroom exports. A separate acquisition adds
10 ProPhoto point-curve controls. A10's Color Grading saturation and luminance
are all zero; its stored Global Hue 52 has no grading effect.

The isolated point-curve implementation improved substantially. In the initial
iteration, the complete A10 partial adapter's p95 regressed after that change.
Subsequent results below retain that failure alongside later improvements.
Do not present the exported photographs as matched Lightroom looks.
This loop records measurements without an invented compatibility pass.

Later iterations added measured Mixer and tonal responses. Use `--modes tonal`
to exercise the public `WhitesFeature` / `BlacksFeature` alongside the measured
Mixer. `--case-id ID` (repeatable) selects specific cases within a scope.
Use `--modes adaptive` to select the public spatial H/S, global saturation and
Camera Raw grain algorithms. `adaptive-no-grain` reproduces the color-only
comparison with the same signed Light and saturation amounts.
With `--scope light`, omitting `--modes` compares `tonal` and `adaptive`.
The `groups`, `adjustments` and `mixer` scopes render the current `adaptive`
and the earlier `partial` paths by default.
The [Light investigation](../Light/README.md) records all updated cases, including
colored negative-direction regressions and strong positive-Whites residuals.
On the supplied TIFF/A10 pair the original preset gave p95 0.081229 with Core
Image H/S, 0.042788 with the earlier spatial H/S, and 0.042494 with the updated
positive Shadows and global Saturation responses in the color-only mode.
With the updated negative Highlights interpolation, isolated Highlights −11 on
the photograph improved from 0.006533 to 0.005211. The supplied full A10
pair rose from 0.042494 to 0.043393 with grain disabled and from 0.047665 to
0.048452 with grain enabled. These results use Shadows before Highlights.
The adaptive modes now pass the original two signed values together to
`HighlightsShadowsFeature` and use the wider-gamut positive Shadows response.
On the same 6000×4000 supplied pair, p95 dropped to 0.039885 with Brightroom
grain disabled and 0.045505 with grain enabled. For the 32×32 block means,
it fell from 0.035667 to 0.031642 without grain and from 0.035775 to 0.031819
with grain. Both settings use the same supplied Lightroom TIFF with its grain.
The A10 photograph's five Light controls alone went from 0.008012 to 0.006200.
[Joint H/S measurements](../../../docs/highlights-shadows.md#joint-highlights-and-shadows)

The adaptive adapter applies Texture, Clarity and Dehaze after the point curve.
The regional parametric curve is still omitted. The grain comparison
measures strength and spatial correlation against Lightroom's paired exports.
[Texture measurements](../../../docs/texture.md) · [Clarity measurements](../../../docs/clarity.md) · [Dehaze measurements](../../../docs/dehaze.md) · [Grain measurements](../../../docs/grain.md)

Add `--paired-neutral` to measure adjustment-response error as well as absolute
error. Each selected input must have exactly one registered neutral case with
the same input hash. The runner renders that neutral through every selected
mode before the adjusted cases. It reports
`(Brightroom adjusted - Brightroom neutral) - (Adobe adjusted - Adobe neutral)`
alongside absolute error. The `byNeutralLuminance` entries group those same pixels
by the brightness of the neutral Lightroom export. Each band reports its pixel
count, the mean luminance change in each engine, and their signed difference.
A positive difference means the Brightroom result lifted more or darkened less.

An additional registered set can supply a second strength on the same source
images. Each adjustment retains its own registration and checked reference ICC.
The runner finds the neutral case by source-file hash across the supplied sets.
IDs must be unique. The following command measures the 39 isolated Light cases
on the 13 photographs, including both Highlights strengths on every photograph.
It renders the 13 shared neutrals once per mode. The report retains each
photograph's calibration or validation role.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/photo-calibration-acquisition/acquisition-001 .tmp/xmp-research/runs/new-crossed-light \
  --additional-references .tmp/camera-raw-goal/h37-crossed-reference-001 \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --include-calibration --paired-neutral --modes adaptive
```

For example, compare a frozen set of individual Light controls:

```bash
python3 Tools/LightroomComparison/A10/run.py \
  /path/to/frozen-references /path/to/new-run \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --modes tonal adaptive --paired-neutral
```

The report distinguishes requested cases from automatically added neutral
baselines and counts rendered images, compared images, compared pixels, and
failures. Empty selections and changed evidence are refusals. A failed run
writes `failure.json` after creating its new output directory and does not
produce a successful comparison report. The requested settings hash must also
match the settings hash recorded with the Adobe reference.

The runner, both reference registrars, `PointModel`, and `FrozenSet` keep their
evidence checks enabled under `python -O` and `PYTHONOPTIMIZE=1`. To exercise their refusal
paths, run this with the analysis environment's Python (NumPy required):

```bash
python3 Tools/LightroomComparison/A10/check_evidence_guards.py /path/to/new-check
```

The check uses synthetic file bytes and metadata, plus a build sentinel. It
does not decode images or invoke Xcode, Lightroom, or a GPU. Successful controls
and corrupt-evidence cases run in normal and both optimized Python modes. It
checks stale, swapped, and missing metadata bindings, supplied-pair registration
preservation, and point-calibration inputs and amounts. `--kind register`,
`--kind pair`, and `--kind point` can limit a retained-source check. Repeat
`--kind` to select more than one entry point.

## Fixed conditions

- Lightroom Classic 15.6 / Camera Raw 18.7 / ProcessVersion 15.4.
- Identical decoded pixels: a 1024×256, 16-bit Display-P3 analytic chart and
  a 6000×4000, 16-bit Display-P3 photograph developed once with Apple RAW.
- Embedded input profile, neutral white balance and all unrelated controls;
  only the named case's settings vary. A10 itself has no CameraProfile/Look.
- Reference export: 16-bit ProPhoto TIFF, no resize, output sharpening,
  watermark or HDR. Root CRS settings are checked, including neutral values.
- Candidate: actual `ExportRenderer`, RGBAh working format, 16-bit ProPhoto PNG.
- Comparison: Float32 extended-linear Display-P3. Each pixel's error is its
  largest absolute RGB channel difference, white = 1. These are not Delta E.

The chart contains an encoded gray ramp, a linear gray ramp, and a 32³ RGB
lattice. The photo is not used to fit the curve model. Repeated inspection now
makes these development-validation cases; future acceptance needs new cases.

## Master point curve and Refine Saturation, 2026-11-11

The point adapter reads `ToneCurvePV2012*` and `CurveRefineSaturation`
into the public `PointCurveFeature`. Replay the registered Display-P3 and
ProPhoto charts, the 24 MP photograph, and their neutral exports together.
Use a new output directory on each run.

```bash
python3 Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/a10-001 .tmp/xmp-research/runs/new-point-curve-run \
  --additional-references .tmp/xmp-research/pointcurve-002 \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope point --modes point --paired-neutral
```

Version 2 measured 23 cases covering 53,505,024 pixels. On the Display-P3
chart, master-only p95 fell from 0.018475 to 0.000369. The A10 master with RGB
curves fell from 0.000935 to 0.000295 on the photograph. The separate ProPhoto
midtone-lift exports at refinement 0, 50 and 100 had p95 of 0.000560, 0.000486
and 0.000469. On the supplied TIFF the supported A10 stack with grain changed
from 0.045925 to 0.046144. The [point-curve measurements](../../../docs/point-curve.md)
describe the coverage of these controls and the remaining region-curve difference.

## Results, 2026-11-08

The previous adapter converted XMP points into `ToneCurveFeature`'s stop
domain. The new adapter uses [PointCurveFeature](../../../docs/point-curve.md)
with normalized XMP coordinates. Existing ToneCurveFeature behavior is unchanged.

| Case | Previous p95 | New p95 | New maximum |
|---|---:|---:|---:|
| Chart, A10 RGB curves | 0.079285145 | 0.000501633 | 0.000749886 |
| Chart, A10 master + RGB | 0.109986961 | 0.017076075 | 0.035035729 |
| Photo, A10 master + RGB | 0.035482071 | 0.000935341 | 0.030610979 |
| Photo, full A10 partial adapter | 0.103921622 | **0.131322652** | 0.302823663 |

Neutral p95 is 0.000170469 on the chart and 0.000079066 on the photo. The photo's
point-curve p95 fell about 97.4%, but the master curve's chromatic response is
not solved. Independent chart controls also disagree: midtone lift p95
0.018844724, midtone reduction 0.014829814, quarter-tone lift 0.022601724.

For the full partial stack, median error improved 0.054448355 → 0.035025090
while p95 worsened. Both facts must be retained. Error cancellation in the old
mapping is a plausible explanation, not a demonstrated decomposition of the
regression. At that stage the adapter omitted Whites/Blacks, parametric curves,
Texture/Clarity/Dehaze, noise reduction, grain, and Adobe profile/Look data.

Further isolation measures the *existing numeric mappings* against corresponding
Lightroom groups:

| Group | Chart p95 | Photo p95 | Photo maximum |
|---|---:|---:|---:|
| Light (includes omitted Whites/Blacks) | 0.056943774 | 0.073326513 | 0.098436177 |
| Color Mixer (OKLCh) | 0.162737131 | 0.046029329 | 0.228460193 |
| Detail (unsharp only; no NR) | — | 0.005586326 | 0.252570629 |
| Vignette (fixed Brightroom falloff) | — | 0.003146216 | 0.028983891 |
| Light + curves + Mixer partial stack | — | 0.123561233 | 0.248218864 |

Chart Light subcases: Highlights p95 0.022929400, Shadows 0.053115040,
Saturation 0.016363785. Chart Mixer subcases: Hue 0.062833615,
Saturation 0.091923684, Luminance 0.164998949. Passing identical slider numbers
to these different algorithms is not parameter compatibility. A10 alone is
insufficient to derive a general replacement parameter mapping.

The Lightroom leave-one-group-out experiment also ranks effects on this photo:
curves p95 0.08072, Mixer 0.05824, Light 0.03043, Presence 0.02437. Those numbers
are changes between two Lightroom renders, **not Brightroom errors**. Together
with the mismatch cases, they motivate measuring positive/negative Light values
and individual Mixer bands next, then checking mixed settings on new photos.

`measurements.json` retains all 41 reported candidate measurements, input,
reference, candidate and source hashes. Complete local reports and heatmaps:

- `.tmp/xmp-research/runs/point-curve-004/report.json`
- `.tmp/xmp-research/runs/a10-partial-001/report.json`
- `.tmp/xmp-research/runs/a10-groups-001/report.json`
- `.tmp/xmp-research/a10-001/ablation/report.json` (Lightroom-only effect magnitudes)

## Replay against existing references

Run from the repository root. No Python packages are required. Xcode's Metal
toolchain, local GPU access, and the retained `.tmp/xmp-research/a10-001`
acquisition are required; photographs and TIFF exports are not in git.

```sh
python3 Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/a10-001 .tmp/xmp-research/runs/new-point-run \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

Use `--scope groups` to measure Light, Mixer, Detail, Vignette and the partial
color stack. The `ablation` scope selects the full photographic preset and
each registered group omission. To measure what adding a group changes with
the other groups already on, render the matching Lightroom and Brightroom
cases and compare their pixel changes with the two commands below.

```sh
python3 Tools/LightroomComparison/A10/run.py .tmp/xmp-research/a10-001 \
  .tmp/xmp-research/runs/omission-exports --scope ablation --modes adaptive \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
python3 Tools/LightroomComparison/A10/measure-omissions.py \
  .tmp/xmp-research/runs/omission-exports a10-photo-full .tmp/omission-responses
```

The second report's `groupResponse` measures the difference between the two
engines' full-minus-omitted changes on every pixel. Each pair must have the
same source, the same render mode, and only the registered group removed
from the authored XMP. `withoutAbsolute` measures the error of the whole
remaining preset. Interactions among groups affect both measurements.

Add `--explain-omission a10-photo-minus-presence` to the second command to
measure how the residual of that group aligns with the residuals from other
one-at-a-time omissions. The report gives their signed mean RGB products,
cosines, and the remaining contribution from the baseline and interactions.
A negative product means that the two group errors tend to cancel. In paired
comparisons, `errorEnergy` gives the baseline and response mean squared errors
and twice their mean product, over all pixels and within each neutral-luminance
band. Their sum is the adjusted mean squared error. The identity applies to
squared RGB error. Percentiles are reported separately.

With the joint H/S implementation, the group-response p95 on the registered
A10 photograph was 0.034532 for curves (including the parametric curve),
0.032725 for grain, 0.024369 for presence, 0.009558 for Light, 0.007781
for Mixer, 0.006899 for vignette and 0.006389 for detail. All measurements
use the same 24 million pixels with the other groups active. Removing
presence raised whole-image p95 from 0.045895 to 0.054900. The differences
between the full and omitted images expose that group's response even when
residuals from several groups offset each other.

The `partial` scope compares the full partial adapter with its
previous curve mapping. Every output directory must be new. The runner checks
frozen input/settings/reference hashes before rendering, builds the actual
ParametricMacDemo package, and snapshots tools and relevant source. Full RGB
errors, extrema, luminance-band metrics and heatmaps remain in each run.

Each comparison also reports `belowDisplayP3Black`. For the reference and
candidate it counts pixels whose lowest linear Display P3 channel is below
−0.001 and gives the number found at the same positions in both images.
When the reference contains such pixels, `minimumChannelErrorP95` measures
the error of the lowest channel and `pixelMaxChannelErrorP95` measures the
largest RGB error over those same reference positions.
Wide-gamut TIFFs can retain those colors even when a P3 view clips them.

`compare.swift` is shared with the grading loop. Its exact-zero, known-step,
baseline-response, coordinate-marker and incompatible-input controls were
validated separately. No perceptual threshold is assigned here.

## Acquire another case set

Preparation uses the previously frozen `probe.tiff`,
`fixtures/L1007620-developed.tiff`, and `cases/neutral.xmp` under the research
root. It does not redevelop RAW or infer a neutral Adobe preset. Inspect that
baseline when starting a different process-version experiment.

```sh
python3 Tools/LightroomComparison/A10/prepare.py \
  .tmp/xmp-research /path/to/A10.xmp .tmp/xmp-research/new-a10-set
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  xcrun swift -module-cache-path .tmp/swift-module-cache \
  Tools/LightroomComparison/A10/embed-inputs.swift \
  .tmp/xmp-research/new-a10-set/cases.json
```

`embed-inputs.swift` creates metadata-only copies and verifies identical decoded
pixels. Import those copies into the research Lightroom catalog, ensure embedded
settings are applied, and export the fixed settings above to
`new-a10-set/inputs/adobe-references/`, retaining basenames with `.tif` extension.
The [manifest-bound SDK exporter](../README.md#acquire-an-explicit-reference-manifest)
now adds these paths in place and exports the exact list. Start it through
Lightroom's Plug-in Extras menu; no headless exporter is claimed.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  xcrun swift -module-cache-path .tmp/swift-module-cache \
  Tools/LightroomComparison/A10/inspect.swift \
  .tmp/xmp-research/new-a10-set/inspection \
  .tmp/xmp-research/new-a10-set/inputs/adobe-references/*.tif
python3 Tools/LightroomComparison/A10/register.py \
  .tmp/xmp-research/new-a10-set/cases.json \
  .tmp/xmp-research/new-a10-set/inspection
```

Inspection records actual dimensions, depth, profile, and image hashes, and
extracts XMP without applying it. Each `images.json` record includes `metadata`
and `metadataSHA256`, binding the sidecar path and exact extracted bytes to the
image inspection. The inspector reads the image once for both extraction and
its image hash. Registration verifies this binding before parsing the same
packet bytes, checks every root CRS setting, and freezes the exported reference
hashes once. It retains the full inspection record. These hashes detect
accidental swaps or corruption against the inspection record. They are not an
authenticity signature.
Only file identity, AlreadyApplied and CompatibleVersion are excluded from
parameter equality. Absent dependent settings are accepted only when their
controlling amount is zero; each omission is retained. Refine Saturation can
be absent only for an exact identity master curve. Registration never overwrites
an existing reference set. The portable extraction/registration path was checked
against frozen chart-neutral and photo-point-curve references.

Legacy `images.json` files without both metadata fields cannot register new
references. Run `inspect.swift` again against the original TIFFs into a new
directory, then pass that directory to `register.py` or `register-pair.py`.
Do not add hashes to old inspection records or reuse an extraction directory.
For example:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  xcrun swift -module-cache-path .tmp/swift-module-cache \
  Tools/LightroomComparison/A10/inspect.swift \
  /path/to/new-inspection /path/to/reference.tif
python3 Tools/LightroomComparison/A10/register.py \
  /path/to/unregistered-set/cases.json /path/to/new-inspection
```

Existing `references.json` files remain frozen and the comparison runner can
consume them. Reinspection does not upgrade their historical provenance or
authorize overwriting a registration.

## Compare a supplied bitmap / Lightroom export pair

Use `register-pair.py` for an already acquired pair. It verifies every authored
preset control against the reference's embedded root XMP. The candidate reads the
original preset file. Registration freezes both hashes and retains the resolved
reference settings for inspection. It does not infer unrecorded export options
or certify that Lightroom's unadjusted output is neutral.
Both input and reference require bound metadata sidecars from a fresh
inspection. Registration refuses an existing `cases.json` or `references.json`,
and exclusive creation prevents replacing either file if another registration
appears after validation. Publishing the two new files is not a filesystem
transaction.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  xcrun swift -module-cache-path .tmp/swift-module-cache \
  Tools/LightroomComparison/A10/inspect.swift .tmp/supplied-pair/inspection \
  /path/to/input.tiff /path/to/processed.tif
python3 Tools/LightroomComparison/A10/register-pair.py \
  /path/to/input.tiff /path/to/processed.tif /path/to/A10.xmp \
  .tmp/supplied-pair/inspection .tmp/supplied-pair
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/supplied-pair .tmp/xmp-research/runs/new-supplied-pair \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope partial --modes adaptive
```

The candidate exports through the reference's ICC profile. When a separate
profile was retained, the runner checks its hash and copies it into the run.
For older registrations the renderer checks the reference image's hash and
reads its embedded profile. Each render records the SHA-256 of the ICC data
used to define its output color space.

The supplied `bitmap_from_apple_raw.tiff` / `processed.tif` pair and the original
`A10.xmp` are registered in `.tmp/xmp-research/user-a10-authored-002`. Both
TIFFs are 6000×4000, 16-bit Adobe RGB. The
reference records Lightroom 9.6, Camera Raw 18.7, ProcessVersion 15.4, an Embedded
profile, and all 91 authored A10 controls match. With the existing models frozen:

| Full A10 adapter | p50 | p95 |
|---|---:|---:|
| Previous OKLCh Mixer / CI Light | 0.035342 | 0.131758 |
| Measured Mixer / CI Light | 0.031710 | 0.092173 |
| Measured Mixer / experimental Light | 0.031973 | 0.080962 |
| Measured Mixer / public Whites and Blacks / Core Image H/S | 0.031990 | 0.081229 |
| Original A10 XMP / same Mixer and tonal points / spatial H/S | 0.008015 | 0.042788 |

An unadjusted Brightroom export equals the input in all measured Float32
comparison pixels. No unadjusted Lightroom export was supplied; output
sharpening/watermark settings are unknown. The spatial H/S candidate has a mean
signed error of −0.00949, −0.00819, −0.00628 in linear P3 red, green and blue.
It omits the preset's grain and presence controls. This is another export of the
same scene, not an independent photographic-scene holdout. No model was refit.
The original-preset report and display comparison are in
`.tmp/xmp-research/runs/authored-a10-001`. The older stage measurements remain
in `.tmp/xmp-research/runs/user-a10-001`.

## DNG output is separate evidence

The updated production-engine run is
`.tmp/xmp-research/developed/brightroom-engine-010/`. It uses the supplied
`L1007620.DNG` with both A10 and the photo XMP, through
`SourceImage(rawContentsOf:) -> EditingDocument.render() -> ExportRenderer`.
A10 is 6000×4000; the cropped photo XMP output is 6000×2553. Both are 16-bit
Display-P3 PNGs, explicitly named `*-partial.png`.

The production RAW intermediate is now **16-bit floating-point extended-linear
Display-P3**, retaining 192 MB for this 24 MP image. The common TIFF used for
parameter calibration remains frozen; RAW precision changes do not enter the
post-development comparisons. `configuration.json` records the
approximate and omitted controls; `render.json` records actual dimensions,
precision, minimum alpha and hashes. All three PNGs, including the neutral
control, had minimum alpha 255 after the full-resolution iOS export. Original
files were checked unchanged. See the parent
[README](../README.md#develop-a-dng-with-the-partial-xmp-adapter) for rerunning it.

## Subsequent Mixer and Light investigation

The [measured Mixer](../Mixer/README.md) retains OKLCh as the default and adds
an explicit approximation. On the photo its isolated p95 falls from 0.04603 to
0.003949; full A10 falls from 0.13132 to 0.09145 (legacy curves: 0.10392).
With the new Mixer, the no-Light ablation is 0.03698, no-Mixer 0.08497, and
no-curves 0.09656. Percentiles are not additive causal contributions.

A pointwise Shadows response learned from the chart over-brightens the photo,
so it was rejected. Equal-gray locations also differ within the chart under
Highlights/Shadows. Local/adaptive tone behavior remains unresolved; no general
Lightroom Light compatibility is claimed. The subsequent optional [Light experiment](../Light/README.md) adds measured
Whites/Blacks/Saturation and lowers full A10 p95 to 0.08015, but its mixed-Light
chart regresses. Parametric curves and presence remain missing. The latest DNG
output at that stage used this explicit experiment; no full Light parity is claimed.

## Measure Presence and Dehaze

`--scope presence --paired-neutral` selects the registered Texture, Clarity,
Dehaze and combined Presence exports, plus each source's own neutral. The
adaptive renderer maps signed `Texture`, `Clarity2012` and `Dehaze` values directly to their public features.

```sh
study=.tmp/camera-raw-goal/presence-response/acquisition
python3 Tools/LightroomComparison/A10/run.py "$study" .tmp/xmp-research/runs/new-dehaze \
  --scope presence --paired-neutral --modes adaptive \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
python3 Tools/LightroomComparison/A10/run.py "$study" .tmp/xmp-research/runs/new-strong-shadows \
  --scope light --paired-neutral --modes adaptive \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

The 34-file registration contains five neutrals, five Dehaze strengths per
source and four single-control Shadows −100 photographs. The `cases.json`
roles record the split by whole source. To reproduce the Dehaze endpoint
coefficients, decode the registered TIFFs into a new `decoded` directory
once, then run the fitter with a new output path.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  xcrun swift -O Tools/LightroomComparison/Light/decode.swift \
  "$study/decoded" "$study"/inputs/adobe-references/*.tif
python3 Tools/LightroomComparison/Dehaze/calibrate.py "$study" .tmp/dehaze-endpoints.json
```

To isolate how the three Presence controls affect the same pixels, compare
their individual Lightroom TIFFs with their joint Lightroom TIFF. The
following command uses the A10 strengths of Texture +4, Clarity +4 and
Dehaze +9. Each TIFF is decoded afresh and bound to its applied XMP, input
file, dimensions and embedded profile. An isolated reference on any registered
photograph can also be measured by passing one edit ID and omitting `--joint`.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  xcrun swiftc -O Tools/LightroomComparison/Light/decode.swift -o .tmp/decode-presence
python3 Tools/LightroomComparison/A10/measure-presence.py .tmp/xmp-research/a10-001 \
  a10-chart-neutral a10-chart-presence-texture a10-chart-presence-clarity \
  a10-chart-presence-dehaze --joint a10-chart-presence \
  --decoder .tmp/decode-presence --output .tmp/a10-presence-response.json
```

The output measures the individual edit, the change unexplained by measured
luminance, and the change still unexplained after allowing color to expand
or contract along the original RGB hue line. Both projections use information
from the edited reference. The joint residual subtracts the sum of all three
isolated RGB changes from their simultaneous change at each pixel. On the
1024 × 256 A10 chart, that residual is 0.001261 at p95, against a total
joint change of 0.036128 in linear Display P3 (white = 1).

## Reproduce the Clarity response

The signed study contains the same chart, sign, bridge, boat and plant at
0, −100, −50, +4, +50 and +100. The calibration command reads only whole
sources marked `fit`. It freshly decodes their 16-bit TIFFs, verifies the
requested and applied XMP against the same input and profile, and fits brightness
and chroma gains from the local luminance difference and mean absolute difference.
The registered boat and plant have role `evaluate`.

```sh
study=.tmp/camera-raw-goal/clarity-response/acquisition
dev=/Applications/Xcode-27.2.0.app/Contents/Developer
DEVELOPER_DIR="$dev" xcrun swiftc -O Tools/LightroomComparison/Light/decode.swift -o .tmp/decode-clarity
python3 Tools/LightroomComparison/Clarity/calibrate.py "$study" .tmp/decode-clarity .tmp/clarity-endpoints.json
python3 Tools/LightroomComparison/A10/run.py "$study" .tmp/clarity-comparison \
  --scope presence --modes adaptive --paired-neutral --response-axes --developer-dir "$dev"
```

Each source uses its own neutral for the response comparison. The 30
registered cases include five neutrals and 25 nonzero changes. The original
chart-only +4 prototype and the signed public implementation have different
coefficients. [Public API and measured errors](../../../docs/clarity.md)

## Reproduce the Texture response

The Texture study contains four photographs and two types of chart. The 768 × 384
sinusoidal chart contains 32 gray patches at eight periods. A 1536 × 384 copy
repeats the same pixels horizontally. Its neutral and +50 exports check the
effect of changing the overall image dimensions. The Texture calibration reads
the other chart and the two photographs assigned the `fit` role, plus the
768-pixel chart. The largest measured contrast change on that chart bounds the
gain for each slider strength. Each scene is decoded in temporary storage.

```sh
study=.tmp/camera-raw-goal/texture-response/acquisition
dev=/Applications/Xcode-27.2.0.app/Contents/Developer
DEVELOPER_DIR="$dev" xcrun swiftc -O Tools/LightroomComparison/Light/decode.swift -o .tmp/decode-texture
python3 Tools/LightroomComparison/Texture/calibrate.py "$study" .tmp/decode-texture .tmp/texture-gains.json \
  --frequency-neutral texture-wave768-neutral
python3 Tools/LightroomComparison/Texture/measure_frequencies.py "$study" texture-wave768-neutral \
  texture-wave768-Texture-50 --decoder .tmp/decode-texture --output .tmp/texture-wave50.json
python3 Tools/LightroomComparison/A10/run.py "$study" .tmp/texture-response-metrics \
  --scope presence --modes adaptive --paired-neutral --metrics-only --developer-dir "$dev"
```

Generate the two TIFF inputs for another acquisition with
`xcrun swift Tools/LightroomComparison/Texture/frequency-chart.swift NEW_DIRECTORY`.
Use `--metrics-only` for iteration on any scope. The loop removes an edited PNG
and its difference image after computing the metrics, then releases the neutral
PNGs after their paired comparisons. Omitting the flag keeps those images for
visual review. On APFS the source and calibration snapshots share disk blocks
until either copy is edited. Synthetic evidence checks discard successful fixture trees after
writing each log. Pass `--keep-fixtures` to retain their inputs for debugging.
