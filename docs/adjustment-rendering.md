# Replaceable adjustment rendering

## Design and scope

Feature values remain the editing vocabulary. An immutable `AdjustmentRendering`
belongs to a renderer or host, never an `EditingDocument` or its history. It
travels in `FeatureEvaluationContext` through static composition and local
adjustments. There is no global selection or string-dispatch registry.

`AdjustmentImplementation` has typed entry points for `ExposureFeature` and
`HighlightsShadowsFeature`. The latter is intercepted before its `body` applies
interaction compensation, so implementations receive both original amounts.
Returning nil explicitly delegates an unsupported adjustment to its original
recipe; throwing is a failure, never permission to fall back. A context with
`usingStandardAdjustments()` permits explicit nonrecursive standard delegation.

Selection is deliberately named `overridingSupportedFeatures(with:)`: choosing
it is consent to replace the algorithms of supported feature types. Standard
selection preserves every existing algorithm and numeric interpretation.
Unhooked feature types retain their original behavior under either selection.

The implementation supplies a semantic identity including its version and all
output-affecting settings/model hashes. Equal identities promise interchangeable
output. Hosts combine this with their source, feature values, time, scale and
output options; a Feature RenderKey alone is not an output cache key. Changing
selection invalidates canvas recipes and downstream bakes without decoding the
source again or writing edits back.

This slice builds an actual external GradingKit runtime and carries the same
selection from preview to export/video. It does not move existing calibration
models, introduce missing adjustment types, or claim Lightroom equivalence.
