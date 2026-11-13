# Whites and Blacks

`WhitesFeature` and `BlacksFeature` adjust developed RGB pixels with responses
measured from Lightroom Process Version 15.4. Negative Whites and Blacks use pointwise SDR
responses. Positive Whites adapts its strength to the input image's luminance
distribution and to colored highlights that approach white. From +50 to +75,
the feature blends toward a response that also measures asymmetry between
the dark and bright tails of the luminance distribution. The response was
measured on developed RGB. Nine photographs have registered +75 exports.
Four of them also have a +100 export from the same input.

```swift
let effects = [
  AnyImageEffect(WhitesFeature(amount: -22)),
  AnyImageEffect(BlacksFeature(amount: 11)),
]
let image = try FeatureRenderer().makeImage(from: source, feature: effects)
```

Both amounts range from -100 through 100, with an exact graph bypass at zero.
Positive Whites brightens the bright end; positive Blacks lifts the dark end.
Negative amounts lower those tones. Adobe describes these controls as adjusting
white and black clipping; its documentation does not specify an implementation
kernel. [Adobe tone controls](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)

The normal initializer and property setters clamp finite values to that range
and replace nonfinite values with zero. `init?(validatingAmount:)` rejects invalid
stored values without repairing them. Hosts choose the feature order; the
library owns no XMP parser or persistence format.

Alpha and the effect's input extent are preserved. The recipe matches into
extended-linear Display-P3 regardless of the rendering context's working space.
The pointwise paths use a 32-cubed encoded-P3 lattice of linear RGB deltas, with tetrahedral RGB
interpolation and nine signed parameter knots. Gray vertices remain achromatic.
Outside SDR, the boundary delta extends without clamping the input. That
extension preserves headroom but is not measured Adobe HDR behavior. Render
through a floating-point working format.

The pointwise paths cache one compiled amount per control. Already-built graphs
keep their own immutable table. Positive Whites measures the finite input extent
at the feature's position in the editing chain.

Through +10, positive Whites uses moments of lightly smoothed luminance and
the five-strength Float32 atlas. Between +10 and +25 it interpolates the fixed
endpoint colors in linear Display-P3. From +25, it samples up to 256×256 original
pixel centers. Each sample pairs encoded luminance with its Gaussian local average
at a standard deviation of 1/512 of the longer image dimension. The ratio of
mean squared fine detail to total variance weights the local average. The
result feeds 128 coverage-weighted luminance bins. The mean and thirteen quantiles
estimate the +75 gray displacement from seventeen synthetic scenes. A second
estimate weights their measured displacements by the overlap of sixteen
luminance intervals. Each fine bin distributes its mass between adjacent interval
centers. The greater the overlap, the more the local estimate contributes.
A second comparison caps the contribution of any one interval at 2.5% before
renormalizing. This makes wide areas of constant brightness less sensitive to
their relative area. The variance of the flat guide samples as a fraction of
the whole guide's variance determines the blend between these estimates.
A uniform 10% encoded gray field supplies an additional local measurement at +75.

The RGB measurements cover the same 32,768 colors on eight backgrounds at four
slider values. A shape-preserving cubic interpolates each channel across the
32 measured displacements and the identity. The resource packs 33 layers from
that curve. The builder can select each measured strength or an intermediate
position where the GPU's linear blend would lose more detail. Two
+100 gray ramps extend the displacement from 0.264 through 0.280 to 0.341.
A final layer at 0.355 extends the difference between the ramps to reach the
measured +75 output on the 10% gray field. All three extensions transfer the
additional gray change to the color extrema in linear ProPhoto RGB.
Each layer stores the response of the two outer ProPhoto channels on a grid of
63 levels. Sorting all three input channels lets the six channel permutations
share measurements. The GPU interpolates the two endpoint changes and preserves
the position of the middle channel between them in linear light. Grays follow
the measured neutral ramp.
Eight RGB chart backgrounds and two gray ramps each provide a measured pair
of +75 and +100 displacements. The feature estimates +100 from +75 with
a ratio of two polynomials fitted to those ten pairs. The slope stays
positive across the response table. The GPU evaluates the distribution
once per graph and samples the tables at the full input resolution.
Between +50 and +75 the output interpolates the two endpoint responses in
linear Display-P3. Above +75, a full-resolution reduction measures the largest
visible channel of the input and its +100 output. If that output leaves headroom
below the measured white point, the feature adds a fraction of the +100 correction.
At +100 that fraction reaches one. Five independent gray-level exports determine
the white point. Below 10% encoded gray the target connects linearly to black.
Crop an unbounded Core Image generator before applying
positive Whites.

