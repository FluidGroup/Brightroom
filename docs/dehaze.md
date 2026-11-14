# Dehaze on developed RGB images

`DehazeFeature(amount:)` takes the signed Camera Raw `Dehaze` value in −100…100. The default is zero. Its validating initializer accepts only finite values in that range. For example, `DehazeFeature(amount: 9)` applies A10's setting to an existing image. A host chooses the position in its feature stack. In the A10 comparison and DNG development adapters, the point curve is followed by Texture, Clarity, Dehaze and the Color Mixer.

## Image response

The shader measures two properties of each neighborhood in linear ProPhoto RGB primaries. A local minimum of the lowest color channel estimates how bright the darkest colors are. A wider average measures the surrounding colors. The mean local minimum and the maximum of a broadly blurred luminance image supply the scene-wide darkness and brightness estimates. This use of a local dark channel was motivated by an image dehazing method from He, Sun and Tang. The Brightroom response and its coefficients are empirical measurements against SDR Lightroom Process Version 15.4. [Single Image Haze Removal Using Dark Channel Prior](https://people.csail.mit.edu/kaiming/publications/cvpr09.pdf)

The guides are limited to 1024 pixels on the long edge and the output samples the original RGB at every pixel. Local minimum and broad Gaussian radii scale with the input extent. Transparent samples carry zero weight in the scene averages. The fitted luminance and chroma shifts interpolate between −100, −50, 0, +9, +50 and +100. The strongest negative setting has a measured black lift. Values outside the SDR ProPhoto cube receive the change calculated at its boundary.

## Lightroom comparison

A chart and two photographs supplied the five nonzero endpoints. Selection omitted one entire calibration source at a time. Two further photographs (a boat and a plant) were reserved for evaluating the frozen response. Each cell below is the mean of the two photographs' individual 95th percentiles. Each pixel contributes its largest absolute RGB error in extended-linear Display P3, with white equal to 1. The comparison subtracts the matching neutral on each side before measuring the change.

| XMP Dehaze | Previously omitted | Public feature, macOS |
| ---: | ---: | ---: |
| −100 | 0.38076 | 0.22947 |
| −50 | 0.16646 | 0.10879 |
| +9 | 0.01605 | 0.01199 |
| +50 | 0.09051 | 0.06878 |
| +100 | 0.17937 | 0.13786 |

On the supplied 24-megapixel TIFF, absolute p95 for the entire A10 preset changed from 0.046224 to 0.045765. Isolating the three Presence controls on a separate registered export of the same scene increased response p95 from 0.016900 to 0.018231. The plant example loses more of its blue-green color than Lightroom at −50. The iOS simulator rendered the same 34 inputs. Its per-setting p95 differed from macOS by at most 0.00058 across the 25 Dehaze changes. Intermediate slider values interpolate between measured knots and have no independent Lightroom exports in this set. This Dehaze measurement predates the addition of Clarity and Texture. [Clarity measurements](clarity.md) · [Texture measurements](texture.md)

The research scripts read the recorded input, XMP, TIFF, embedded ICC profile and role of each source. The public renderer produces its own pixels from the source and XMP. The fitter uses Python, NumPy, SciPy and Pillow. `Light/decode.swift` produces its input arrays. The fitting command writes a new JSON file with endpoint weights and evidence hashes. [Comparison commands](../Tools/LightroomComparison/A10/README.md#measure-presence-and-dehaze) · [Coefficient reproduction](../Tools/LightroomComparison/Dehaze/calibrate.py)
