# Light parameter investigation

BrightroomParametric exposes measured `WhitesFeature` and `BlacksFeature`, plus
opt-in spatial Highlights/Shadows. Positive Whites now adapts to image statistics;
negative Whites and Blacks retain their pointwise behavior. Their known limitations and public usage are in
[Whites and Blacks](../../../docs/whites-blacks.md). Existing default Highlight, Shadow
and Saturation behavior is unchanged; use `.lightroomApproximation` to select the
new H/S processing. See [spatial H/S](../../../docs/highlights-shadows.md). `MeasuredLightFeature.swift` retains the
earlier three-control research adapter, including global Saturation, so previous
comparisons remain reproducible. It is not an automatic XMP importer.

It uses only analytic charts at -100/-50/-25/-10/0/10/25/50/100. A10 values and
photographs are validation, not training data. Parameter responses interpolate
piecewise linearly. A 32-cubed lattice with tetrahedral interpolation evaluates
linear-P3 RGB deltas in Whites, Blacks, Saturation order. The comparison adapter
places these after its existing CI Highlights/Shadows and before point curves.
Working-space matching, alpha and input extent follow the normal Feature path.
Outside SDR, boundary deltas extend without clipping the input; Adobe HDR
behavior has not been established.

## Measured improvements and remaining failures

Full-photo p95 is the maximum absolute RGB channel difference per pixel in
linear Display-P3, with white = 1. It is not Delta E.

The frozen `compare.swift` uses nearest rank, `sorted[ceil(n * p) - 1]`,
without percentile interpolation. New Python experiments can use
`error_metrics.rgb_error(candidate, reference)` to share its Double channel
deltas, Float32 pixel maxima, and percentile convention. This helper does not
decode ICC profiles, validate image identity or alpha, or turn a numerical
prediction into evidence of a public-feature render. Those checks remain with
the acquisition reader and actual renderer comparison.

| Case | Previous mapping | Measured point controls |
|---|---:|---:|
| Whites -22 | 0.024115 (omitted) | 0.000196 |
| Blacks +11 | 0.011476 (omitted) | 0.000248 |
| Saturation +5 | 0.000541 | 0.000261 |
| Mixed Light, photo | 0.100022 | 0.095821 |
| Mixed Light, chart | 0.089981 | **0.100053 (worse)** |
| Full A10 with measured Mixer, photo | 0.091450 | 0.080153 |

Full A10 median slightly worsens: 0.031293 to 0.031571. The full-stack p95
improvement does not establish uniform accuracy. The mixed chart regression
remains recorded, and the model is explicitly experimental.

In the original Core Image baseline, Highlights -11 and Shadows +30 were at p95 0.007700 and 0.062515 respectively.
A chart-derived Shadows transfer was rejected: on the photo its predicted
response p95 was 0.08330 versus Adobe's 0.01039. Equal-gray chart locations also
respond differently. This falsifies a purely pointwise mapping for these
controls; it does not identify Adobe's exact local or histogram-dependent method.
No A10-only strength coefficient was used to hide that mismatch.

New full-A10 ablations with both measured models: no curves 0.084505, no Mixer
0.074504, no Light 0.036981. These are non-additive comparisons. Remaining
errors include Highlights/Shadows, parametric curves, presence, detail and other
unsupported controls; prior cancellation of errors is still a hypothesis.

## Reproduce

Acquire and register the coarse `A10/prepare-adjustments.py` and fine
`Mixer/prepare-responses.py` sets using the manifest-bound SDK exporter.
Decode their chart TIFFs with `Mixer/decode.swift`. The model verifies hashes
before consuming them. The loop saves `light-calibration.json`, compiled tables,
source snapshots, configuration and actual render/measurement hashes.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/adjustments-001 .tmp/xmp-research/runs/new-light \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --modes calibrated calibrated-light \
  --light-calibration .tmp/xmp-research/adjustments-001 \
    .tmp/xmp-research/response-model-001
```

Use `--scope ablation` with the A10 reference set to evaluate the whole preset.
`calibrated` selects only the measured Mixer; `calibrated-light` additionally
selects these point controls. Neither mode silently substitutes a Shadows LUT.

The supplied-DNG run `developed/brightroom-engine-007` used the same
`--light-calibration` arguments with `develop-xmp.py`. Its 16-bit P3 outputs
still represent a partial XMP interpretation, and Apple performs the RAW
conversion into a 16-bit floating-point extended-linear-P3 intermediate.

`evaluate-point-model.py` retains the rejected +/-50 pointwise hypothesis as a
rerunnable diagnostic. `decode-samples.swift` takes an output folder and photo
paths, retaining one sample every eight pixels after a full ICC-managed Float32
decode. Give each input a unique basename. These sample metrics are separate
from the full-image renderer comparisons and are labelled as such in
`measurements.json`.

Fresh point-controls holdout (Whites +19, Blacks -27, Saturation -16): chart p95
0.070967 -> 0.004774, photo 0.031502 -> 0.024031. This is an unresolved
photographic generalization/composition failure, despite the independent A10
control improvements. The model remains an explicit research adapter.

The split acquisition localizes that holdout failure: Whites +19 has chart/photo
p95 0.002028/0.024392, Blacks -27 0.000747/0.000593, and Saturation -16
0.001794/0.000249. Positive Whites therefore also fails chart-to-photo transfer.
Do not attribute the remaining Light mismatch only to Highlights/Shadows or
present the public features as a complete Lightroom implementation.

## Public Whites and Blacks

`build-calibration.py COARSE FINE OUTPUT.bin MANIFEST.json` freezes the same
Whites/Blacks responses from 18 chart references. It averages each gray vertex's
RGB deltas to remove measurement-rounding casts, leaving colored vertices intact.
`compress.swift INPUT.bin OUTPUT.lzfse` packs the Float32 data losslessly.
`calibration.json` records the layout, reference/decoded hashes and final hashes.
The resource is 5,424,365 bytes compressed, 7,077,888 bytes decoded, with two
524,288-byte compiled tables at most in the cache. Float32 storage deliberately
avoids another quantization; this costs more package space than Float16.

Run `A10/run.py` with `--modes tonal` to use the actual public features and the
measured Mixer. This mode needs no external Light calibration. It keeps the
existing CI Saturation, whereas `calibrated-light` uses the experimental measured
Saturation; their full-stack results therefore include that difference too.

## Context validation

`context-inputs.swift OUTPUT` makes four 1024x256, 16-bit P3 images: a full ramp,
the identical ramp in a 32-row stripe on dark/light surrounds, and uniform
midgray. `prepare-context.py RESEARCH FIXTURES OUTPUT` prepares 24 neutral and
signed cases including the frozen photograph. Feed its manifest through the
existing `embed-inputs.swift`, SDK exporter, inspection and registration
sequence in the [A10 procedure](../A10/README.md). Decode the chart references
with `Mixer/decode.swift`, then run `analyze-context.py REFERENCES OUTPUT.json`.
These new fixtures are validation only; never pass them to the resource builder.

The central ramp's Whites +25 response changes by up to 0.021821 on a dark
surround and 0.011568 on a light surround. The paired neutral ramps are exactly
equal. Whites -25 and Blacks +/-25 have identical central-ramp responses in
these fixtures. Negative Blacks nevertheless retains a mismatch on uniform
midgray. This proves a fixed per-pixel transform is insufficient for Whites;
it does not identify convolution, a local neighborhood, or global adaptation.
The adaptive follow-up below adds histogram-preserving rearrangements and
near/far surround swaps.


## Adaptive follow-up (2026-11-08)

The current loop runs actual Parametric features with `--modes adaptive`.
`tonal` retains Core Image H/S while using the current public Whites/Blacks;
`calibrated-light` retains the original pointwise research adapter, including
its different global Saturation. Keep those distinctions when assigning causes.

Acquisition sets:

- `adaptive-inputs.swift` and `prepare-adaptive.py`: full/permuted ramps,
  near/far surround swaps, and dark/light surrounds, 36 references.
- `calibration-inputs.swift` and `prepare-adaptive-calibration.py`: five gray
  fields, three restricted ramps, and full-ramp amount axes, 72 references.
- `scene-inputs.swift` and `prepare-scenes.py`: sixteen deterministic grayscale
  scenes with varying means, contrast and spatial frequencies, 80 references.
- `holdout-inputs.swift PHOTO OUTPUT` and `prepare-adaptive-holdout.py`: a new
  color scene and a reduced existing photograph, each neutral plus W+42/+75,
  H-37/+23 and S+17/-32, 14 references. Edge extension before Lanczos is required
  to keep the resized photograph opaque. The first acquisition had transparent
  edges and was rejected; `adaptive-holdout-002` is the valid immutable set.

The preparation scripts take `RESEARCH FIXTURES OUTPUT`; the gray calibration
script additionally takes the full-ramp input path before `OUTPUT`. Feed each
manifest through `A10/embed-inputs.swift`, `prepare-reference-export.py`, the
manifest-bound Lightroom SDK menu command, `A10/inspect.swift`, and
`A10/register.py`. `Light/decode.swift OUTPUT IMAGES...` handles arbitrary image
sizes while requiring TIFF16, ICC, orientation 1, opaque finite pixels. Avoid the
Lightroom device-import dialog entirely.

The spatial probe shows a histogram-preserving permutation changes H/S and
positive Whites. Near/far swaps change H/S but did not change Whites in the
central tested ramp. This supports a smoothed-statistics approximation for
Whites; it does not prove Adobe uses our smoothing radius or statistics.

Reproduce the fit in the local analysis environment (NumPy and SciPy required):

```sh
OPENBLAS_NUM_THREADS=1 .tmp/xmp-analysis-venv/bin/python \
  Tools/LightroomComparison/Light/fit-spatial.py .tmp/xmp-research \
  .tmp/new-spatial-model.json .tmp/new-spatial-fit.json
OPENBLAS_NUM_THREADS=1 .tmp/xmp-analysis-venv/bin/python \
  Tools/LightroomComparison/Light/white-stats.py .tmp/xmp-research \
  .tmp/new-white-fit.json