## Validation and limits

The comparison uses the same already-developed TIFF for both applications,
matching export ICC profiles. Error is the per-pixel maximum RGB channel
difference in linear Display-P3, white = 1; it is not Delta E or a visual match
percentage. Each comparison covers every pixel in the registered image. The
supplied full-size A10 TIFF has 24 million pixels.

Original +/-25 photographic references, rendered through the public features
before spatial adaptation:

| Control | p95 error |
|---|---:|
| Whites -25 | 0.000229 |
| Whites +25 | **0.043242** |
| Blacks -25 | 0.000211 |
| Blacks +25 | 0.000260 |

On the supplied Apple RAW TIFF / Lightroom A10 pair, adding the two public
features reduces full-stack p95 from 0.092173 to 0.081229. The previous research
Light stack scored 0.080962 and used a different measured global Saturation,
so the public-feature stack is slightly worse than that candidate. Its median
also rises slightly, from 0.031710 without the two controls to 0.031990 with
them. This is not uniform improvement or complete A10 reproduction.

The ramp-on-different-background experiment keeps the tested pixels exactly
equal. Lightroom's Whites +25 response changes when the background changes,
falsifying a universal pointwise mapping. It does not establish whether Adobe
uses local filtering, image-wide statistics, or both. Uniform-midgray negative
Blacks also has a measured mismatch of about 0.00179 in the public feature run;
the other successful cases do not establish universal Blacks parity.

### Positive-Whites follow-up

The spatial follow-up reduced the original full-resolution photograph's +25 p95
from **0.043242 to 0.000616**. At unused strengths on a 1500x1000 version of that
same scene, +42 improved **0.133681 -> 0.023378** and +75 improved
**0.479096 -> 0.275311**. On a new colored scene, +42 improved
**0.079188 -> 0.045965**, and +75 improved **0.307548 -> 0.082907**.
These are actual public-feature renders, not only numerical model predictions.
The previous pointwise adapter is the baseline for these four new cases.

### Strong positive Whites

The public 16-bit export with the distribution-based response was measured on
each registered image against its matching Lightroom export. Error is the
95th percentile of the largest absolute linear Display-P3 channel difference
per pixel, with white at 1. Each row gives the mean of those image-level values.

| Setting | Images | Pointwise baseline | Initial distribution model | Improved |
| --- | ---: | ---: | ---: | ---: |
| +75, photographs | 5 | 0.121732 | 0.044837 | 4 |
| +75, charts | 21 | 0.122254 | 0.031138 | 20 |
| +100, charts | 21 | 0.368622 | 0.095799 | 20 |

The street photograph changed from 0.10163 to 0.05630 and the portrait from
0.10814 to 0.00521. The bright color photograph regressed from 0.02719 to
0.03017, and the held colored chart from 0.08291 to 0.14330. A uniform field
at 10% encoded gray had p95 of 0.9134 at +100 in that model.
Lightroom brings that field close to white. Extending the table reduced
the 25% gray error from 0.6965 to 0.2556 and the calibration ramp error
from 0.4533 to 0.0053. All five +75 photo outputs stayed at their previous p95.
Photo validation above the original displacement range is pending.

The five photographs served as recurring validation images. The predictor
coefficients and tables use synthetic measurements. After extending the
distribution response to +25 and +50, all 101 registered conditions were
rendered again in both working precisions.

| Setting | Images | Before extending the range | Extended distribution model | Improved |
|---|---:|---:|---:|---:|
| +25, charts | 26 | 0.012382 | 0.005743 | 18 |
| +42, photographs | 5 | 0.044865 | 0.012573 | 4 |
| +42, colored chart | 1 | 0.045964 | 0.033754 | 1 |
| +50, charts | 21 | 0.051110 | 0.009302 | 21 |

