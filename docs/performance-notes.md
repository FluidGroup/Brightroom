# Performance Notes

## Status

Working notes. Measurements taken 2026-06-13 after the Engine→Parametric
convergence, on an iPhone 17 Pro Simulator (iOS 26.5). Interactive use feels
fast; nothing here is a known regression. This document records where the CPU
time goes and the improvement opportunities worth keeping on the radar.

## How to reproduce the measurements

Two complementary methods — the simulator cannot be profiled by headless
`xctrace` (attach succeeds but captures an empty run), so use these instead:

1. **Deterministic per-path numbers** — `EnginePerformanceWorkloadTests`
   (`measure` with `XCTClockMetric` + `XCTCPUMetric`). CPU Instructions Retired
   is the device-portable metric; simulator wall-clock GPU time is **not**
   device-representative.

   ```bash
   cd Dev && xcodebuild test \
     -scheme BrightroomEngineTests \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
     -only-testing:BrightroomEngineTests/EnginePerformanceWorkloadTests
   ```

2. **Call-tree / flame graph** — Instruments GUI (CPU Profiler). The GUI *can*
   profile a Simulator process: Device dropdown → Running Simulators → attach to
   `SwiftUIDemo`, record, drive PhotosCrop, stop, then Invert Call Tree.

For a true device-accurate flame graph (including GPU), record on a real device
with Instruments / `xctrace record --device <udid>`.

## Per-path cost (3000×2000, simulator)

| Path | Wall | CPU time | CPU instructions |
| --- | --- | --- | --- |
| Export render (effects + masked blur + crop → CGImage) | ~233 ms | ~39 ms | ~357 M |
| Preview composition (`makePreviewImage(.editing)` → CGImage) | ~216 ms | ~26 ms | ~223 M |
| Parametric eval (5 effects → CGImage) | ~218 ms | ~26 ms | ~222 M |
| Brush-mask raster, cache miss (CPU CoreGraphics) | ~10 ms | — | ~427 M |

**Reading:** wall ~220 ms per render but only 26–39 ms is CPU ⇒ ~85% is Core
Image GPU evaluation + full-resolution CGImage readback. The parametric path is
*not* CPU-bound. Preview ≈ parametric eval (the masked blur adds negligible CPU:
its mask is memoized and the blur is GPU). Export costs ~13 ms / ~130 M more
than preview — the crop (`croppedWithColorspace` CPU copy) plus a full-res
CGImage. The mask raster is the heaviest single CPU op but only on a cache miss,
and `LocalAdjustmentMaskRasterStore` makes repeats free.

## CPU self-time during interactive editing (Instruments CPU Profiler)

From a ~4-minute PhotosCrop session (Adjust slider drags across all parameters,
Filters preset taps, Blur painting, then export), heaviest self-cycles:

| Share | Symbol | What it is |
| --- | --- | --- |
| ~15% | `_platform_memmove` | Image buffer copies (CIImage→CGImage readback, RGBA mask raster, texture↔CIImage) |
| ~12% | `swift_conformsToProtocol…` (+ `MetadataCacheKey==`) | Swift runtime protocol-conformance / existential-cast machinery |
| ~5% | `DplusDM` + `RGBA32_shade_radial_RGB` (CoreGraphics) | CPU brush-mask soft-stamp radial gradient |
| ~4% | `AG::Graph::UpdateStack::update` / `propagate_dirty` | SwiftUI AttributeGraph view diffing (slider-driven re-eval) |
| ~3% | `objc_msgSend` / `swift_retain` | ARC / runtime |

(Aggregate over a session that was mostly idle; read the ranking, not the
absolute %. The conformance cost is a mix of SwiftUI's own generics and the
parametric model's existential casts — its callees are libswiftCore recursion
with no single app caller.)

## Improvement opportunities

Ordered roughly by expected payoff vs. risk. None are blocking; interactive
performance is already good.

1. **Reduce existential-cast churn in the effect pipeline (CPU ~12%, low risk).**
   `EffectPipeline.first(of:)` / `firstIndex(of:)` / `set(_:)` do `as?` / `is T`
   over `[any ImageEffectFeatureType]`, and `parametricFeaturesAreEqual` /
   `isEqualFeature` do dynamic type checks. These run on every slider tick
   (PhotosCrop upserts a typed effect per value change) and per Equatable
   comparison. Candidates: cache the type→index lookup on `EffectPipeline`,
   avoid re-scanning the array per parameter, and short-circuit equality by
   identity/kind before the dynamic compare. Some of the measured cost is
   SwiftUI's, so verify the win with the same Instruments session.

2. **Alpha-only (A8) brush-mask raster instead of RGBA (memmove + raster, med risk).**
   The CPU mask raster allocates and copies a full-resolution RGBA buffer; the
   mask only needs one channel. An A8 raster is ~4× less memory and copy work,
   shrinking both `_platform_memmove` and the `LocalAdjustmentMaskRasterStore`
   footprint (so the cache holds more / larger rasters). Needs falloff parity
   re-verification against the GPU brush shader
   (`testExportMaskReproducesLiveCanvasBrushFalloff`).

3. **GPU-side crop in the export renderer (med/high risk).**
   `renderRevison2` finishes with `croppedWithColorspace`, a full-resolution CPU
   CoreGraphics copy (~13 ms / 130 M instructions of the export cost). A Core
   Image / GPU crop would remove that copy. High risk because
   `RendererDeviceEquivalenceTests` pins crop-edge sampling — any change must
   keep that parity.

4. **Throttle/coalesce preview recomposition during continuous gestures (low risk).**
   Each slider tick recomposes `makePreviewImage` and re-renders the canvas; the
   SwiftUI AttributeGraph churn (~4%) suggests the view tree re-evaluates more
   than necessary. Coalescing rapid value changes (or rendering preview at a
   lower interactive resolution, settling on gesture end) would cut redundant
   full-res work without changing committed output.

5. **Incremental stroke-mask encoding (carried over from the canvas work).**
   The live canvas re-encodes the stroke mask as O(total stamps) per frame; an
   incremental/dirty-region encode would scale better for long strokes. Tracked
   in the canvas architecture notes.

## What is already well-handled

- Mask rasters are memoized (`LocalAdjustmentMaskRasterStore`, 32 MB/entry,
  64 MB total) — repeated previews of the same mask are free.
- `EditingStack.Loaded.editingPreviewImage` only recomputes when the effects
  sequence actually changes (keyed on `effectsSequence`).
- The export and preview share one composition path (proven equivalent by
  `EditingPreviewExportParityTests`), so there is no duplicated render logic to
  optimize twice.