```

`adaptive_data.py` validates registered reference hashes, decoded-source hashes,
shape, opacity, and finite samples. Reports retain a hash of every decoded array
actually consumed. `spatial-calibration.json` records the selected model and
alternative scores; the regenerated resource was verified numerically identical.
`whites-adaptation.json` retains the independent moment fit and radius selection.
No photograph or A10 response is loaded by either fitting command.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/adaptive-holdout-002 .tmp/xmp-research/runs/new-spatial \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --modes tonal adaptive \
  --case-id holdout-photo-Highlights2012--37 \
  --case-id holdout-photo-Shadows2012-17
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/user-a10-001 .tmp/xmp-research/runs/new-adaptive-a10 \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope partial --modes adaptive
```

`adaptive-measurements.json` contains actual public-API render evidence for all
new cases and the A10 comparison. New H/S improves all four photographic cases,
but the negative Highlights and negative Shadows colored cases regress. Positive
Whites improves all four new cases while retaining a large +75 residual. A10
p95 improves 0.081229 -> 0.042792 with the same other effects; Grain and other
unsupported stages remain excluded in both comparison stacks.

Rejected hypotheses remain in the local investigation evidence: pointwise H/S,
a simple Gaussian polynomial, a single-coefficient local-Laplacian approximation,
and two insufficiently general RBF fits. The retained model uses broader
synthetic scene coverage, never a photo-specific multiplier. The monotone-cubic
Whites extrapolation candidate was not adopted because its colored strong-setting
result regressed. These failures are evidence of remaining limits, not hidden
alternatives in the public renderer.

## Negative Highlights and Shadows

For Highlights, start from the public spatial response at −25 and −50.
The two inputs to the strength table are the average of the log-luminance
guide and the standard deviation of its narrowest blur. Each calibration
scene contributes one least-squares gain on the linear RGB change between
those two slider positions. The training set contains 24 synthetic scenes
and nine photographs. The nine other photographs and the A10 export are
evaluation inputs. The table is independent of the image being edited.

Regenerate the packaged 65×33 Float32 table from the frozen statistics.
The calibration file records the source, the −50 Lightroom reference, both
Brightroom anchors, and the image-level sampling and fit parameters.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/build-highlights-strength.py \
  .tmp/rebuilt-HighlightStrength.bin
```

To compare a photograph at both strengths, combine the original acquisition
with its crossed reference. The neutral export is paired by input hash.
Both sets retain the XMP and output ICC from their own registrations.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/photo-calibration-acquisition/acquisition-001 .tmp/xmp-research/runs/new-negative-highlights \
  --additional-references .tmp/camera-raw-goal/h37-crossed-reference-001 \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --modes adaptive --paired-neutral \
  --case-id photo-domain-012-Highlights2012--37 --case-id crossed-001-photo-domain-012-Highlights2012--50
```

Repeat with the matching −37/−50 IDs for the other 12 source hashes. In the
Lightroom triples, compare the observed −37 export to neutral plus 37/50 of
the linear RGB change from neutral to −50. The mean of the 13 image p95 values
was 0.002674. For Brightroom, taking that full linear path on every channel
failed the existing saturated green patch test. The public implementation uses
the fraction shared by all three linear RGB channels, min/max, to weight the
neutral-to-endpoint path. The remaining fraction follows the base and calibrated
color intervals. There are no new fitted coefficients. Public −37 photographic
p95 averaged 0.041818, down from 0.047821. The largest remaining −37 p95 was
0.094475. The [public measurements](../../../docs/highlights-shadows.md) include
the two photographic regressions and the A10 full-preset regression.

### Measuring the interaction between Light sliders

`measure-light-interactions.py` measures how the joint Lightroom export
differs from the sum of changes measured with disjoint controls on the same
input. Each change uses its acquisition's own neutral export. The tool
checks the source, requested settings, registered TIFFs, pixel grid and
active settings. It reports p95 in linear Display-P3 for two predictions.
One sums linear RGB changes. The other sums changes after sRGB encoding
and converts the result back to linear RGB.

```sh
light_set=.tmp/xmp-research/response-model-001
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-interactions.py \
  "$light_set/decoded" .tmp/light-interaction.json \
  --joint "$light_set" adjust-chart-tone adjust-chart-neutral \
  --part "$light_set" adjust-chart-hs adjust-chart-neutral \
  --part "$light_set" adjust-chart-wb adjust-chart-neutral
```

On the chart, the joint −35 Highlights, +42 Shadows, −18 Whites and +16 Blacks
export differed from the two groups summed in linear RGB by p95 0.003771.
At A10's settings, the difference between all five individual controls and
the joint Light export was 0.027196 on the chart and 0.007723 on the photograph.
The photograph used 375,000 positions on a regular 8-pixel grid. The corresponding
Brightroom difference measured 0.001395 with Highlights first and 0.002258 with
Shadows first. The joint and individual exports show
that a residual already exists within the Light panel. They do not identify
Adobe's evaluation order or which pair of sliders causes it.

Five fixed orders of the public features were compared on five chart
conditions. Two were then tested against two photographic settings with the
same camera image. Moving Whites/Blacks first gave the smallest mean chart
p95 but increased supplied full-A10 p95 from 0.049059 to 0.049154. Moving
Shadows before Highlights reduced it to 0.048452. It also reduced the photo's
Light-only errors from 0.008858 to 0.008012 at −11/+30 and from 0.020583 to
0.016460 at −35/+42. Both XMP adapters use that order. All the combined
photographic measurements here come from the same scene.

`fit-highlight-shadow-interaction.py` measures the two-slider response from
the original −35/+42 joint chart and the neutral, 10, 25 and 50 single-slider
charts. It sums linear-RGB changes in a candidate pair of strength intervals
and solves bounded least squares on all 262,144 pixels. The source TIFF,
settings, resolved controls, reference hashes and decoded color space are
checked. The fit uses only Lightroom outputs.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-shadow-interaction.py \
  .tmp/xmp-research/response-model-001 .tmp/xmp-research/adjustments-001
```

Summing individual Adobe edits gave effective strengths of −15.617625 and
+30.279711. The initial feature used that estimate for both stages. On the
five-control A10 photograph, those two engines' joint-minus-individual
responses differed by p95 0.003406, down from 0.005852.
[Public export results](../../../docs/highlights-shadows.md#joint-highlights-and-shadows)

The feature evaluates Shadows first. At the measured −35/+42 pair and above
each stage's anchor, the strengths are `S / (1 + 0.004924 * abs(H))` and
`H / (1 + 0.029549 * S)`. The separate Adobe sweeps determine the second
coefficient. To reproduce the first one,
render both public stages in sequence against the −35/+42 combined TIFF,
holding the second coefficient fixed. The same chart's alternating spatial
blocks check the fit. The photograph and A10 strength are excluded from
estimation. Both individual sliders retain their full strength at a zero
setting of the other slider.

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer
xcodebuild -project Dev/Brightroom.xcodeproj -scheme ParametricMacDemo \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .tmp/xmp-derived-data \
  -skipMacroValidation -skipPackagePluginValidation build
xcrun swiftc -O Tools/LightroomComparison/Light/decode.swift -o .tmp/decode-joint
OPENBLAS_NUM_THREADS=1 .tmp/xmp-analysis-venv/bin/python \
  Tools/LightroomComparison/Light/fit-sequential-shadow-lift.py \
  .tmp/xmp-research/response-model-001 .tmp/joint-shadow-fit.json \
  --products .tmp/xmp-derived-data/Build/Products/Debug --decoder .tmp/decode-joint
```

#### Weak Highlights with lifted Shadows

The registered two-pair chart also isolates the downstream Whites/Blacks
interaction. Run the comparison with the H/S part first. The optional
diagnostic samples the measured W/B color lattice at the H/S output.

```sh
study=.tmp/xmp-research/response-model-001
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-interactions.py \
  "$study/decoded" .tmp/sequential-points.json \
  --joint "$study" adjust-chart-tone adjust-chart-neutral \
  --part "$study" adjust-chart-hs adjust-chart-neutral \
  --part "$study" adjust-chart-wb adjust-chart-neutral --sequential-tonal-points
```

The A10 chart has separate exports of all five Light controls and one combined
export. Infer the input to its three point controls by inverting their measured
responses, then check the inferred image by applying them again. The report
also fits the fraction of each **linear-RGB change** in the H/S combination.
These fractions describe the measured pixel change and have no slider units.

```sh
study=.tmp/xmp-research/a10-001
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-interactions.py \
  "$study/decoded" .tmp/a10-inferred-light.json \
  --joint "$study" a10-chart-light a10-chart-neutral \
  --part "$study" a10-chart-light-highlights a10-chart-neutral \
  --part "$study" a10-chart-light-shadows a10-chart-neutral \
  --part "$study" a10-chart-light-whites a10-chart-neutral \
  --part "$study" a10-chart-light-blacks a10-chart-neutral \
  --part "$study" a10-chart-light-saturation a10-chart-neutral --infer-before-point-controls
```

