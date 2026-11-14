# Color Grading measurements, 2026-11-08

Candidate: ColorGradingFeature, analytic Global + BRCG0001 local curves.
Reference: Lightroom Classic 15.6 / Camera Raw 18.7 / ProcessVersion 15.4.
Same 1024×256 16-bit Display-P3 input; outputs 16-bit ProPhoto RGB.
Measured in extended-linear Display-P3 Float32. Error is maximum absolute RGB
channel difference per pixel; white = 1. These are not Delta E scores.
No compatibility pass threshold has been assigned. Large local-range errors
are unresolved; this implementation is not an Adobe-compatible grading engine.

| Case | p95 | p99 | Maximum |
|---|---:|---:|---:|
| neutral | 0.000170 | 0.000218 | 0.000581 |
| heldout-shadows-0 | 0.000948 | 0.001175 | 0.001599 |
| heldout-shadows-1 | 0.022992 | 0.023710 | 0.024221 |
| heldout-shadows-2 | 0.023594 | 0.024801 | 0.026588 |
| heldout-shadows-3 | 0.001615 | 0.002075 | 0.002522 |
| heldout-midtones-0 | 0.000959 | 0.001142 | 0.001638 |
| heldout-midtones-1 | 0.007301 | 0.008090 | 0.008990 |
| heldout-midtones-2 | 0.006610 | 0.007452 | 0.008257 |
| heldout-midtones-3 | 0.003098 | 0.003733 | 0.004352 |
| heldout-highlights-0 | 0.003940 | 0.004518 | 0.005516 |
| heldout-highlights-1 | 0.057693 | 0.060053 | 0.065188 |
| heldout-highlights-2 | 0.182707 | 0.205630 | 0.217136 |
| heldout-highlights-3 | 0.006670 | 0.007684 | 0.010009 |
| heldout-global-0 | 0.000523 | 0.000605 | 0.000670 |
| heldout-global-1 | 0.000724 | 0.001010 | 0.001165 |
| heldout-global-2 | 0.000465 | 0.000525 | 0.000619 |
| heldout-global-3 | 0.000583 | 0.000724 | 0.000819 |
| heldout-combined-0 | 0.029476 | 0.037638 | 0.041633 |
| heldout-combined-1 | 0.021014 | 0.028855 | 0.032677 |
| heldout-combined-2 | 0.029929 | 0.038325 | 0.042360 |

Four values per range were excluded from calibration:
H37 S33 L0 B50 A0; H211 S65 L0 B35 A−25; H289 S41 L27 B72 A30;
H0 S0 L−35 B18 A67. Combined cases use shadows H225 S35 L12,
midtones H37 S22 L−8, highlights H52 S44 L−17, global H310 S9 L3,
with B50/A0, B35/A−25 and B72/A30 respectively.

The independent 6000×4000 photograph with Global H52/S30 has p95 0.000223249,
p99 0.000261337 and maximum 0.000663042. It was not used to fit the model.
The earlier fixed 32³ lookup prototype had maximum 0.0158916 on this photograph;
the current feature calculates Global directly and removes that observed outlier.

Evidence under the local research root:
`runs/color-grading-feature-003/report.json` and
`runs/color-grading-photo-001/comparison/comparison.json`.
The chart report includes baseline-subtracted response errors separately.
Neutral export p95 is 0.000170469 on this chart and ICC path; it is not zero.

The Global formula was first inferred on separate primary/secondary-hue probes.
Local curves were fitted to 725 grayscale references. The RGB lattice, photograph,
and parameter cases above check generalization. Repeated inspection of these
validation cases is now part of model development; freeze a new set before making
an eventual compatibility acceptance claim.
