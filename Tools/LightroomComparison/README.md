# Lightroom comparison tools

These tools apply Camera Raw settings through Brightroom's public features and
compare the rendered pixels with a Lightroom export of the same developed image.
To reproduce the comparison with your own files, start with a 16-bit TIFF, the
XMP applied to it, and Lightroom's 16-bit TIFF export with embedded settings.
The runner checks the settings and renders into the reference's output profile.
[Compare a supplied TIFF and XMP](A10/README.md#compare-a-supplied-bitmap--lightroom-export-pair)

For the 6000 × 4000 A10 example, the 95th percentile of the per-pixel maximum
absolute RGB channel error was 0.042610 in linear Display P3, with white at 1.
The RAW profile, regional tone curve, and noise reduction remain outside the
adapter. [Highlights and Shadows measurements](../../docs/highlights-shadows.md#negative-highlights-at-a-peak-in-the-scene-histogram)

## Replay the measured loop

[Run recorded Lightroom charts on a fresh Mac or from a Linux agent via CI](Fixtures/README.md). The included post-development Light cases do not require the local acquisition or an Adobe installation.

### Original Color Grading study

The local acquisition is in `.tmp/xmp-research`. It contains private photographs,
large TIFF exports and fixed manifests; these are deliberately not committed.
Keep that directory with this checkout if continuing the experiment.

```sh
python3 Tools/LightroomComparison/run.py \
  .tmp/xmp-research .tmp/xmp-research/runs/my-new-run \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

Required: Xcode with Metal Toolchain, macOS Core Image/GPU access, the existing
local acquisition. No Python dependencies are needed for comparison. The runner
builds ParametricMacDemo, links `render-grading.swift` to its actual package
objects/resources, renders neutral plus 19 held-out settings, then compares them
in Float32 extended-linear Display-P3. It freezes candidate/tool sources and
reports input/output/reference hashes, absolute error and separately the change
relative to each renderer's neutral output. An existing output directory is
rejected. Reference hashes and the common input hash must match the acquisition.

`compare.swift` rejects mismatched dimensions, missing ICC profiles, non-16-bit,
nonopaque and nonfinite images. Its heatmap is maximum absolute channel error
per 10×10 block, multiplied by 64. The tool was checked against exact-zero,
known-gray-step, baseline-response, coordinate-marker and wrong-size controls
in the local `comparator-validation` run. Error units are not perceptual Delta E.

The photograph check uses `render-grading input.tiff settings.json new-folder p3`
and `compare-grading adobe.tif new-folder/brightroom.png new-comparison-folder`.
These binaries are placed in `.tmp/xmp-derived-data/Build/Products/Debug` by the
runner. Settings JSON contains root CRS key/string pairs; for example
`{"ColorGradeGlobalHue":"52","ColorGradeGlobalSat":"30"}`.
Use `prophoto` for the analytic chart references and `p3` for the original photo
references. Neither command silently substitutes a different color space.

## Acquisition and fitting discipline

1. Develop RAW once to a tagged 16-bit TIFF; reimport that TIFF into Lightroom.
   JPEG inputs can be tested directly, with their own neutral baselines. Do not
   compare Adobe RAW development to Apple RAW development as grading evidence.
2. Freeze a synthetic RGB chart: encoded/linear gray ramps plus an RGB lattice.
   Preserve identical decoded pixel bytes in every case. Embed requested XMP
   metadata into copies; never edit the original DNG or supplied presets.
3. Use a separate Lightroom catalog. Fix ProcessVersion, Color profile, WB,
   all Basic/Curve/Mixer/Grading/presence/lens/detail controls, export ICC and depth.
   Export 16-bit TIFF with no resize, sharpening, watermark or HDR.
4. Extract resolved root CRS settings from exported TIFFs. Check **all** requested
   and neutral controls; ignore only AlreadyApplied and RawFileName. Keep nested
   Look settings separate from authored root settings. Freeze exports only once.
5. Keep fitting, validation parameters, RGB lattice and photographs separate.
   Fit one control, then check strength, hue wrap, B/A interactions and combined
   operations. A neutral mismatch is a color-management diagnostic, never a
   reason to subtract away absolute errors and declare compatibility.
6. Evaluate changes with `run.py`. Choose the next measurement from an observed
   residual. Freeze fresh validation cases after a model-selection iteration.
   Preserve a failed run and create a new output directory after a fix.

For this acquisition, `grading-cases.json` defines 225 fitting cases, 19 parameter
validation cases and neutral; `grading-grid-cases.json` defines 500 additional
fitting cases. Resolved settings and TIFF hashes are in the corresponding
`*-references.json`; float decodes are in `grading-pixels`/`grading-grid-pixels`.
All controls, input preparation, metadata inspection and decoding scripts from
acquisition remain in the local `.tmp` directory. Replaying comparison needs no
Lightroom UI. Reacquiring new references still requires Lightroom and explicit
verification of its exports; there is no verified headless Adobe renderer here.

`calibration.json` retains the 725 training reference hashes, decoded-data hashes,
neutral decoded hash and binary hash. Reproduce the committed binary with:

```sh
python3 -m venv .tmp/grading-analysis
.tmp/grading-analysis/bin/pip install -r Tools/LightroomComparison/requirements.txt
.tmp/grading-analysis/bin/python Tools/LightroomComparison/build-calibration.py \
  .tmp/xmp-research .tmp/reproduced-calibration.bin
```

The builder rejects a changed reference, decode or binary result. It never reads
photographs or validation cases. The current reproduction was byte-identical.

## Develop a DNG with the partial XMP adapter

```sh
python3 Tools/LightroomComparison/develop-xmp.py \
  /path/to/photo.DNG .tmp/xmp-research/developed/new-run \
  /path/to/photo.xmp /path/to/preset.xmp \
  --simulator SIMULATOR_UUID \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer
```

This copies and hash-checks the RAW into the evidence directory. It temporarily
adds a driver to Dev's engine test target, executes **production**
`SourceImage(rawContentsOf:) -> EditingDocument.render()`, and removes only its
own driver in `finally`. It refuses to overwrite an existing driver. Do not run
two development adapters in the same checkout concurrently. Optional `--catalyst`
uses the same Engine on Mac Catalyst; the completed reference run used iOS 27.2.

The adapter is intentionally for the supplied preset family. Its outputs are
named `*-partial.png`; `configuration.json` retains requested settings, explicit
approximate mappings and unsupported controls. The adapter passes signed
Highlights and Shadows to `HighlightsShadowsFeature`, which accounts for their
interaction when reducing highlights and lifting shadows. Whites, Blacks and
global Saturation follow. The default adapter applies
Texture, Clarity and Dehaze to developed RGB after the point curve, in that order.
[Texture measurements](../../docs/texture.md) · [Clarity measurements](../../docs/clarity.md) · [Dehaze measurements](../../docs/dehaze.md)

`--derived-data PATH` selects
an isolated Xcode build directory when testing a package resource change.
The adapters pass the XMP grain Amount, Size, Frequency and Seed to
`GrainFeature.CameraRaw` after the crop and vignette. The supplied A10
20/42/70 setting has paired Lightroom measurements. The photo sidecar's
25/73/65 combination is awaiting a reference. [Grain measurements](../../docs/grain.md)
The DNG and developed-TIFF adapters share the same reader for scalar RDF
attributes, scalar elements and explicit point curves.
`render.json` records the actual RAW intermediate precision, output profile,
dimensions, hashes and minimum 8-bit alpha. This opaque DNG export fails if any
tile is missing pixels. All input
hashes are checked again after rendering. A successful test exit without the
expected exported files is an error. The prototype does not implement a general
XMP schema and must not silently become a production importer.

The observed `developed/brightroom-engine-010` run contains neutral, L1007620 and
A10 PNGs and two sRGB JPEG previews. The minimum alpha was 255 on all three
PNGs. The production RAW intermediate is 16-bit
floating-point extended-linear Display-P3 (192 MB at 24 MP). Final PNGs are
16-bit Display-P3. The frozen post-development calibration TIFF remains unchanged.

## A10 point curves and active controls

The [A10 experiment](A10/README.md) adds verified group-isolation references,
an experimental `PointCurveFeature`, and replay modes for isolated curves,
Light/Mixer groups, and the partial full preset. Point curves improve in
isolation; the initial full partial preset's p95 regressed. The subsequent
[measured Mixer](Mixer/README.md) reduces full A10 p95 from 0.1313 to 0.09145. The optional
[Light experiment](Light/README.md) further lowers it to 0.08015, while a mixed
Light chart still regresses.
All stages remain recorded, including unsupported controls and the substantial
remaining Light mismatch. This is still a partial XMP interpretation.

## Acquire an explicit reference manifest

`prepare-reference-export.py` prepares a local Lightroom SDK plugin job from
an existing `cases.json` after `A10/embed-inputs.swift` has created its TIFFs:

```sh
python3 Tools/LightroomComparison/prepare-reference-export.py \
  .tmp/xmp-research/new-set/cases.json \
  '/absolute/path/to/Research.lrcat' .tmp/BrightroomReferenceExporter.lrplugin
```

Add that plugin once through Lightroom's Plug-in Manager. In the named research
catalog, invoke **Library > Plug-in Extras > Export prepared Brightroom references**.
This adds only the manifest's exact paths in place and exports only those photos;
it does not open the device import dialog or copy originals into Pictures. The
job checks the catalog path, input directory and SHA-256 before catalog writes,
checks authored numeric settings, and refuses an existing export directory.
Loading the plugin alone does not start a job. `acquisition.log` records each
addition/export and final count; failures retain partial evidence for inspection.

Continue with `A10/inspect.swift` and `A10/register.py`; a successful SDK export
does not replace verification of all resolved settings, profile, precision and
hashes. This workflow still requires a running Lightroom Classic instance.

To reproduce the earlier `brightroom-engine-007` experiment, add
`--light-calibration .tmp/xmp-research/adjustments-001 .tmp/xmp-research/response-model-001`
to `develop-xmp.py`, running it with the NumPy-enabled analysis environment.
The calibration TIFFs remain frozen, and `configuration.json` records exactly
which point controls were enabled. This opt-in path uses Core Image Highlights
and Shadows and the frozen experimental Whites, Blacks and Saturation tables.
