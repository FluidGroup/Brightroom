# Whites and blacks

`WhitesFeature(amount:)` and `BlacksFeature(amount:)` accept −100…100, with zero
neutral. Their standard recipes use analytic bright-tone gain and dark-tone lift
in extended-linear Display-P3. They need no calibration tables and preserve
input extent and alpha.

These are lightweight standard calculations, not Lightroom-fitted responses.
Install a provider through [Feature implementation setup](adjustment-rendering.md)
to replace the calculation without changing authored values or history.
