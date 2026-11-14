# Measured Color Mixer approximation

`ColorMixerFeature(bands: ..., algorithm: .lightroomApproximation)` explicitly
selects the experimental post-development model. The default remains `.oklch`.
The authored bands and algorithm reconstruct the feature; no XMP codec, Adobe
profile, picture-specific correction, or photograph is embedded in the library.

The model combines signed eight-band selection weights before sampling a
uniform-strength response. Luminance, Saturation, then Hue run in linear
Display-P3. Each pass uses a 24-cubed encoded-P3 lattice and tetrahedral
interpolation of RGB deltas. The achromatic diagonal stays unchanged. Extended
input values retain their original headroom with a boundary delta added; this
policy does not reproduce Adobe HDR. Parameter endpoints are sampled, but
arbitrary combinations and scenes remain approximate.

The LZFSE resource is 2,178,574 bytes, with 3,566,604 bytes of binary16 data
expanded to about 7.1 MB of Float32 values. A single compiled-edit cache retains
three delta tables, about 0.66 MB. Existing graphs retain their own tables;
slider history is not cached. Binary16 decoding supports Intel and Apple silicon.

## Evidence

All values below are 95th-percentile maximum absolute RGB channel error in
linear Display-P3, white = 1. They are not Delta E or a compatibility score.
Photos use every pixel of the same frozen 6000 × 4000 developed TIFF.

| Case | Previous OKLCh adapter | Measured Mixer |
|---|---:|---:|
| A10 Mixer, chart | 0.162737 | 0.014428 |
| A10 Mixer, photo | 0.046029 | 0.003949 |
| Earlier mixed holdout, photo | 0.147493 | 0.003765 |
| Fresh mixed holdout, chart | 0.167015 | 0.004599 |
| Fresh mixed holdout, photo | 0.286114 | 0.004685 |
| Full partial A10, photo | 0.131323 | 0.091450 |

The fresh holdout was acquired after freezing the model: Green Hue -41,
Orange Saturation -19, Blue Luminance +34, Magenta Hue +24, Yellow Luminance -12.
Earlier development cases informed algorithm selection, so they are not an
untouched final test. The fresh combination still uses the same photo; broader
scene coverage remains unverified. Maximum errors and full hashes are retained
in `measurements.json`, not hidden behind p95.

For full A10, the older legacy-curve adapter scored 0.103922. Replacing curves
alone worsened it to 0.131323; replacing Mixer then lowered it to 0.091450.
New-Mixer ablations: no curves 0.096556, no Mixer 0.084965, no Light 0.036981.
These percentiles are not additive contributions and do not prove an error
cancellation mechanism. Light, parametric curves, presence and other unsupported
controls remain substantial sources of error.

## Reproduce the resource

Prepare independent cases with `A10/prepare-adjustments.py`, and uniform
responses with `Mixer/prepare-responses.py`. Embed, acquire, inspect and register
using the parent README. Never regenerate a frozen reference directory.
Decode both analytic reference sets with `Mixer/decode.swift` into `decoded/`.
Only 48 single-band ±50 cases, 24 uniform cases and their two neutrals train this
model. A10, photos and held-out parameter responses are never read by the builder.

```sh
.tmp/xmp-analysis-venv/bin/python Tools/LightroomComparison/Mixer/build-calibration.py \
  .tmp/xmp-research/adjustments-001 .tmp/xmp-research/response-model-001 \
  /tmp/mixer-new.bin /tmp/mixer-new.json
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  xcrun swift -module-cache-path .tmp/swift-module-cache \
  Tools/LightroomComparison/model-codec.swift compress \
  /tmp/mixer-new.bin /tmp/mixer-new.lzfse
```

The builder verifies the source export hashes against frozen registration and
records decoded hashes. `calibration.json` names the 74 consumed references.
The reproduction matched both raw and compressed data bit-for-bit:

- Raw: `96a0fea624dfc342401ce5a965824c8e6ec52727a589709ddef61c397995aa1b`
- Compressed: `bf345bfc86318aad842b8ef74d88d17e92ca25ffa86bf17ba1fbf2a7b06f8470`

```sh
python3 Tools/LightroomComparison/A10/run.py \
  .tmp/xmp-research/a10-001 .tmp/xmp-research/runs/new-mixer-run \
  --developer-dir /Applications/Xcode-27.2.0.app/Contents/Developer \
  --scope mixer --calibrated-mixer
```

Use `--scope ablation --modes calibrated` for full A10 and leave-one-group-out
comparisons. Retain the existing baselines. The loop snapshots source, parameters,
images and hashes, and does not automatically label the results compatible.

Verification: 18 tests passed for measured controls, neutral/alpha behavior,
original OKLCh rendering and still/video working-space independence. After the
portable binary16 reader change, focused tests and the Intel Mac build passed.
All 65,536 binary16 encodings were checked against native Float16 on Apple silicon.