For each of the two active stages below its measured anchor, the effective
magnitude is `amount * fraction / (fraction + attenuation * opposing)`, with
`fraction = min(1, amount / anchor)`. At −11/+30 this gives Highlights −2.879
and Shadows +27.885. Compare the public result through the registered neutral
and edited pairs, using the original signed XMP values and each reference's
embedded output ICC. [Public feature and measured results](../../../docs/highlights-shadows.md#weak-highlights-with-lifted-shadows)

### Negative Shadows and the −50 neighborhood calibration

Negative Shadows uses a shared encoded change at the pixel's linear-P3
luminance. Negative Highlights and Shadows then calibrate RGB span at −50.
The fit pairs each renderer's adjusted output with its own neutral export.
For each of four colored layouts and nine photographs, 18,000 pixels at most
are drawn with a repeatable seed from the input hash. The fit uses five evenly
spaced encoded-P3 luminance knots and one ridge penalty per control. The basis,
luminance floor, and penalties were selected by leaving one calibration source
out at a time. Nine additional photos and three additional colored layouts
are available for evaluation. [Public-feature results](../../../docs/highlights-shadows.md)

Regenerate the 25 Metal constants from the stored normal equations, or supply
the registered decoded pixels to independently reconstruct those equations.
The second command checks the input and setting association, the TIFF hashes,
and the decoded Brightroom baseline hashes before refitting.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-negative-tone-color.py \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal

.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-negative-tone-color.py \
  --public-decoded .tmp/camera-raw-goal/tonal-pyramid/base-001/decoded \
  --reference-set .tmp/camera-raw-goal/acquisition/synthetic-001 \
  --reference-set .tmp/camera-raw-goal/photo-calibration-acquisition/acquisition-001 \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

The −50 neighborhood fit adds an encoded change to the two output extrema.
Negative Highlights uses successive differences from the pixel to four local
averages and the scene mean. Negative Shadows uses the difference between
the pixel and the mean. The calibration uses the same 33 complete sources
as the Highlights strength table and up to 10,000 pixels per source. Use the
public baseline taken before the neighborhood correction to reproduce its 30
coefficients.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-tone-neighborhood.py \
  .tmp/camera-raw-goal/tonal-pyramid/base-001/cases.json \
  .tmp/camera-raw-goal/tonal-pyramid/base-001/decoded \
  .tmp/camera-raw-goal/rank-tone/decoded-gpu \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

### Negative slider strength

Use the registered `adaptive-002` and `adaptive-calibration-001` gray ramps
and the `adjustments-001` and `response-model-001` color charts. Decode each
16-bit ProPhoto TIFF set with `Light/decode.swift` first.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-negative-tone-strength.py \
  .tmp/xmp-research --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

Neutral and −50 are the ends of the measured interval. The fit uses the same
16,384 source positions in each chart's −10 and −25 exports. It follows the
source minimum and maximum channels in linear ProPhoto and weights errors by
their size in linear RGB. An angular coordinate for Highlights and a log-odds
coordinate for Shadows each have 32 intervals. Holding out each complete
chart to select the knot count and smoothness favored 32 intervals and a
penalty of 0.01. The script reproduces the resulting 66 knots with NumPy.

Use the photo-domain and crossed registrations for the subsequent −37 and −50
comparison. The independent −100 gray and color exports test extrapolation.
Feed the original TIFF and signed amounts to the public feature for deployment
metrics. A separate interpolation between Adobe's own neutral and −50 outputs
measures how accurately the strength curve predicts −37 given those endpoints.

### Luminance ranges at the negative endpoint

The blue component of each existing spatial guide carries a measurement of
encoded luminance. At −50, Highlights uses the distance below the midpoint
and Shadows uses the fraction below the brightest third with a linear transition
to white. Each has 35 coefficients fitted to paired Lightroom changes on 33
images. Image-wise cross-validation treats the grayscale, color-chart and
photographic groups equally.

Build the macOS product first. The following commands read its Metal kernels
and the decoded half-float public output from just before this correction.
The Python script selects up to 12,288 reproducible positions per source,
checks the paired captures and writes the measured coefficients to a new directory.

```sh
xcrun swiftc -O Tools/LightroomComparison/Light/capture-tone-range.swift \
  -o .tmp/capture-tone-range
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-tone-range.py \
  .tmp/camera-raw-goal/tonal-pyramid/base-001/cases.json \
  .tmp/camera-raw-goal/tone-range-guides/before/decoded \
  .tmp/capture-tone-range \
  .tmp/xmp-derived-data/Build/Products/Debug/Brightroom_BrightroomColorAdjustmentKernels.bundle/Contents/Resources/BrightroomColorAdjustments-macos.metallib \
  .tmp/rebuilt-tone-range \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

In the half-float public render, mean image p95 on the same 13 photos dropped
from 0.040472 to 0.038493 at Highlights −37 and from 0.052985 to 0.050280 at
−50. Nine of these photos contributed −50 calibration data. For the nine
photos excluded from fitting, Shadows −32 dropped from 0.012901 to 0.012460.
Shadows −50 on 36 charts went from 0.006378 to 0.006408; the supplied A10
TIFF comparison went from 0.046144 to 0.046474. These figures use each
pixel's largest absolute channel error in linear Display P3, with white at 1.

## Strong positive Whites

The +25 to +100 path uses the mean gray displacement as a common coordinate
for 32 measured RGB tables. The fixture layout, ordered calibration contexts,
registered pixel hashes, synthetic luminance summaries and slider law are in
`strong-whites-calibration.json`. The builder checks the forty registered
neutral and adjusted exports, then fits the scene weights. It uses a
shape-preserving cubic (PCHIP) for the RGB changes across displacement.
The candidate displacements include the measured strengths and 65 regularly
spaced samples. From these the builder selects 33 layers, one per chart
measurement including the identity, by minimizing the
integrated squared RGB interpolation error across the cube.
The GPU looks up the surrounding two layer indices once per input and strength.

The upper slider fit uses the measured +75 displacement `x` and the +100
displacement `y` from each of the eight chart backgrounds and two gray ramps.
The builder solves `y (1 + cx + dx²) = ax + bx²` by least squares and checks
that the resulting response increases over the packed displacement range.
The GPU evaluates this fit once per histogram. The RGB layers and their
positions are shared with the lower strengths.

When a measured linear ProPhoto channel reaches white, the builder extends
its last unsaturated slope by up to 1/64 of the measured displacement range.
Only a terminal white plateau preceded by two unsaturated measurements supplies
a slope. At every selected layer the builder takes the difference between
the extended and clipped interpolants of the two outer channels. This preserves
the measured P3 residuals. The runtime clamps the interpolated endpoints at
the pixel.

In each layer, sort the three linear ProPhoto RGB input channels. Colors with a
different channel order share two measured responses, the changes to the lowest
and highest channels. The builder fits each ordered grid node to its 48 nearest
measured colors using a weighted local quadratic in sRGB-encoded ProPhoto
coordinates. On the gray diagonal it interpolates the measured gray ramp.
The 63 levels include every one of the 32 original gray coordinates. Each layer
occupies 43,680 pairs of half-floats. Four tetrahedral vertices per layer
interpolate the two changes. The middle channel retains its position between the
outer channels in linear light. All training colors come from the registered
charts above.

`surroundRamp` and `darkRamp` record the source, XMP and exported TIFF
identities. The former samples the neutral and +100 rows of the gray patch
in `paired-surround-00`. The layout `paired-surround-01` and both layouts'
color patches are excluded from those measurements. The darker ramp reads
scanline 128 and reaches white by its highest authored input code of 0.6.
The builder uses the eight RGB contexts and two ramp endpoints to fit the
+100 displacement as a function of +75 displacement. The scene summaries
use an encoded-luminance Gaussian with sigma equal to the longer image
dimension divided by 512. The ratio of fine-detail variance to total variance
weights this smoothed signal. Sixteen overlapping brightness bins describe
how closely a source histogram matches a calibration scene. The `darkField75`
registration binds the measured +75 output on a constant 10% encoded gray
field. The builder extends the difference between the two measured gray
ramps until tetrahedral interpolation on that field reaches the measured
output. It checks the resulting gray level again after half-float packing.
The field supplies a local histogram anchor. Its additional color response
above the last measured ramp is extrapolated in linear ProPhoto RGB.
The `peakGray` records bind the five +100 gray
fields to their registered TIFFs and store their measured linear input and
output. The builder takes the median shoulder coefficient across those fields.

From the repository root, rebuild the resource in a new file with NumPy, SciPy and
the Apple toolchain installed.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/build-strong-whites.py \
  .tmp/camera-raw-goal/whites-context-acquisition/acquisition-001 \
  .tmp/rebuilt-StrongWhitesCalibration.lzfse
```

Run the public XMP path on the five evaluation photographs. The neutral
exports in this run also give the error of the adjustment itself after
subtracting each renderer's unadjusted pixels.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/acquisition/photographs-001 .tmp/xmp-research/runs/new-whites75 \
  --additional-references .tmp/xmp-research/adaptive-holdout-002 \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --modes adaptive --paired-neutral \
  --case-id photo-street-Whites2012-75 --case-id photo-portrait-Whites2012-75 \
  --case-id photo-color-Whites2012-75 --case-id photo-vertical-Whites2012-75 \
  --case-id holdout-photo-Whites2012-75
```

Replace the five case IDs' final `75` with `42` to compare the same sources at
the measured intermediate value, using a fresh output directory. For the
separate 24-megapixel +25 reference, use `whites-context-001` and
`--scope light --modes adaptive --case-id context-photo-Whites2012-25`.

The five photographic p95 values and the largest remaining chart errors are
documented with the feature. [Whites and Blacks](../../../docs/whites-blacks.md)

For a pixel-level rebuild of the spatial distributions and the white-point curve,
give the builder the decoded source TIFFs and the acquisition containing the five
uniform gray fields. It checks input, adjustment, reference hash and the measured
levels before packing the resource. For the darker ramp it reads the neutral
TIFF from the earlier acquisition named by the registered reused reference.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/build-strong-whites.py \
  .tmp/camera-raw-goal/whites-context-acquisition/acquisition-001 .tmp/rebuilt-verified-StrongWhites.lzfse \
  --distribution-inputs .tmp/camera-raw-goal/light-control-shapes/strength-path-002/decoded \
  --peak-references .tmp/camera-raw-goal/acquisition/synthetic-001
```

## Global Saturation and positive Shadows

Use `SaturationFeature(lightroomAmount:)` for the XMP `Saturation` slider.
`SaturationFeature(value:)` selects the original Core Image response. The measured
mode uses nine signed strengths on a 32³ encoded Display-P3 lattice. It takes
the linear luminance-based saturation response as a starting point and stores
the measured deviations. Cubic Hermite interpolation with PCHIP tangents selects
a strength. Tetrahedral interpolation then selects a color. This construction
preserves achromatic colors, alpha and a gray result at −100 between lattice
nodes. Extended-range pixels use the linear chroma response and the residual at
the boundary of the SDR cube. The calibration used opaque SDR TIFFs.

The two photographs in the following commands' saturation comparisons are the
same 24 MP scene at two settings. Neither setting entered the calibration.
Its +5 p95 fell from 0.000541 to 0.000239 and its −16 p95 from 0.001397 to
0.000204. The −16 chart fell from 0.049031 to 0.000550. Rebuild the resource
from registered chart exports with NumPy, SciPy and the system Foundation encoder.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/build-saturation.py \
  .tmp/xmp-research/adjustments-001 .tmp/xmp-research/response-model-001 \
  .tmp/rebuilt-saturation.bin .tmp/rebuilt-saturation.json
xcrun swift Tools/LightroomComparison/Light/compress.swift \
  .tmp/rebuilt-saturation.bin .tmp/rebuilt-saturation.lzfse
cmp .tmp/rebuilt-saturation.lzfse Sources/BrightroomParametric/Saturation/Resources/SaturationCalibration.lzfse
```

Positive Shadows uses the +10 and +25 gray-ramp changes relative to +50 at
nine input tones. At +50, one RGB cube and four registered calibration layouts
supply a chroma correction at fixed luminance. The runtime uses the luminance
lift, the change in channel span, and the largest channel lift. It interpolates
the two corrected channel extrema together and carries the +50 correction into
larger slider values. The independent +17 photographs went from mean p95
0.009431 to 0.008424. The two reserved +50 color layouts went from 0.016338
to 0.009461. At +100 the full color chart still has p95 0.137389.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-weak-shadows.py \
  .tmp/xmp-research/adaptive-002 .tmp/xmp-research/adaptive-calibration-001 \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-positive-shadow-color.py \
  .tmp/xmp-research/adjustments-001 \
  .tmp/camera-raw-goal/a10-effects/positive-shadows/color-registered/adjust-chart-neutral \
  .tmp/camera-raw-goal/a10-effects/positive-shadows/color-registered/adjust-chart-Shadows2012-50 \
  .tmp/camera-raw-goal/acquisition/synthetic-001 \
  .tmp/camera-raw-goal/a10-effects/positive-shadows/calibrated/half-decoded \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

The three public-output directories in the color fit contain 16-bit PNGs
decoded by `decode.swift` before adding the chroma correction. The first two
contain the cube's neutral and +50 exports, each named `brightroom.png`.
The last contains the source-ID-named layout exports. The script pairs these
with the hash-checked Lightroom TIFFs using the original calibration split.

## Negative Highlights and Shadows near Display P3 black

Use the registered ProPhoto RGB exports to check colors that darken past
the Display P3 boundary. The original 1024×256, 16-bit chart contains
two gray ramps and a 32³ Display P3 lattice. Supply the output profile
embedded in the reference through the regular XMP comparison.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/adjustments-001 .tmp/xmp-research/runs/negative-light-gamut \
  --scope light --modes adaptive-no-grain \
  --case-id adjust-chart-Highlights2012--50 --case-id adjust-chart-Highlights2012--100 \
  --case-id adjust-chart-Shadows2012--50 --case-id adjust-chart-Shadows2012--100
```

The `belowDisplayP3Black` field in each case's metrics counts reference
pixels below −0.001 and measures the error of the minimum channel there.
At −100 these rows contain 37,670 pixels for Highlights and 32,466 for
Shadows. In half-float rendering their minimum-channel p95 went from
0.115384 to 0.078645 and 0.043982 to 0.032396. On those same pixels the
largest RGB channel error at p95 went from 0.144762 to 0.139978 for
Highlights and from 0.159547 to 0.159555 for Shadows. Whole-chart RGB p95
went from 0.134346 to 0.132345 and from 0.098267 to 0.098267, respectively.

The iOS public-API fixture also checks the mean red channel over 256 cyan
patches. In top-down source coordinates, sample `x = 32 × green` and
`y = 128 + 4 × blue` with both indices in `16..<32`. Lightroom's means are
−0.067050 and −0.036896 in linear P3. The full-chart statistic and the
color-specific statistic describe different parts of the image.

## Highlight color response

The color fit uses paired −50 and neutral Lightroom exports on four calibration
layouts and nine photographs. It reads the public half-float output captured
before adding this correction. Distribute each source's samples equally within
its group. Resample the production luminance guide on the same pixels, then
fit the remaining error in encoded luminance. The runtime builds one 33×33
gain table per scene from that fit. The signed XMP amount, source pixels and
scene statistics are the inputs to the public rendering path.

Run from the repository root with a macOS build of BrightroomParametric. The
Python environment needs NumPy, SciPy and Pillow. The decoder and capture
programs use the local Core Image implementation. Use a fresh output directory.

```sh
xcrun swiftc -O Tools/LightroomComparison/Light/decode.swift -o .tmp/decode-light
xcrun swiftc -O Tools/LightroomComparison/Light/capture-tone-range.swift -o .tmp/capture-tone-range
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-color-gain.py \
  .tmp/camera-raw-goal/tonal-pyramid/base-001/cases.json \
  .tmp/camera-raw-goal/tone-meter-color/boundary/half \
  .tmp/decode-light .tmp/capture-tone-range \
  .tmp/xmp-derived-data/Build/Products/Debug/Brightroom_BrightroomColorAdjustmentKernels.bundle/Contents/Resources/BrightroomColorAdjustments-macos.metallib \
  .tmp/rebuilt-highlight-color --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

The published product uses the previously measured −25 endpoint and a common
monotone slider coordinate through the corrected −50. Applying the endpoint
gain all the way down to zero increased p95 for the supplied A10 from
0.046474 to 0.047977. On 13 paired photographs the fixed endpoints reduced
half-float p95 from 0.038491 to 0.031620 at −37 and from 0.050278 to 0.041845
at −50. Twelve photographs improved and the thirteenth had the same p95 at
both strengths. The four photos excluded from fitting averaged 0.043003 at
−50. A similar Shadows fit at −50 increased error at −32 on nine evaluation
photos from 0.012460 to 0.012595, so the existing Shadows model is retained.

Beyond −50, the residual change in chroma on the RGB cube supplies three
coefficients. Use the public −50 and −100 images captured immediately before
adding these coefficients, decoded with the same program. The script checks
the source, XMP settings, reference output profile and whole-chart p95. It
uses one position for each of the 32,768 source codes. Four held-out blocks of
colors each improved at −100 in the incremental fit. The complete −100
chart in the final public export measured 0.082813, previously 0.132345. There
is no independent photographic reference for this strongest chroma correction.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-strong-highlight-chroma.py \
  .tmp/xmp-research/adjustments-001 \
  .tmp/camera-raw-goal/local-contrast/patch-measurements/spec.json \
  .tmp/camera-raw-goal/local-contrast/pre-strong/linear \
  .tmp/camera-raw-goal/local-contrast/final-gamut/half/metrics.json \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

## Positive Whites headroom

The +75 displacement estimate uses the mean headroom in linear light, the
headroom in the bright part of the distribution, and its relative mass.
The public kernel derives them from the existing histogram. Its maximum
blend in log displacement is one quarter, attenuated by the confidence of
the measured scene response and by overlap between histogram bins four
steps apart. The 17 synthetic scenes are the inputs to the coefficient fit.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-whites-headroom.py \
  Tools/LightroomComparison/Light/strong-whites-calibration.json \
  --check Sources/BrightroomColorAdjustmentKernels/ColorMixerCalibrationKernels.metal
```

Across five photographs, half-float mean p95 fell from 0.003531 to 0.003109
at +42 and from 0.020488 to 0.018486 at +75. The +75 chart mean rose from
0.006128 to 0.006209. On the 21 +100 charts it fell from 0.005566 to 0.005467.

The same fitting command also selects the flat-region histogram parameters.
It withholds each synthetic source and then its entire layout family. Capping
each of 16 interval masses at 0.025, renormalizing, and raising the affinity
to the power of 32 took the mean absolute log displacement error from 0.1737
to 0.1304 across those folds. The GPU blends this estimate into the ordinary
one in proportion to the luminance variance contributed by flat regions.
Flat samples match their four cardinal guide neighbors to within one 16-bit
code of straight encoded luminance. A single uniform region contributes no
between-region variance.

Replay the two validation layouts and their own neutral exports using the
registered 16-bit Lightroom TIFFs. Supply an unused output directory.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/acquisition/synthetic-001 .tmp/xmp-research/runs/replay-whites-flat-layouts \
  --additional-references .tmp/camera-raw-goal/whites-context-acquisition/acquisition-001 \
  --scope light --modes adaptive --paired-neutral \
  --case-id paired-surround-01-Whites2012-75 --case-id paired-surround-01-Whites2012-100 \
  --case-id whites-context-bimodal-diagonal-Whites2012-75 --case-id whites-context-bimodal-diagonal-Whites2012-100 \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

The half-float whole-frame +100 p95 fell from 0.034059 to 0.011898 on the
diagonal and from 0.022098 to 0.004423 on the paired surround. The +75
five-photo mean rose from 0.018486 to 0.018501. The original 32³-color chart
in `adjustments-001` remained at 0.105690 for +100. A separate diagnostic
estimated strength from its measured +50 and obtained 0.010913 at +100.
Only the ordinary source-only render measures production behavior.

### Colored highlights in positive Whites

The guide samples straight RGB in linear ProPhoto and encodes its largest
channel with the same transfer function as the 32-node calibration grid.
For both that channel and luminance, the interpolation weight in the last
interval is `clamp(1 + 31 × (code − 1), 0, 1)`. The guide averages the
positive difference, weighted by alpha. An achromatic white contributes zero.
Up to the largest coverage in the 17 synthetic calibration images (0.002486),
the existing luminance estimate determines the strength. At the coverage of
the original 32³ lattice (0.009944), the multiplier on the estimated +75
displacement reaches 0.846. It stays at that value for larger coverages.
The +50 neutral-ramp displacements of the colored chart and an equal-luminance
grayscale version determine the multiplier through the existing amount law.

Use the registered `adjustments-001` references and decoded source TIFFs
from the earlier calibration. The source directories hold manifests from
`decode.swift`. The fitter identifies the 17 inputs by SHA-256 and also
requires the source of the neutral and +50 color-lattice exports. Compile the
gray probe with the same macOS build products as the comparison renderer.

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer
products="$PWD/.tmp/xmp-derived-data/Build/Products/Debug"
study=.tmp/camera-raw-goal
work=$(mktemp -d .tmp/whites-replay.XXXXXX)
xcrun swiftc -O -I "$products" Tools/LightroomComparison/Light/whites-gray-ramp.swift \
  "$products/BrightroomParametric.o" "$products/BrightroomColorAdjustmentKernels.o" \
  -o "$work/whites-gray-ramp"
PACKAGE_RESOURCE_BUNDLE_PATH="$products" .tmp/xmp-analysis-venv/bin/python \
  Tools/LightroomComparison/Light/fit-whites-channel-headroom.py .tmp/xmp-research/adjustments-001 \
  --decoded-inputs "$study/light-control-shapes/strength-path-002/decoded" "$study/whites-channel-headroom/sources" \
  --gray-probe "$work/whites-gray-ramp" --check Sources/BrightroomColorAdjustmentKernels/ColorMixerCalibrationKernels.metal

.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/adjustments-001 "$work/comparison" \
  --additional-references "$study/acquisition/photographs-001" \
  --scope light --modes adaptive --paired-neutral --include-calibration \
  --case-id adjust-chart-Whites2012-50 --case-id adjust-chart-Whites2012-100 \
  --case-id photo-color-Whites2012-42 --case-id photo-color-Whites2012-75 \
  --developer-dir "$DEVELOPER_DIR"
```

The coefficient uses the lattice's +50 export. Other strengths on this
input and every photographic export were reserved for evaluation of this
coefficient. Full-frame public macOS half-float p95 on the lattice dropped
from 0.105690 to 0.010831 at +100. On the separate balloon photo it dropped
from 0.023323 to 0.002725 at +75. The other four +75 photo renders were
pixel-identical to their previous versions. These five photos are recurring
validation inputs. Four other photographs have registered Lightroom neutral, +75 and +100 references.
[Measured photographic differences](../../../docs/whites-blacks.md#positive-whites-at-100)

### Measuring the closest public slider value

`measure-light-slider.py` takes an `A10/run.py` report made with
`--scope light --modes adaptive --paired-neutral`. Each selected case
must isolate one integer Whites, Blacks, Highlights or Shadows setting.
It renders the same developed input and ICC at all 101 integer values
from zero through the signed end of the public slider. The original
setting and zero must reproduce the recorded Brightroom pixels exactly.

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-slider.py \
  .tmp/xmp-research/runs/photographic-whites-tail-floor/report.json .tmp/whites-slider-comparison \
  --case-id strong-photo-domain-011-Whites2012-100 \
  --case-id strong-photo-domain-012-Whites2012-100 \
  --case-id strong-photo-domain-013-Whites2012-100 \
  --case-id strong-photo-domain-014-Whites2012-100
```

A deterministic sample of up to 8,192 pixels selects the closest setting
by p95 maximum RGB error in linear Display P3. The report also measures
a disjoint sample and the whole image, including the adjustment relative
to the paired neutral. The original XMP value is favored on an exact tie.
The exported `closest.png` uses the reference to select a value for this
photograph. The public feature continues to use the caller's authored value.

For positive Whites, `upperWhitesTransitions` measures the same check pixels
at each adjacent integer from +75 to +100. Each step records the largest
decrease of any RGB channel and the number of pixels where a channel fell
by more than 0.0001 in linear Display P3. A pixel counts once per step.
These values describe Brightroom's slider response within one input.

### Photographic Whites at +75 and +100

Run the standard XMP adapter with the original four-photo registration and
the additional Whites +75 exports. This compares all 20 registered images,
including neutral and Highlights, using their shared 16-bit ProPhoto RGB profile.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/strong-highlight-interval/acquisition .tmp/xmp-research/runs/whites-decile-balance \
  --additional-references .tmp/camera-raw-goal/whites-photo-interval \
  --scope light --modes adaptive --paired-neutral \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

Choose a new output directory for each build. The slider sweep above takes
the resulting report and verifies the same build's authored and neutral pixels.

The `photographicTails` entries in `strong-whites-calibration.json` record
the source, XMP and Adobe TIFF hashes for the five fit photographs. Each
entry gives the source quantiles, the combined texture, histogram-confidence
and colored-highlight weight, the previous +75 displacement and the
displacement fitted on 8,192 Adobe pixels. The first coefficient fits the
log ratio of these displacements using the 1% and 5% boundaries. Three
photographs have zero contribution to this first term. The second coefficient
fits the remaining error using the mean of each outer 5%, the median and the
variance of the same 128-bin histogram. Divide a boundary bin's population
at exactly 5% when computing the two tail means. The four evaluation
photographs are named in the [results](../../../docs/whites-blacks.md#measuring-the-brightest-and-darkest-5).
The fitter repeats both steps on the same five observations with the first
term divided by `1 + 2 × |outer imbalance| / remaining headroom`. The Metal
kernel blends these two fits when the 10th and 90th percentiles show less
asymmetry than the 5th and 95th. The additional two gains use no +100 exports.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-whites-headroom.py \
  Tools/LightroomComparison/Light/strong-whites-calibration.json \
  --check Sources/BrightroomColorAdjustmentKernels/ColorMixerCalibrationKernels.metal
```

Compare the *change between settings* from two registered public renders
and their Lightroom references. Pass the same report twice if it contains
both settings. The command verifies the source, XMP, output profile and
neutral pixels, then reports whole-image and neutral-luminance-band p95
for the signed RGB change in linear Display P3. The optional error bound
checks the two endpoint responses and their interval separately on every pair.
The four registered photographs below use a bound of 0.010.

```sh
report=.tmp/xmp-research/runs/whites-decile-balance/report.json
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-whites-interval.py \
  "$report" "$report" --maximum-p95 0.010 \
  --pair strong-photo-domain-011-Whites2012-75 strong-photo-domain-011-Whites2012-100 \
  --pair strong-photo-domain-012-Whites2012-75 strong-photo-domain-012-Whites2012-100 \
  --pair strong-photo-domain-013-Whites2012-75 strong-photo-domain-013-Whites2012-100 \
  --pair strong-photo-domain-014-Whites2012-75 strong-photo-domain-014-Whites2012-100
```

## Shadow color response

The −50 endpoint fit uses nine photographs, four color layouts and the native
32³ Display-P3 color lattice. It estimates two contributions to the missing RGB
loss, one along the spatial model's predicted loss and one along the source RGB.
Five scene centers are clustered from the mean and standard deviation of the
source log luminance. Four encoded luminance knots interpolate the coefficients.
A scene far from these centers receives less correction. Each render precomputes
16 texels for the full-resolution kernel. The fit uses each engine's signed
change from its own neutral on the same source and output ICC.

The comparison exports linear Display-P3 RGB through the Lightroom reference's
ICC. The error is each pixel's maximum absolute RGB channel error, then the 95th
percentile within each image. Photographs have equal weight in the reported
averages. macOS half-float results for the previous and current implementations
are shown below.

| Source and signed Shadows amount | Previous | Current |
| --- | ---: | ---: |
| Nine calibration photographs at −50 | 0.021050 | 0.016863 |
| Nine photographs outside the fit at −32 | 0.012460 | 0.011857 |
| Full chart at −10 | 0.009847 | 0.008099 |
| Full chart at −25 | 0.025049 | 0.018796 |
| Full chart at −50 | 0.052250 | 0.036607 |
| Full chart at −100 | 0.098267 | 0.071051 |

The −32 photographs have also been used to evaluate earlier versions. Eight
improved. One went from 0.004727 to 0.006493. Grayscale output was identical
in all 33 signed settings in both working formats for that −50 endpoint change.
The following strong-interval calibration addresses the remaining cyan error.

To reproduce the endpoint, compile `capture-tone-range.swift` and `decode.swift`
with the macOS SDK. The baseline paths below contain the previous public output.
The fitter verifies inputs, settings, TIFF and ICC identity, the paired neutral,
and a full-image baseline score before sampling.

```sh
study=.tmp/camera-raw-goal/shadow-channel-response
previous=.tmp/camera-raw-goal/local-contrast
kernels=.tmp/xmp-derived-data/Build/Products/Debug/Brightroom_BrightroomColorAdjustmentKernels.bundle/Contents/Resources
xcrun swiftc -O Tools/LightroomComparison/Light/capture-tone-range.swift -o "$study/capture-source"
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-shadow-color-response.py \
  .tmp/camera-raw-goal/tonal-pyramid/base-001/cases.json "$previous/response/half" \
  .tmp/xmp-research/adjustments-001 "$study/cube" "$previous/response-gamut/half/metrics.json" \
  .tmp/camera-raw-goal/a10-effects/decode-full-chart "$study/capture-source" \
  "$kernels/BrightroomColorAdjustments-macos.metallib" "$study/refit-new" \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

### Strong negative Shadows

The strong-interval color correction uses the original linear-P3 RGB span.
To refit its single gain, render the same 32³ lattice at 0, −50 and −100
with the pre-correction public feature. Render −100 twice more with
`gain += delta * span` immediately before the existing hue gain scales
the additional loss, using `delta` of −0.125 and +0.125. Use the registered
ProPhoto ICC for all five outputs. Decode into extended-linear Display P3
and take the first scanline of each four-row color strip at rows 128…255.

Save the row-major pixel indices as `indices` and the five RGB arrays
as `source`, `half`, `full`, `less` and `more` in an NPZ file. Its JSON
manifest names the file in `sample`, its SHA-256 in `sha256`, the chart's
registration directory in `registration`, and the input, ICC and baseline
Metal library hashes in `source`, `icc` and `baseline`. Set `delta` to 0.125
and supply the registered TIFF hashes in `reference` under `0`, `-50`
and `-100`. Run the following command with the analysis environment.

```bash
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-strong-shadow-color.py path/to/manifest.json
```

The fit gives equal weight to the error from neutral and the error from
−50 at each color. It increases the weight of colors with a larger native
−100 error and regularizes the single gain toward zero. All four photographs
are excluded from the coefficient estimate.

Use the neutral, −10, −25 and −50 ProPhoto exports of the grayscale ramp and the
32³ color lattice. The common log-odds coordinate uses black and white limits
fitted in linear ProPhoto RGB. These finite limits keep bright cyan close to its
measured −50 color as Shadows approaches −100. On the lattice, the public −10
and −25 renders and the registered −25 reference determine two endpoint gains
at three luminance knots in six hue directions. The fitter verifies the source,
XMP, embedded ICC and public baseline p95. It uses NumPy, SciPy and Pillow.

```sh
study=.tmp/camera-raw-goal/shadow-strength-transfer
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-strong-shadows.py \
  .tmp/xmp-research "$study/patches-mac/spec.json" "$study/decoded-macAfter" \
  "$study/product-gamut/half/metrics.json" \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal

.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/adjustments-001 .tmp/xmp-research/runs/new-strong-shadows \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --modes adaptive --case-id adjust-chart-Shadows2012--100 \
  --paired-neutral --middle-channel-error
```

The −100 exports are evaluation strengths. On the half-precision public path,
the saturated cyan p95 fell from 0.102871 to 0.031540, the full chart from
0.071051 to 0.069025, and the separate gray ramp from 0.014702 to 0.014508.
Across 12 strengths and 262,144 pixels the largest sampled upward step after
export was below 0.000065 in half precision and 0.000045 in single precision.
The strongest saturated reds retain visible error. Photographic comparisons
currently cover Shadows −32 and −50.

### Source-color neighborhoods

Use the unmodified public negative-Light output, its neutral PNG and the
registered Lightroom TIFFs to estimate how the spatial response varies among
nearby pixels of similar color. The calibration manifest identifies 33 source
hashes. Nine photographs and 24 synthetic inputs contribute equal weight as
groups. Both controls use the same −50 split. The fit checks both absolute
and neutral-subtracted whole-frame p95 against the baseline ledger before
taking a regular sample for the bandwidth search.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-tone-color-neighborhood.py \
  .tmp/camera-raw-goal/tonal-pyramid/base-001/cases.json \
  .tmp/camera-raw-goal/whites-channel-headroom/signed-half/scores.json \
  .tmp/camera-raw-goal/conditional-tone/native/*
```

The selected standard deviations in encoded P3 RGB are 1/8 for Highlights
and 1/16 for Shadows. The guide measures linear luminance loss. At −50,
native runs screened encoded and linear loss, uniform and channel-relative
Highlights corrections, and gain values 1, 1.5 and 2. The chosen gain of 1.5
minimized the family-weighted mean log p95 ratio for both controls. Slider
endpoints, flat fields, wide gamut and weak-slider ratios are checked on the
public iOS features. The per-source ledger records regressions as well as
improvements.

To measure both strengths on the same photographs through the XMP adapter,
use a fresh destination directory. The two registrations contain 13 matching
photographs and also include independent Shadows settings.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/photo-calibration-acquisition/acquisition-001 \
  .tmp/xmp-research/runs/negative-neighborhood-check \
  --additional-references .tmp/camera-raw-goal/h37-crossed-reference-001 \
  --scope light --include-calibration --paired-neutral --modes adaptive \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

### Negative Highlights peak coverage

The −50 fit uses the same 33 registered inputs as the source-color
neighborhood fit. The 24 charts comprise 20 grayscale layouts and four color
layouts. Nine photographs form the third family. The measured quantity is
the difference between each engine's change from its own neutral output in
extended-linear Display P3. Four native renders per calibration source
perturb the pre-strength encoded response by ±0.0125 in the luminance and
RGB-span directions. They measure the sensitivity of the exported pixels
through the actual slider and gamut code. The 12 basis values combine three
source-luminance knots with nearer/farther brighter/darker peak coverage.

To reproduce the 24 shader coefficients from the retained measurements in
this checkout, run from the repository root.

```sh
study=.tmp/camera-raw-goal
field=$study/highlight-tone-field
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-peak-coverage.py \
  "$study/conditional-tone/baseline.json" "$study/conditional-tone/product-mac-half-all/scores.json" \
  "$field/index.json" "$field/probe-manifest.json" \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

The case and image ledgers identify the original input, signed XMP, embedded
output profile, neutral and adjusted Adobe TIFFs, pre-change native PNGs and
the four measured probe arrays. The script checks the fixed source split,
native whole-frame absolute and paired p95, and the hashes of the probe
kernels and arrays before solving. The measurements and private source
images live in the local study directory.

The weak-strength fit used nine of the paired photographs at −37. Run the
paired XMP comparison in the preceding section with a new output directory
to measure all 13 photographs at both strengths. To check interaction with
the user's preset, run the following comparison with the original Apple
RAW-developed TIFF and the registered Lightroom export. Both Brightroom
modes use the same grain-containing Lightroom reference.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/user-a10-authored-002 .tmp/xmp-research/runs/a10-peak-coverage-check \
  --scope partial --modes adaptive adaptive-no-grain \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

### Strong negative Highlights

The two original charts supply neutral, −10, −25 and −50 exports for the
ProPhoto strength coordinate. The 33 previously registered −50 calibration
sources and the original color lattice supply the endpoint fit. For each
source, the fitter renders neutral, −50 and −100 with the archived public
macOS feature. It checks the whole −50 image against the previous decoded
RGB hash and both the absolute and paired-neutral p95. It samples the same
10,000 source positions in each of those outputs and the neutral and −50
Lightroom exports. The target is an extrapolation of Lightroom's measured
−50 response. Direct −75 and −100 photo outputs are reserved for evaluation.

Refit the strength bounds and the 84 endpoint weights from the original
captures and the preceding kernel in this checkout. The command requires a Mac GPU,
the local research files, NumPy, SciPy and Pillow.

```sh
study=.tmp/camera-raw-goal
strong=$study/strong-highlight-interval
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-strong-highlights.py \
  .tmp/xmp-research "$study/conditional-tone/baseline.json" \
  "$study/highlight-tone-field/release/product-mac-half-all/scores.json" \
  "$strong/before-mac/render" "$strong/before-mac" "$study/a10-effects/decode-full-chart" \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

For near-neutral colors in textured scenes, the full endpoint also uses the
second luminance step predicted by neutral and −50. The fraction of log-luminance
variance removed by the first Gaussian blur measures the image's fine detail.
Smooth gray ramps retain their measured shoulder. The two original −100 charts
served as regression checks when selecting this weight.

Negative Highlights reconstructs color around the spatial model's luminance.
Fit the black and white bounds for the common ProPhoto odds multiplier from the
registered neutral and −50 color pairs with the following command. Each pair
retains its original hue line. The fit compares its predicted and measured color
separation in linear P3. The full-resolution kernel uses half the correction
within 1% of the input span. For larger differences it retains at most 0.5%
of the span as uncertainty. Near P3 black it anchors the same odds change at
the spatially adjusted ProPhoto peak.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-color-separation.py \
  .tmp/camera-raw-goal/conditional-tone/baseline.json
```

The independent four-photo acquisition pairs neutral with Highlights −75,
Highlights −100 and Whites +100 in the same 16-bit ProPhoto output profile.
To check an implementation against all 16 TIFFs with the current XMP adapter,
supply a fresh output directory.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/strong-highlight-interval/acquisition .tmp/xmp-research/runs/check-strong-light \
  --scope light --modes adaptive --paired-neutral \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

### Measuring the strong Highlights interval

Use a neutral export and the same photograph at both −50 and −100. Measure the
signed change from neutral and the additional change from −50. Improving one
endpoint can increase the error in the second step.

```sh
study=.tmp/camera-raw-goal/highlight-interval-shape
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/light_interval.py \
  "$study/xmp-crossed/report.json" "$study/xmp-strong/report.json" --control Highlights2012 \
  --pair crossed-001-photo-domain-012-Highlights2012--50 strong-photo-domain-012-Highlights2012--75 \
  --pair crossed-001-photo-domain-012-Highlights2012--50 strong-photo-domain-012-Highlights2012--100
```

The command verifies both XMP values, the shared input, embedded output
profile and neutral pixels. It reproduces the registered single-setting
errors before subtracting the two signed responses pixel by pixel.
`interval.p95` measures that difference. `projectedStrongerP95` measures
two predictions of the stronger setting. Both continue the weaker change
in log odds at each source ProPhoto extremum. One uses the measured weaker
Lightroom output, the other uses the weaker public Brightroom output.
Only the former has access to any adjusted Adobe pixels when predicting.
All errors use the largest absolute channel difference in linear Display P3,
with white equal to one. Repeat `--pair` for additional photographs.
`--maximum-p95` applies to the two directly rendered responses and their
interval. [Photo, chart and full-preset results](../../../.tmp/camera-raw-goal/2026-11-13-highlights-wide-tones.md)

```sh
study=.tmp/camera-raw-goal/negative-light-color-axes
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-interval-gain.py \
  "$study/calibration/manifest.json" --leave-one-out
```

Each manifest entry identifies one calibration input and the SHA-256 of its
NumPy capture. Each sampled row has the same pixel index in the public neutral,
−50 and −100 renders and the corresponding Lightroom exports. The capture
also holds public −100 renders with the spatial interval gain perturbed by ±0.15,
and three standard deviations of log luminance from the GPU guide. These measure
the scene, the scene after the smallest blur, and the broad neighborhood.
The fitted gain scales the spatial loss before the textured-gray and gamut steps.
The paired captures and the two independent evaluation photographs are listed
in the [calibration and validation report](../../../.tmp/camera-raw-goal/2026-11-13-negative-light-color-axes.md).

Add `--response-axes` to a paired XMP comparison to locate the remaining
error. The comparator uses the candidate's neutral RGB to define the original
hue direction. It projects the signed RGB error onto luminance, change along
that hue, and change across it. The two color components preserve luminance.
Their p95 values use pixels with a neutral RGB channel span greater than 0.02.
The luminance p95 includes every pixel. Each percentile is calculated separately.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/adjustments-001 .tmp/xmp-research/runs/my-negative-light-axes \
  --scope light --modes adaptive --paired-neutral --response-axes \
  --case-id adjust-chart-Highlights2012--100 --case-id adjust-chart-Shadows2012--100 \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

### Spatial variation at identical source colors

After a paired Light run, compare the same 16-bit source code at two locations
in a photograph. The command reads the original pixel bytes through ImageIO,
checks the input, signed XMP, ICC, adjusted and neutral exports, and reproduces
the two whole-image p95 measurements before comparing neighborhoods. It needs
macOS, Xcode, NumPy, Pillow and SciPy.

```sh
study=.tmp/camera-raw-goal/photo-calibration-acquisition/acquisition-001
run=.tmp/xmp-research/runs/check-shadow-context
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py "$study" "$run" \
  --scope light --case-id photo-domain-012-Shadows2012--32 --modes adaptive --paired-neutral \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-context.py \
  "$run/report.json" --case-id photo-domain-012-Shadows2012--32
```

For each distinct source color with neutral luminance between 0.015 and 0.90,
the diagnostic selects its darkest and brightest surrounding regions in the
same image. It measures Gaussian radii of 16 and 64 pixels per 1024 pixels of
long edge on a guide of at most 256 pixels. A pair must differ by more than 0.03
in normalized log luminance, equivalent to a geometric-mean luminance ratio
over 1.32 above the black floor. Each source code contributes at most one pair
per radius. The reported effect is the difference in neutral-minus-adjusted
linear P3 luminance between the two positions. The output gives each engine's
spread, the p95 of their paired discrepancies, and the number of qualifying
colors. Some photographs have few or zero qualifying pairs.

### Negative Highlights at the same input luminance

To measure the bright side of a dark edge, add the source luminance to a
registered paired comparison. Several `--edge-luminance` values can be supplied.

```sh
run=.tmp/xmp-research/runs/highlight-edge-final-crossed
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-context.py \
  "$run/report.json" --case-id crossed-001-photo-domain-012-Highlights2012--50 \
  --edge-luminance .55
```

The selection uses the original developed input's linear Display P3 luminance
within ±0.005 of the specified level. A region qualifies as dark when the
brightest pixel in a square neighborhood (five pixels at a 1024-pixel long
edge) is at least 0.16 lower in encoded luminance. Distances are reported in
pixels per 1024 pixels of long edge. For each band, the output records the
pixel count, each renderer's median neutral-minus-adjusted luminance, and the
error between their losses at corresponding pixels. A band can be empty.
These measurements describe variations within one photograph. The equal-RGB
pair counts above provide a separate check on the influence of surroundings.

The negative Highlights implementation mixes the local −50 luminance loss
with the mean loss at the same input tone across the image. To reproduce the
choice of maximum share, its dependence on image detail, and the amount to
retain at a bright edge, run both fits.

```sh
study=.tmp/camera-raw-goal/highlight-edge-response
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-scene-loss.py \
  "$study/confidence/calibration.json"
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-edge-loss.py \
  "$study/edge-fit/calibration.json"
```

Each capture contains a public neutral render, the previous Highlights output,
a render at 35% sharing, the two corresponding Lightroom exports and GPU guide
statistics at the same encoded pixel positions. The manifest checks their
SHA-256 digests. The fit used 34 inputs at −50, comprising nine photographs,
24 synthetic scenes and the original color lattice. Four additional photographs
and the −37, −75 and −100 strengths were excluded from this fit.

The second fit uses the same 34 inputs. Each capture retains the signed
RGB change from sharing, both engines' paired response error, the means of
the four Gaussian guides, and the distance band at the same source location.
For the fit, encoded source luminance is grouped in 0.05-wide bins and dark
regions are identified relative to each bin's center. The fit measures each
image's whole-frame RGB p95 and its luminance p95 at bright-side distances of
4–16, 16–64 and 64–256 pixels per 1024. It selects the guide radius, contrast
direction and amount of local loss to retain. The diagnostic above can select
a narrower range of linear luminance when inspecting an individual photograph.
[Calibration, edge distances and whole-image comparisons](../../../.tmp/camera-raw-goal/2026-11-13-highlight-scene-loss.md)

### Comparing two negative Shadows settings on the same photograph

Render both settings with `A10/run.py --scope light --modes adaptive --paired-neutral`.
Use separate runs when the registrations have separate neutral exports for the same
input. Supply a weak and a strong case for each photograph. For the acquired
−32 and −100 pairs, this example measures the boat and the plant.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-shadow-interval.py \
  .tmp/xmp-research/runs/shadow-tone-final-weak/report.json \
  .tmp/xmp-research/runs/shadow-tone-final-strong/report.json \
  --pair photo-domain-013-Shadows2012--32 atmosphere-013-Shadows2012--100 \
  --pair photo-domain-014-Shadows2012--32 atmosphere-014-Shadows2012--100
```

The tool checks source, XMP, profile, public render and neutral provenance, then
recomputes the original whole-image p95s from the 16-bit files. It estimates a
shared log-odds change from the low and high linear ProPhoto RGB channels of the
weak export, scales it by the ratio of slider amounts and applies it to the
strong case's own neutral. The black and white limits come from
`fit-strong-shadows.py`. These predictions are diagnostics that use a weaker
export as input. The public feature takes only the source image and slider value.

The four reported p95s use the maximum absolute RGB-channel error per pixel in
linear Display P3. `fromMeasuredWeakerSetting` uses the weaker Lightroom output,
and `fromNativeWeakerSetting` uses the weaker Brightroom output.
`publicStrongerSetting` measures the actual strong Brightroom response from
neutral. `publicIntervalOnly` measures the additional change between the two
settings, with each render's own neutral subtracted.

### Negative Shadows near bright regions

The paired report made by `A10/run.py --scope light --modes adaptive --paired-neutral`
can also measure the dark side of a bright edge. Select source luminance in
linear Display P3. Each band includes source pixels within ±0.005 of that level.

```sh
run=.tmp/xmp-research/runs/shadow-boundary-strong
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-context.py \
  "$run/report.json" --case-id atmosphere-013-Shadows2012--100 \
  --bright-edge-luminance .05 --bright-edge-luminance .10
```

A bright region starts where the entire analysis window exceeds the target
by 0.16 in encoded luminance. A single bright pixel in a darker neighborhood
therefore does not set the distance. The distance bands and error measures
are the same as for `--edge-luminance` above. `medianExcessLoss` is positive
where Brightroom darkens more than Lightroom. Tone-matched pixels may have
different RGB values. The `neighborhoods` entries separately compare pairs
with identical source RGB codes.

To reproduce the two coefficients used by the negative Shadows endpoint, run
the paired −50 calibration. The manifest includes only the 34 calibration
sources. It identifies the baseline Metal library and each capture by SHA-256.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-shadow-edge-loss.py \
  .tmp/camera-raw-goal/shadow-boundary-response/calibration.json
```

The fit uses the previous public neutral and −50 outputs, both Lightroom
exports, and the local GPU guide moments at matching pixel indices. It fits
dark-tone and low-variance contrast terms against the luminance residual.
The canonical runs separately measure the resulting public feature at full
image resolution, including −32 and −100 on other photographs.
[Comparison images and measurements](../../../.tmp/camera-raw-goal/2026-11-13-shadows-bright-boundary.md)

### Negative Highlights in dark surroundings

Regenerate the −50 coefficients from the paired calibration captures with
the repository's analysis environment.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-dark-surround.py \
  .tmp/camera-raw-goal/highlight-color-meter/dark-calibration/manifest.json
```

The calibration uses 9 photographs, 24 spatial charts and the original color
lattice. Each capture holds identical pixel positions from the source, the
previous public render, its GPU probe, and the matched Adobe neutral and
−50 exports. The probe retains a known fraction of the loss according to
the four-pixel dark-surround measurement. Candidate coefficients weight its
RGB change by real input chroma and scene darkness. The second fit compares
subtracting fractions of the source pixel's own darkness from the local
measurement. It leaves one source out at a time with the first-stage gains
fixed. The final comparisons use independent GPU renders at full frame size.
[Photographs, chart results and signed error maps](../../../.tmp/camera-raw-goal/2026-11-13-highlights-dark-surround.md)

### Negative Highlights across neighboring luminance bins

On the same developed input, compare the actual Lightroom −50 and −100 changes
with the change predicted from −50 in the calibrated log-odds coordinate.
Replacing only the −50 input to that calculation separates the error in the
initial loss from the error in the stronger interval. Brightroom estimates
the −50 loss from its input RGB. Testing this estimate on a broad bright
region needs a source that also contains other tones.

The following command reproduces the selection of the amount shared between
adjacent tones. It reads native candidate renders at −50, checks source,
XMP, both neutral and edited output identities, ICC, and pixel count, and
uses the same nine photos, 24 spatial charts and color lattice in every run.
The four photographs reserved for validation and all other slider amounts are
excluded. Each photograph or chart contributes its own full-frame p95.

```sh
study=.tmp/camera-raw-goal/highlight-weak-meter
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-tonal-neighbors.py \
  "$study/odds-probes/manifest.json" \
  .tmp/camera-raw-goal/highlight-color-meter/retained-mac-half-all.json \
  "$study/highMode-mac-half-highlights.json" "$study"/bound*-mac-half-fit.json
```

The output reports the selected candidate, scores, and the result of
leaving out each source. The baseline is a candidate with zero change.
The signed near-neutral band and the separate validation photos are measured
in the [comparison report](../../../.tmp/camera-raw-goal/2026-11-13-highlights-bright-tones.md).

The same command accepts the five registered color-weight candidates in
place of the density candidates. In this experiment their report stems are
`coverage`, `sqrtCoverage`, `squareCoverage`, `measuredNeutral` and
`absoluteSpan`, followed by `-mac-half-fit.json`. The selected
`sqrtCoverage` uses the square root of the minimum to maximum channel
ratio. The separate −37 color scene checks two secondary channels after
selection.

## Regional lift for positive Shadows

Rebuild the positive Shadows rates from registered TIFFs. The fitter checks the
actual source, XMP, output ICC, neutral and adjusted references. It also runs
the built luminance and deviation kernels on the original source, so that the
local and global measurements use Core Image's guide sampling. Set
`DEVELOPER_DIR` to the Xcode used to build ParametricMacDemo. A built macOS
metallib, NumPy, SciPy and Pillow are required.

```sh
products=.tmp/xmp-derived-data/Build/Products/Debug
library="$products/Brightroom_BrightroomColorAdjustmentKernels.bundle/Contents/Resources/BrightroomColorAdjustments-macos.metallib"
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-positive-shadow-lift.py \
  .tmp/xmp-research .tmp/camera-raw-goal/acquisition/synthetic-001 "$library" \
  --photographs .tmp/camera-raw-goal/photo-calibration-acquisition/acquisition-001 \
  --check Sources/BrightroomColorAdjustmentKernels/HighlightShadowKernels.metal
```

Two charts at +10, +25 and +50 determine the log-odds bounds. The separate
+50 fit uses 25 gray inputs, the color lattice and four color layouts. The fit normalizes each
source by its sample count and weights each endpoint by the squared derivative
of linear intensity with respect to log odds. A ridge
penalty of 0.001 stabilizes the four-knot fit. The encoded regional brightness,
scene contrast and intercept give twelve coefficients in total. The five gray
sources originally reserved by `fit-spatial.py`, color layouts 02 and 05 and all
photographs are excluded from fitting these rates. The first six gray layouts
from `adaptive-002` were reused in the original spatial fit. The regularization
and blend selection are calibration decisions.

For scenes with more contrast, the kernel also uses a rate fitted to the same
+50 charts and nine photographs at −50. In linear ProPhoto log odds, changing
the sign of Shadows approximately reverses the step for a given pixel. The
second fit includes the scene's encoded geometric mean and excludes clipped
endpoints. Each family's total weight is 0.45 for photographs, 0.20 for the
lattice and 0.16 each for gray and colored layouts. The ridge penalty is 0.004.
The transition spans the highest contrast among the four training layouts
and the lowest among the nine training photographs. Both quantities are
standard deviations of normalized log luminance. The fitter reports those
limits and the two sets of coefficients. The separate +17 photographs, the
supplied +30 photograph and its complete A10 edit serve as checks.

For negative Shadows, the same rate predicts the decrease at both ProPhoto
extrema. The full-resolution response mixes this prediction into the existing
spatial estimate with a weight of up to one quarter, proportional to the
input's relative ProPhoto channel span. Gray pixels retain their original
response. The fraction of the full-strength loss is bounded at both extrema
when projecting outlying Display P3 channels. The full-strength photos were
used to evaluate this blend and were excluded from the rate fit.

To measure the relationship on another pair, run
`measure-shadow-interval.py FIRST_REPORT SECOND_REPORT --pair FIRST_CASE SECOND_CASE`
using paired-neutral reports from `A10/run.py`. For example, select −32 in
the first report and +17 in the second for the same photograph. The result
contains separate errors for prediction using Lightroom's first setting,
prediction using Brightroom's first setting and Brightroom's actual second
setting, all measured against Lightroom's second setting.

To exercise the XMP reader and production feature on five +17 photographs, run
the following in a new output directory. The report contains both absolute RGB
error and the difference between the two edit-minus-neutral responses. Compare
the supplied A10 result against its own output ICC and full-resolution TIFF.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/adaptive-holdout-002 .tmp/positive-shadows-photographs \
  --additional-references .tmp/camera-raw-goal/acquisition/photographs-001 \
  --scope light --paired-neutral --modes adaptive --developer-dir "$DEVELOPER_DIR" \
  --case-id holdout-photo-Shadows2012-17 --case-id photo-street-Shadows2012-17 \
  --case-id photo-portrait-Shadows2012-17 --case-id photo-color-Shadows2012-17 \
  --case-id photo-vertical-Shadows2012-17
```

### Local contrast in negative Highlights

The full-resolution kernel compares a pixel's encoded luminance with its
radius-4 geometric mean, and the radius-64 mean with the scene mean. At −50
these two contrasts predict a common luminance shift. Each ProPhoto component
takes the fraction of that shift corresponding to its own loss. Beyond the
fixed −50 color, a second pair of coefficients scales only the additional
loss. The gray axis and the existing wider-gamut response carry through this
step. The A10 preset and the −75 photograph exports are excluded from the fit.

Reproduce the four coefficients from the registered baseline GPU captures:

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-surround-loss.py \
  .tmp/camera-raw-goal/highlight-channel-anchors/calibration-inputs.json
```

The manifest names each source, XMP, neutral, Lightroom export, ICC profile
and sampled capture by SHA-256. Each capture includes identical row-major
indices for the native neutral, native −50 and requested strength, reference
neutral and edited exports, and the spatial guide values. The fitter gives
each source and strength the same weight. It uses the color half of the 32³
lattice, excluding the two gray ramps in its upper half. The −50 set contains
nine photographs and 25 synthetic sources. The −100 set contains the ramp,
the lattice, the sign and the bridge. The boat and plant are outside both
fits. Replay their XMP values with the existing
[strong Highlights comparison](#measuring-the-strong-highlights-interval).

### Negative Highlights scene range

Refit the −50 luminance gain from the paired Lightroom and public feature
captures. The command reads the registered 256-bin input histograms and
row-aligned neutral, −50 and guided log-luminance samples.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-scene-range.py \
  .tmp/camera-raw-goal/highlight-scene-exposure/calibration-inputs.json
```

The four coefficients apply to the centered 95th percentile, the centered
98th-to-75th percentile spread, and the local log-luminance contrasts at
radii 4 and 64. The fit includes nine photos, 24 spatial charts and the
colored half of one lattice. The scene histogram still covers the whole
lattice image. Each source has equal weight within its family. The native
renderer estimates its percentiles in the existing 128-bin, smoothed scene
histogram on a bounded GPU guide. Native validation checks this difference
from fitting on the complete source.

Use the [strong Highlights comparison](#measuring-the-strong-highlights-interval)
to check the same XMP at −75 and −100. The wider comparison also includes
the registered −37 and −50 exports, the green secondary-channel sample and
the bright end of the limited-range gray ramp.

### Color at equal source luminance

Pass `--color-luminance` to the context measurement to compare the response
on gray and saturated pixels at a specific source luminance. The level is
linear Display P3 and the band extends 0.005 on either side. This example
uses the same paired report and original XMP as the strong Highlights sweep.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/measure-light-context.py \
  .tmp/camera-raw-goal/highlight-channel-meter/xmp-strong/report.json \
  --case-id strong-photo-domain-011-Highlights2012--100 \
  --color-luminance .20 --color-luminance .35 --color-luminance .52
```

Each band uses the input file's linear ProPhoto RGB span divided by its
nonnegative peak plus 0.025, clamped to 0…1. The output includes pixel
counts, the mean RGB loss from each renderer's own neutral, and the p95
of the RGB, luminance and residual color errors. The residual color error
subtracts the luminance difference from each channel. The three p95
statistics describe different distributions and cannot be added together.
Empty bands carry a zero pixel count.

### Negative Shadows beside a brighter region

The calibration fits a shared fraction of the existing RGB loss to a signed
regional contrast. It uses registered −50/neutral TIFF pairs and the
corresponding pre-change public FeatureRenderer outputs in linear Display P3.
The geometric-mean luminance comes from the 16-pixel Gaussian neighborhood
at a 1024-pixel long edge. The calibrated implementation applies the fraction
on the brighter-surround side. It uses the feature's existing GPU guide.

The capture contains 5,000 fixed pixel positions per scene. `x` and `e50`
are the previous native neutral and edit. `n50` and `t50` are the registered
Lightroom neutral and edit. Column 2 of `log` holds the 16-pixel neighborhood
of the normalized log luminance before encoding. Each of nine photographic
scenes has equal weight within 60% of the fit, and each of 24 charts has equal
weight within the remaining 40%. Residual weighting and a 2% ridge term are
in the fitter. The manifest records the SHA-256 of the samples, inputs,
references, XMPs, ICC profiles and decoded baseline output.

```sh
study=.tmp/camera-raw-goal/shadow-local-odds
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-shadow-surround.py "$study/calibration.json"
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/presence-response/acquisition .tmp/shadows-surround-replay \
  --scope light --modes adaptive --paired-neutral --metrics-only \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

The second command independently renders Shadows −100 and its neutral on
each of the four registered photographs using the current Parametric body.
Its per-picture adjustment-response p95 can be compared with the public
single-feature renderer. The images are released once the pairs are measured.

### Negative Highlights at different neighborhood sizes

The four existing Gaussian guides supply the first and second moments of
normalized log luminance at radii 4, 16, 64 and 256 for a 1024-pixel long
edge. A smoothed rank compares the center pixel to each neighborhood. The
fit estimates how much of the signed RGB loss to retain using the fine
rank, the 4-to-16 rank difference, and the 64-to-256 difference evaluated
at three encoded tones. The GPU applies this correction in proportion to
the existing luminance estimator's weight near the P3 gamut boundary.
The peak-channel response has its own calibration at that boundary.

The calibration uses 5,000 registered positions per input, comparing the
change from each renderer's own neutral in extended-linear Display P3.
Each capture stores those positions (`idx`), the original geometry
(`shape`), Brightroom's prior neutral and edit (`x`, `e50`), Lightroom's
neutral and edit (`n50`, `t50`) and the device's spatial statistics
(`guide`). Columns 7/8, 10/11, 13/14 and 16/17 hold the first and second
local moments. Columns 4 and 5 hold the scene deviations before and after
the fine blur. Nine photographs share 62% of the weight, 24 spatial charts
share 28%, and the 32³ lattice contributes 10%. Only the color half of the
lattice enters the fit. Each capture and the associated original image,
XMP, reference pair and ICC are identified by SHA-256 in the manifest.

```sh
study=.tmp/camera-raw-goal/highlight-tone-ranks
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-tone-ranks.py "$study/calibration.json"
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/strong-highlight-interval/acquisition .tmp/highlights-rank-replay \
  --scope light --modes adaptive --paired-neutral --metrics-only \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

The first command reproduces the five fitted weights from the retained
baseline. The second reads the registered XMP files and measures the
current module at −75 and −100 on four photographs. A fit to the −50
endpoint can improve the complete −100 result while the additional
−50-to−100 change still has an error. Measure both when comparing models.

### Negative Highlights at a peak in the scene histogram

Use the paired −50 captures from the nine calibration photographs, the
24 spatial charts and the lower half of the 32³ color lattice. Keep a
128-bin encoded-luminance histogram for the same source. The comparison
tool's captures record the source, authored XMP, ICC, both Adobe TIFF hashes
and the frozen native kernel. Each compressed sample contains the same
registered pixel indices for its four linear Display P3 buffers. The
histogram uses the GPU's 64 × 32 staggered grid on a guide with a
256-pixel maximum long edge and a 0.02 encoded-unit Gaussian window.

```bash
study=.tmp/camera-raw-goal/highlight-edge-profile
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Light/fit-highlight-tone-density.py "$study/calibration.json"
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/A10/run.py \
  .tmp/camera-raw-goal/strong-highlight-interval/acquisition .tmp/highlights-density-replay \
  --scope light --modes adaptive --paired-neutral --metrics-only \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

The fit reports 5.84886 for excess population over the darker neighboring
bin and −1.97729 for the brighter one. Each signal uses the same 0.014
density support ramp as the spatial renderer. The fit scales their effect by
squared encoded headroom, the current RGB loss and the existing weight near
the P3 black boundary. Check the separate limited-range gray ramp along with
the withheld photos. It caught a regression when a barely populated bin was
treated as an observed neighbor.
[Per-image measurements and full-preset comparison](../../../.tmp/camera-raw-goal/2026-11-13-highlights-tone-density.md)
