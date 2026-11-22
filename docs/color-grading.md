# Color grading

`ColorGradingFeature` holds shadows, midtones, highlights and global corrections.
Each correction has hue, saturation and luminance; blending and balance control
the tonal weights. The standard calculation uses analytic weights, gain and tint
in extended-linear Display-P3, preserving input extent and alpha.

These are lightweight standard calculations, not Lightroom-fitted responses.
Install a provider through [Feature implementation setup](adjustment-rendering.md)
to replace the calculation without changing authored values or history.