The street photo at +42 improved from 0.08559 to 0.01739. The bright color
photo went from 0.00984 to 0.01106. The independent full-resolution check
at +25 went from 0.00062 to 0.00272 on the supplied photograph, and the
permuted grayscale chart went from 0.01421 to 0.03419. The +75/+100 p95
values matched the previous distribution implementation on every registered
input. Across 28 slider positions on 26 inputs, the largest 95th-percentile
luminance decrease between adjacent settings was 0.0000018. A10 uses
Whites −22 and measures a separate combination of effects.

The spatial histogram and the measured white point were then checked against
the same registered exports. These are 16-bit exports through the public feature.

| Setting | Inputs | Previous p95 | Spatial histogram and white point |
|---|---:|---:|---:|
| +25, charts | 26 | 0.005743 | 0.004544 |
| +42, photographs | 5 | 0.012573 | 0.010585 |
| +75, photographs | 5 | 0.044837 | 0.042220 |
| +100, charts | 21 | 0.095799 | 0.036095 |

With +25 on a shuffled gray ramp, p95 fell from 0.03419 to 0.00483.
The full-size photograph at +25 moved from 0.00272 to 0.00228.
At +100 the 10% uniform gray changed from 0.91344 to 0.00011. Five gray
levels provide the white-point calibration. The paired-surround chart still
has p95 of 0.36625. At +75 the portrait error rose from 0.00521 to 0.02694.

The sixteen-interval histogram interpolation and two gray-ramp extensions
were then evaluated on the same 101 registered cases in both working precisions.
The table uses the normal half-float path, a 16-bit export, and the image-level
p95 metric above. The five photographs were used repeatedly for validation.

| Whites setting | Inputs | Previous | Histogram and two ramps |
|---|---:|---:|---:|
| +25, full-resolution supplied photograph | 1 | 0.002277 | 0.000322 |
| +42, photographs | 5 | 0.010585 | 0.003616 |
| +75, photographs | 5 | 0.042220 | 0.020921 |
| +75, charts | 21 | 0.030109 | 0.007948 |
| +100, charts | 21 | 0.036095 | 0.006486 |

Changing the padding around identical ramps in the held-out layout previously
gave p95 of 0.36625 at +100. The two-ramp model gave 0.02259. The +75 street image moved
from 0.06667 to 0.02501, while the portrait rose from 0.02694 to 0.03042.
The 10% gray field at +75 reached 0.081 where Lightroom reached 0.099.
The +100 measurements in this table cover synthetic images. Four later
photographic measurements appear in [Positive Whites at +100](#positive-whites-at-100).

The same five photographs have registered +42 and +75 exports. In a diagnostic
using the packaged 19-layer RGB table, 16,384 pixels per photo estimated the
response strength and another 16,384 measured the error. Inferring the +75
strength from the measured Lightroom +42 response and the public amount law
gave mean +75 p95 0.014773, versus 0.020862 for the public GPU render on the
same evaluation pixels. Three scenes improved and two regressed. Fitting
the strength directly to the +75 reference gave 0.005604 on the evaluation
pixels. These estimates require a Lightroom export of each photo. They
quantify remaining errors in scene-strength selection, slider scaling and
the RGB response. The feature estimates strength from its input alone.

### Nonuniform color responses and the dark gray field

The 28-layer resource was evaluated against the same 101 registered Lightroom
exports in half- and single-float working formats. Each frame was exported
at 16 bits per channel. The following photo and chart-validation rows exclude
the inputs used to fit the resource. The gray field supplied its final layer.

| Whites setting and input | Count | Previous p95 | Updated p95 |
| --- | ---: | ---: | ---: |
| +42, photographs | 5 | 0.003616 | 0.003568 |
| +75, photographs | 5 | 0.020921 | 0.020538 |
| +50, chart validation | 3 | 0.007595 | 0.005883 |
| +75, chart validation | 4 | 0.028830 | 0.027827 |
| +100, chart validation | 3 | 0.024752 | 0.022083 |
| +75, uniform 10% gray | 1 | 0.018633 | 0.000167 |

Three of the five +75 photos improved in the normal half-float working format.
The street photo went from 0.025011 to 0.025971 and the bright color photo
from 0.022742 to 0.022869. At +25 on the 24 MP original, p95 increased from
0.000322 to 0.000359. The single-float +75 photo mean was 0.020796 before
and 0.020578 after, with one photo improving and four regressing slightly.
The compressed resource grew from 3.13 MB to 4.65 MB.

On the same five photos, an independent set of 16,384 pixels per image
evaluated a displacement inferred from a separate 16,384 pixels of the +75
Lightroom output. Mean p95 for that diagnostic fell from 0.005604 with the old
table to 0.003443 with the new one. The standard GPU output on those evaluation
pixels measured 0.020508. Estimating the scene's displacement accounts for
most of the remaining error on these photographs.

Brightroom's standard 8-bit and 16-bit exports evaluate the graph in half
precision. Forcing the intermediate Core Image working format to `.RGBA8`
in the iOS 27.2 simulator gave an incorrect +75 result on uniform gray
with both resource versions. The public 8-bit Display-P3 export reproduced
the measured gray within 0.005 in linear light.

### Color interpolation at strong positive amounts

On the five recurring photographs, the ordered ProPhoto response reduced the
mean full-frame p95 for +42 from 0.003568 to 0.003531 and for +75 from
0.020538 to 0.020488 in half precision. Three photographs improved and two
regressed at each strength. On the four held-out +75 charts, the mean fell
from 0.027827 to 0.027739. The packaged response occupies 3.80 MB.

At +75 the mean p95 of the middle-channel error on the same photographs fell
from 0.001072 to 0.000270. This statistic takes the middle channel's position
between the outer channels from the original linear Display-P3 pixel, then
compares the Lightroom and Brightroom outputs at that position. It excludes
inputs with a channel span of 0.02 or less. The brightness endpoints still
depend on scene metering. Photo-specific parameters do not enter the feature.

The current metering also estimates the remaining distance to white across
the whole scene and in its brightest pixels. It uses the existing 16-bin
luminance distribution. A histogram with isolated peaks or a close match to
a calibration scene gives the estimate less weight. The coefficients come
from 17 synthetic scenes. In the half-float public export the +42 photo mean
fell from 0.003531 to 0.003109, and the +75 mean from 0.020488 to 0.018486.
At each strength four of the five photos improved and one had the same p95.
A held-out color chart at +75 rose from 0.068510 to 0.071475.
[Headroom calibration](../Tools/LightroomComparison/Light/README.md#positive-whites-headroom)

Three charts have paired +75 and +100 Lightroom exports from the same input.
For each chart, 8,192 pixels of the +75 reference estimated its scene-wide
displacement. A diagnostic GPU render supplied that displacement to the public
+75-to-+100 curve. On a separate 8,192 pixels of the +100 reference, p95 fell
from 0.035216 to 0.000912 on the diagonal pattern, from 0.022511 to 0.002180
on the paired surround, and from 0.006859 to 0.005365 on the color plane.
The first two patterns identify scene metering as their main source of error.
The public feature must estimate the displacement from the input alone.

The flat-region estimate brings the full-frame macOS half-float p95 for +100
from 0.034059 to 0.011898 on the diagonal pattern and from 0.022098 to
0.004423 on the paired surround. The color plane held at 0.006841. Across
21 charts the +100 mean went from 0.005467 to 0.003570. At +75, four of five
photographs kept the same p95, and one went from 0.023248 to 0.023323.

On a separate 32³ color lattice with two gray strips, the luminance estimate
gave a full-frame +100 p95 of 0.105690. The feature now measures how much of
the image approaches white in an individual ProPhoto RGB channel while its
luminance stays below white. When this area exceeds the range of the original
17 calibration scenes, the feature reduces the estimated lift. The lattice's
+50 Lightroom export sets the maximum reduction. The public renderer uses
only the incoming pixels and the Whites amount.

At +100 on that same chart, the macOS half-float p95 fell to **0.010831**.
On a photograph of balloons, +42 fell from 0.007952 to 0.003676 and +75
from 0.023323 to 0.002725. The other four photographs retained identical
16-bit output at both strengths. Across all five photographs the +75 mean
went from 0.018501 to **0.014381**. The portrait still measured 0.028732
at +75. The four +100 photographs are described below.
[Calibration and XMP replay](../Tools/LightroomComparison/Light/README.md#colored-highlights-in-positive-whites)

## Reproduce

See the [Light investigation](../Tools/LightroomComparison/Light/README.md) for
resource generation, manifest-bound reference acquisition and context probes.
From the repository root, against the retained reference acquisition:

```sh
python3 Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/whites-context-001 .tmp/xmp-research/runs/new-tonal \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope light --modes tonal --middle-channel-error
```

`tonal` uses the public Whites/Blacks features and measured Mixer, with the
existing Highlight/Shadow/Saturation features. `calibrated-light` retains the
previous research adapter including measured global Saturation. Do not attribute
full-stack differences between those modes solely to Whites/Blacks.

### Repeated colors and spatial arrangement

Across 97 positive-Whites settings, the same native RGB code appeared at least
twice in each half of a 64-pixel checkerboard. On all 49,352,004 qualifying
pixel observations, Lightroom produced identical linear-P3 output for the same
source code within the same image and setting. Four other settings had no
qualifying repeats. Many of the qualifying pixels came from synthetic charts.
The five photos contributed between 162 and 728,928 qualifying pixels per
setting.

The response still depends on the image. At the center of a gray ribbon,
Whites +25 lifted linear green from 0.523654 by 0.049258 on a dark background
and by 0.023991 on a bright one. Swapping near and far surrounds in a
histogram-matched pair preserved the response for every code. Shuffling a
ramp with the exact same histogram changed its output by p95 0.036503 after
aligning source codes. These observations support measuring the spatial
arrangement to select a common image-wide color response.

### Positive Whites at +100

Four further photographs have registered neutral, Whites +75 and Whites +100
Lightroom exports. Before the photographic metering experiment, their macOS
half-float public-render p95 values at +100 were
0.323366, 0.084564, 0.097394 and 0.116931. On two photographs the selected
displacement is too high and on the other two it is too low. Across
85,224 pixels whose 16-bit input RGB repeated on both sides of a 64-pixel
checkerboard, each source color had exactly the same +100 output everywhere
it occurred within its photograph. One photograph contributed most of these pixels.

To estimate how much of the error comes from metering, 8,192 pixels of each
Lightroom output selected a displacement in the existing RGB table. Another
8,192 pixels of the same photograph measured p95 values of 0.000514,
0.001151, 0.001069 and 0.005070. This experiment uses each photograph's
Lightroom output. The public feature chooses its displacement from the source alone.
Fitting the displacement on each photograph's +75 export and applying the existing
+75-to-+100 curve predicts the +100 export with p95 of 0.001294, 0.001240,
0.002196 and 0.006276 on the separate 8,192 pixels. In the table's displacement
units, the error in selecting the +75 displacement accounted for 96.6–99.6%
of the sum of the two absolute errors. These measurements use Adobe output to
isolate the two contributions.

Rendering the 101 public integer settings of that build from 0 to +100 on each of these
inputs gives a result in slider units. Against Adobe +100, the illuminated
sign was closest at +84 and the boat at +92, with whole-frame p95 of
0.001452 and 0.001471. On the bridge and the plant the closest setting was
the public maximum of +100. Their p95 remained 0.084564 and 0.116931.
Against the +75 exports the closest public integers were +63, +80, +68 and +80.
A separate 8,192-pixel sample selected each value. These are diagnostics
using each Lightroom reference. The XMP mapping uses the original amount.
[Reproduce the slider comparison](../Tools/LightroomComparison/Light/README.md#measuring-the-closest-public-slider-value)

### Matching the photographic +75 endpoint

The feature compares the mean encoded luminance with the 1st and 99th
percentiles. It repeats the comparison at the 5th and 95th percentiles
and subtracts the change in balance from the magnitude of the first estimate.
A consistent bright tail reduces the lift. A consistent dark tail increases
it. A narrow distribution, flat regions, proximity to a calibrated scene
and colored channels near white all reduce the weight of this adjustment.
The +50 displacement is a lower bound on the +75 estimate. This keeps
increasing Whites from darkening an image with a small bright region on
a dark field. The +75 estimate feeds the existing +100 curve. Settings
from +50 to +75 blend the measured endpoint images.

Five registered +75 photographs supplied the fit. Two of them, the sign
and bridge, had a nonzero tail term. The boat, plant, street and balloon
photographs were excluded from the fit and had been used in earlier evaluations.
The table shows whole-frame p95 maximum RGB error in linear Display P3 on
macOS half-float. Each row uses the original XMP setting on every photograph.

| Registered inputs | Whites | Previous | With the tail estimate |
| --- | ---: | ---: | ---: |
| Sign, bridge, boat and plant | +75 | 0.086423 | 0.012615 |
| Same four photographs | +100 | 0.155564 | 0.023060 |
| Boat and plant | +100 | 0.107162 | 0.033688 |
| Boat, plant, street and balloons | +75 | 0.034133 | 0.013455 |
| Five earlier photographs | +75 | 0.014381 | 0.013204 |

In slider units, the four Lightroom +75 exports were closest to Brightroom
+63, +80, +68 and +80 before this change. A new sweep over every integer
setting of the public feature selected **+75, +76, +72 and +76**. The table
above uses +75 on all four images.

Of 119 registered conditions, 15 improved, seven had a higher p95 and 97
had the same p95. The largest increase was on the two-tone diagonal chart
at +100, from 0.011898 to 0.013624. The colored lattice retained its +100
p95 of 0.010831. All 63 settings through +50 produced identical decoded RGB.
[Reproduce the measurements and fit](../Tools/LightroomComparison/Light/README.md#photographic-whites-at-75-and-100)

### Measuring the brightest and darkest 5%

Two images can have similar 5th and 95th percentiles while their darkest or
brightest pixels extend different distances beyond those levels. The +75
endpoint now measures the mean of each outer 5% of the luminance distribution.
It gives this difference more weight when the broader 1st-to-99th percentile
balance is small relative to the standard deviation. The extra correction
fades when the mean and median point toward the opposite tail. All these values
come from the existing whole-image histogram. The same five +75 photographs
used in the previous fit supplied the new coefficient.

Each entry below is the mean of four whole-image p95 errors. Both editors
used the same developed input and XMP value. Each response is measured from
the editor's own neutral output in linear Display P3. The interval row first
subtracts +75 from +100 at each pixel in each editor, then compares the two
changes. Each pixel contributes its largest absolute RGB channel error.

| Whites on sign, bridge, boat and plant | Previous | With the outer 5% |
| --- | ---: | ---: |
| +75 | 0.012574 | 0.008754 |
| +100 | 0.022922 | 0.016035 |
| Additional lift from +75 to +100 | 0.015441 | 0.010684 |

At +100 on macOS half-float, the sign retained its p95 of 0.004162.
The bridge improved from 0.020233 to 0.003299, the boat from 0.037521
to 0.029314, and the plant from 0.029772 to 0.027362. The boat and plant
were excluded from the fit and had been evaluated in earlier experiments.
On nine photos at +75, the mean absolute p95 fell from 0.012942 to 0.006667.
Across 119 registered conditions on macOS half-float, nine p95 values
improved and four increased. The largest increase was 0.000081 on the
paired-surround chart at +100. All 63 conditions through +50 produced
identical decoded RGB. The full A10 preset uses Whites −22.
[Reproduce the coefficient and interval measurements](../Tools/LightroomComparison/Light/README.md#photographic-whites-at-75-and-100)

### Near-white colors above +75

Above +75, the feature measures the brightest channel at +100 over the full
image. It now looks up the current pixel and applies the resulting peak correction
in one kernel. Reading the current RGB from an intermediate half-float texture
could lower an almost-white channel when the slider moved from +75 to +76.

An upper-range sweep tested 18 gray patterns with a narrow bright strip on a
dark textured background. Each pattern was exported at every integer from +75
to +100. The number of pixel transitions with a channel decrease greater than
0.0001 in linear Display P3 fell from 36,744 to zero on both macOS and the iOS
simulator. The largest remaining decrease was 0.000011. The test
`raisingWhitesPast75PreservesNearWhiteChannelsInHalfFloat` exercises this
boundary through the public renderer.

At the original Whites +100 setting, the mean whole-image RGB p95 for the
registered sign, bridge, boat and plant went from 0.023060 to 0.022943 on
macOS. The boat went from 0.037286 to 0.037507 and the color lattice from
0.010831 to 0.011114. Of the 119 registered settings, the 93 through +75
produced identical decoded pixels. The scene-dependent metering error at +100
is larger than the change from the intermediate texture.

### Concentrated bright and dark tails

The +75 estimate compares the asymmetry of the outer 5% of the luminance
histogram with the outer 10%. When the imbalance recedes at the inner
boundary, the estimate scales the tail correction by the distance from mean
luminance to white. Histogram bin width and the proportion of flat regions
limit this adjustment on stepped patterns. The two gains are reproducible
from the same five +75 photo observations. The existing +100 strength curve
takes the revised +75 estimate as its input.

Both editors received the same source pixels, ICC profile and authored XMP
value. Each row gives the mean of four whole-image p95 errors on macOS
half-float. The errors compare the RGB change from each editor's own neutral
in linear Display P3 where white is 1.

| Sign, bridge, boat and plant | Previous | With the 10% boundary |
| --- | ---: | ---: |
| Whites +75 | 0.008754 | 0.002441 |
| Whites +100 | 0.016035 | 0.004139 |
| Additional lift from +75 to +100 | 0.010684 | 0.003915 |

The boat and plant were excluded from the five coefficient-fit sources.
Their +100 errors fell from 0.029314 to 0.007298 and from 0.027362 to
0.007024, respectively. The evaluation photos were also inspected during
model selection. In an integer sweep from 0 to 100, the closest Brightroom
setting to Lightroom +75 was +75 for every one of the four photographs.
For Lightroom +100, the closest setting was +99 on the boat and +100 on
the other three. All the errors above use the authored XMP value.

Across all nine available +75 photographs the mean absolute p95 fell from
0.006667 to 0.003855. The street photo retained an absolute p95 of 0.017532,
and the sinusoidal color chart retained 0.066767. The largest regression
among the 119 macOS half-float conditions was the diagonal stepped chart
at +100, from 0.013468 to 0.013504.

### Interpolating the white point

The positive Whites atlas carries the measured slope of each outer linear
ProPhoto channel through the start of its white plateau. Extrapolation ends
within one step of the strength grid. The GPU still limits the interpolated
endpoints to white and preserves the input channel order. The calibration uses
the same 32 color cubes measured on eight backgrounds.

The table compares each editor's change from neutral and the extra lift between
the two settings. Each value is the mean of four whole-photograph p95 errors
in linear Display P3, measured with the macOS half-float renderer.

| Authored setting | Previous atlas | Revised atlas |
| --- | ---: | ---: |
| Whites +75 | 0.002441 | 0.002405 |
| Whites +100 | 0.004139 | 0.003969 |
| Change from +75 to +100 | 0.003915 | 0.003684 |

All four interval errors decreased. At +75 the bridge increased from 0.002038
to 0.002152 and the plant from 0.001765 to 0.001784. Across 119 registered
settings, 61 absolute p95 errors decreased, 55 stayed the same and three
increased. The largest increase was 0.000079 on the bridge at +75.
The photos were used to compare candidate methods. Their XMP values were
applied directly.

The boat retains a +100 response error of 0.007297. Fitting the previous atlas's
scene strength on 8,192 pixels and evaluating 24,576 different pixels reduced
the boat's diagnostic error from 0.007296 to 0.000949. On the plant it went
from 0.006991 to 0.004990. Scene metering still contributes to both. The
remaining color response is especially apparent on the plant.
[Rebuild the atlas](../Tools/LightroomComparison/Light/README.md#strong-positive-whites)
and [repeat the photographic comparisons](../Tools/LightroomComparison/Light/README.md#photographic-whites-at-75-and-100).
[Reproduce the fit and whole-image interval check](../Tools/LightroomComparison/Light/README.md#photographic-whites-at-75-and-100)
