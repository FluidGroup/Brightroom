# EditingStack Local Adjustment Tile Canvas Specification

## Status

Draft for the Metal Brush Sandbox v1.

This document defines the target behavior for a zoomable, tile-rendered canvas
that previews an `EditingStack` result and adds local adjustment layers with a
brush mask. The first production candidate is still the Sandbox; PixelEditor and
PhotosCrop integration is intentionally out of scope until the rendering and
coordinate contracts are stable.

## References

- Apple Core Image: `CIImage.insertingIntermediate()`
  https://developer.apple.com/documentation/coreimage/ciimage/insertingintermediate()
- Apple Core Image: `CIImage.insertingIntermediate(cache:)`
  https://developer.apple.com/documentation/coreimage/ciimage/insertingintermediate(cache:)
- Apple Core Image: `CIImage.insertingTiledIntermediate()`
  https://developer.apple.com/documentation/coreimage/ciimage/insertingtiledintermediate()
- Apple Core Image: `CIImage`
  https://developer.apple.com/documentation/coreimage/ciimage
- Apple Core Image: `CIContext`
  https://developer.apple.com/documentation/coreimage/cicontext

## Product Goal

Build a Lightroom / Photoshop-like local adjustment canvas:

- A user can freely zoom and pan the edited image.
- Global filters are visible everywhere.
- A brush stroke can add a local adjustment layer, v1 effect: Gaussian blur.
- The local mask is non-destructive and stored in orientation-up original image
  pixel coordinates, not crop-space coordinates.
- Committed tiles display the complete result: source, global filters, local
  adjustments, and crop clipping.
- The live brush layer previews the active local adjustment without waiting for
  committed tile rasterization.
- The interaction target is Apple Photos Edit quality: large images should feel
  inspectable and editable, not merely loadable.

## Benchmark Image Target

The canvas should comfortably handle NASA's VIIRS Blue Marble image:

```text
URL: https://eoimages.gsfc.nasa.gov/images/imagerecords/78000/78314/VIIRS_3Feb2012_lrg.jpg
Compressed JPEG size: about 20 MB
Pixel size: 12000 x 12000
Decoded BGRA/RGBA size: 576,000,000 bytes, about 549 MiB
```

This image is the target scale for the architecture. A single full-resolution
decoded bitmap is already too large to treat as a routine interactive buffer,
and multiple full-resolution intermediates are not acceptable. The interactive
canvas must therefore be viewport-, tile-, and level-of-detail-driven.

Apple Photos Edit handles this class of image comfortably, so this benchmark is
not an aspirational stress case. It represents the baseline user expectation for
a native iOS photo editor. If Brightroom needs to show a degraded path for this
image, that should be treated as an implementation gap in the renderer
architecture rather than a product limitation.

Required implications:

- do not create a full-resolution `UIImage` for interactive preview;
- do not create full-resolution base, blurred, or mask textures for the whole
  image;
- do not render a full-resolution filtered image just to downsample it for a
  zoomed-out viewport;
- choose source LOD from the current zoom and destination tile pixel size;
- keep low-zoom rendering close to display resolution;
- use original-resolution sampling only for tiles that are zoomed in enough to
  need it.

## Non-goals For v1

- Shipping the shared canvas inside PixelEditor or PhotosCrop.
- Full layer UI, reordering, opacity, blend modes, erase mode, or undo history.
- A complete export pipeline rewrite.
- Replacing all Brightroom filters with stateful reusable `CIFilter` objects.
  This can be optimized after the tile canvas contract is proven.

## Coordinate Systems

### Original Image Coordinates

The canonical storage coordinate space for masks is the orientation-up original
image pixel space.

- Origin: top-left after EXIF orientation has been applied.
- Unit: image pixels.
- Extent: oriented original image size.
- Crop never rewrites this data.

### Canvas Coordinates

The Sandbox canvas maps the oriented original image into a fixed canvas rect for
interaction and display.

- Strokes are collected in canvas coordinates while drawing.
- On commit, the stroke is converted to original image coordinates before being
  written to `EditingStack.Edit.LocalAdjustmentLayer.mask`.
- Rendering converts tile canvas rects back to the matching original image
  region.

### Crop Coordinates

Crop is a render-time clipping and transform step.

- Local masks remain in original image coordinates.
- Cropped output clips the already composited image.
- Changing crop must not mutate local adjustment masks.

## Rendering Order

The required order is:

1. Decode source image.
2. Apply source orientation.
3. Apply global filters from `EditingStack.Edit`.
4. Insert a cacheable Core Image intermediate for the global-filtered result
   when it is reused by multiple visible tiles.
5. Apply local adjustment layers:
   - Render the adjusted image, v1: blurred global-filtered image.
   - Render or reuse the mask for the layer.
   - Composite adjusted over base using the mask.
6. Apply `RenderCrop` or crop clipping.
7. Render the requested tile rect into a reusable Metal texture or IOSurface.

The committed tile path must not route through `UIImage`, `UIImageView`, or a
fresh `CGImage` for each update. `CGImage` may still exist as an input source or
export target, but not as the interactive tile transport.

## Core Image Graph Policy

`CIImage` should be treated as an immutable render recipe, not as an already
materialized bitmap. Constructing a new `CIImage` graph is usually cheaper than
rendering it, but in this canvas the same expensive subgraphs are consumed by
many visible tiles. The graph therefore needs explicit reuse boundaries.

### Required Boundaries

- Build a render graph once per edit generation, not once per tile.
- Keep one long-lived Metal-backed `CIContext` for the canvas renderer.
- Render each tile by cropping and transforming the graph into that tile's
  destination texture.
- Reuse Metal destination textures and IOSurfaces while their pixel size is
  unchanged.
- Treat the original image source as a lazy source. `CGImageSource`/file-backed
  input is preferred for large images; `UIImage` is only acceptable for small
  demo images or already-decoded app assets.

### Large Source Strategy

The renderer needs an explicit source abstraction that can answer:

- image metadata and orientation without decoding the full image;
- low-resolution preview images for zoomed-out display;
- tile-sized or LOD-sized render input for the current destination pixel size;
- original-resolution input only when the visible tile needs it.

For ordinary JPEG, true arbitrary region decode may not be available in the way
tiled image formats provide it. The fallback strategy is to build or cache a
bounded image pyramid:

- small overview LODs via `CGImageSourceCreateThumbnailAtIndex`;
- display tile render from the closest sufficient LOD;
- high-zoom tiles from original-resolution sampling;
- optional background prewarming for nearby tiles and LODs.

The key invariant is that the interactive path never requires several
full-resolution 12000 x 12000 intermediates to exist at the same time.

The expected shape is closer to Photos than to a document viewer with one giant
backing image:

- persistent source object with metadata-first loading;
- multi-resolution display pyramid or equivalent Core Image / ImageIO cache;
- tile render requests driven by viewport and zoom;
- bounded concurrent render queue;
- cancellation and generation checks for superseded edits;
- immediate low-resolution feedback followed by sharper replacement when needed.

### Intermediate Insertion

Use Core Image intermediates as explicit graph checkpoints:

- Use `insertingTiledIntermediate()` for the global-filtered base image when the
  result is sampled by many independent display tiles.
- Use `insertingIntermediate(cache: true)` only for subgraphs that are expensive
  and stable for the current edit generation. Example: a blurred image reused by
  several local-adjustment tiles.
- Avoid forcing a full-image blurred intermediate while the blur radius is zero
  or no visible tile intersects a local mask.
- Do not use intermediates to hide excessive tile concurrency. Scheduling must
  still be bounded.

Apple's contract matters here: `insertingIntermediate()` adds a cacheable
intermediate, but it follows the context's `cacheIntermediates` behavior.
`insertingIntermediate(cache: true)` can force cacheability even when the context
would otherwise not cache intermediates. `insertingTiledIntermediate()` is the
preferred candidate for a zoomable canvas because the consumer naturally asks for
rectangular tile regions.

### Filter Instance Reuse

Reusing `CIFilter` instances can reduce object churn, but it is a secondary
optimization and must not leak mutable filter state across concurrent renders.

The v1 contract is:

- The render graph owns any reusable filter instances.
- A filter instance is used on one serial render queue or protected by a clear
  ownership boundary.
- The public `EditingStack.Edit` model remains value-based and non-destructive.
- The tile renderer receives immutable `CIImage` graph outputs for the current
  edit generation.

## Tile Canvas Requirements

### Tile Sizing

Tile layer frames are in canvas points. Backing texture size is derived from
display need:

```text
pixelWidth  = ceil(tileFrame.width  * zoomScale * screenScale)
pixelHeight = ceil(tileFrame.height * zoomScale * screenScale)
```

When zoomed out, a tile may cover a large logical image region but should be
backed only by approximately display-resolution pixels. When zoomed in, the tile
grid may split into smaller logical regions to keep per-tile backing textures
bounded.

### Scheduling

- Rendering work is serial or explicitly bounded. It must not spawn one
  concurrent Core Image render per visible tile without backpressure.
- A new edit generation cancels or supersedes older tile jobs.
- Zoom interaction may keep old tiles visible until replacement tiles are ready.
- Tile transitions must not clear a visible region before the replacement tile
  has valid contents.

### Memory

- Tile display IOSurfaces are reused when possible.
- Scratch textures are pooled by pixel size and capped.
- The canvas must not retain textures for historical zoom levels after they are
  no longer visible or part of an active transition.
- Exposure and other global slider updates should rewrite existing destination
  buffers rather than allocating a fresh IOSurface per tick.

## Live Brush Requirements

The live layer is an `MTKView` overlay.

- Target refresh rate: up to 120 Hz when the device supports it.
- It renders only the active stroke's preview.
- Its texture size follows the viewport's drawable pixel size, not the full
  original image size.
- It uses the same mask brush shader as committed rasterization.
- When a stroke is committed, the live layer remains visible until the affected
  committed tiles have replacement contents, avoiding a flash between live and
  committed states.

## EditingStack Model

`EditingStack.Edit` owns local adjustments:

```swift
struct LocalAdjustmentLayer {
  var id: UUID
  var isEnabled: Bool
  var effect: LocalAdjustmentEffect
  var mask: LocalAdjustmentMask
}

enum LocalAdjustmentEffect {
  case gaussianBlur(radius: Double)
}
```

The model contract:

- Layers are part of the edit model, not view-local state.
- Masks are stored in orientation-up original image coordinates.
- The Sandbox may keep a temporary active stroke outside the model until commit.
- The committed tile renderer observes edit generation changes and invalidates
  only affected tiles when possible.

## Debugging And Observability

The renderer should expose logs that answer:

- Which tile rect is being rendered?
- What pixel size and contents scale are used?
- Which path was used: base-only, local-adjustment composite, live preview?
- Which edit generation and tile generation produced the result?
- Was a render skipped because it was superseded?
- Was a cached intermediate expected to be reused?

Logs should be compact enough to leave enabled in Sandbox development, but
should be gated behind an `OSLog` category or debug flag before production use.

## Current Known Issues

These are the current gaps between the target design and the observed Sandbox
behavior. They should be treated as active implementation and validation tasks,
not as accepted trade-offs.

### Interactive Filter Latency

Exposure and other global filter sliders can still feel behind the finger on
device. The desired behavior is that parameter changes rebuild a lightweight
render graph and rewrite existing tile buffers without allocating new display
surfaces. The current implementation has buffer reuse, but it still needs
profiling to prove:

- the profiling path is not dominated by SwiftUI view invalidation from
  high-frequency slider state;
- tile renders are not queued faster than they can be consumed;
- Core Image is not re-evaluating the same global-filtered subgraph for every
  visible tile;
- `insertingTiledIntermediate()` or `insertingIntermediate(cache: true)` improves
  real device latency without causing memory spikes;
- `CIFilter` instance reuse would reduce meaningful object churn rather than
  adding unsafe mutable shared state.

### Core Image And IOSurface Warnings

Device logs have shown repeated compressed-photo IOSurface creation failures and
a Core Image working-format warning. The intended canvas path should not create a
new `CGImage` or `UIImage` for interactive tile updates, but the source image
decode and Core Image input path still need validation on device.

Required checks:

- identify whether `IOSurfaceName = CMPhoto` logs still originate from the input
  image source after the decoded `CGImage` path;
- ensure the canvas `CIContext` working format is one Core Image accepts for
  Metal rendering;
- confirm that these logs do not repeat on every slider tick, zoom step, or tile
  render.

### Tile Update Consistency During Zoom And Drawing

Rapid zooming while drawing has shown cases where some tile regions update late
or appear not to update. The target behavior is that old tiles remain visible
until replacements are ready, then the transition swaps atomically.

This area still needs stress validation for:

- generation cancellation of superseded tile jobs;
- invalidating every tile intersecting a committed stroke;
- preventing stale fallback layers from covering newer rendered content;
- ensuring serial or bounded scheduling does not starve visible tiles while a
  zoom gesture is still producing new tile grids.

### Tile Size And LOD Validation

The View Debugger can show very large `CALayer.frame` values because frames are
in canvas points. That is acceptable only if the actual backing IOSurface is
near display resolution for the current zoom level.

The current renderer needs instrumentation that logs, per tile:

- logical frame in canvas points;
- visible intersection;
- zoom scale and screen scale;
- backing pixel size;
- render path, either base-only or local-adjustment composite.

This should make it clear when zoom-out uses display-resolution downsampling and
when zoom-in splits into smaller logical tiles.

### Filtered-only Diagnostic Mode

The Sandbox should keep a render mode that isolates the global-filtered image.
In this mode the committed renderer draws only the base `CIImage` produced by
source orientation, canvas scaling, and global filters.

Disabled work in this mode:

- Gaussian blur graph construction;
- live blur preview texture rendering;
- brush mask texture rasterization;
- base / blurred / mask composite pass.

This mode exists to answer whether the bottleneck is already present in the
global filtered image render, or whether it appears only after local blur and
mask composition are added.

The Sandbox UI is also expected to keep high-frequency controls in UIKit rather
than SwiftUI `@State` while profiling this path. SwiftUI should host the screen
shell only; Exposure and render-mode changes should flow directly to the UIKit
canvas/controller layer so Instruments captures the tile renderer instead of
SwiftUI control invalidation.

### Viewport-only Diagnostic Mode

The Sandbox should also keep a Viewport diagnostic render mode. This mode
bypasses the committed `CALayer` tile grid entirely and renders the current
visible rect of the filtered base `CIImage` directly into the viewport-sized
`MTKView` drawable.

Disabled work in this mode:

- committed tile layer creation and invalidation;
- IOSurface display buffer allocation;
- per-tile render scheduling;
- local blur graph construction;
- brush input and live local-adjustment preview.

This is not the target editing architecture, because it does not preserve
committed local adjustments or PencilKit-like tile backing. It exists to answer
one performance question: if a single viewport render is still slow, the
bottleneck is in source decode / Core Image filter evaluation / drawable render.
If it is fast while `Filtered` tile mode is slow, the bottleneck is tile
scheduling, tile count, IOSurface/CALayer transport, or repeated per-tile Core
Image source binding.

### Viewport Full Diagnostic Mode

The Sandbox should also keep a `VP Full` diagnostic render mode. This mode
bypasses the committed `CALayer` tile grid like `Viewport`, but keeps the local
blur and committed mask composite in the single `MTKView` path.

Disabled work in this mode:

- committed tile layer display and invalidation;
- IOSurface display buffer allocation;
- per-tile render scheduling.

Enabled work in this mode:

- Gaussian blur graph construction;
- base and blurred visible-rect Core Image renders;
- committed stroke mask rasterization;
- base / blurred / mask composite pass.

This mode exists to separate the tile transport and scheduling cost from the
local-effect cost. If `VP Full` stays fast while `Full` tile mode is slow, the
interactive preview should likely use a viewport renderer as the main display
while committed tiles update later for cache or quality. If `VP Full` is slow,
the next profiling split should isolate blur texture creation, mask texture
rasterization, and composite independently.

### Viewport Cached Source Diagnostic Mode

The Sandbox should keep a `VP Cached` diagnostic render mode that materializes
the current visible source rect into a viewport-sized Metal texture before
global filters, local blur, mask rasterization, and composite are evaluated.

Expected behavior:

- pan/zoom changes invalidate the viewport source texture;
- filter and blur slider changes reuse the same viewport-sized source texture;
- global filters run against the small `CIImage(mtlTexture:)` source rather than
  the original large image graph;
- local blur and mask composite stay in viewport-sized textures.

This mode exists to test whether interactive cost can be bounded primarily by
the drawable size instead of the original image size. It is still possible that
the initial source materialization remains expensive for huge `CGImage` backed
inputs because Core Image may still need to bind or decode the large source.
The important trace question is whether source binding disappears from slider
updates after the viewport source texture is cached.

### Live And Committed Visual Parity

The live preview and committed tile output must match in position, alpha, and
color. Previously observed symptoms include a slightly different live opacity or
color and a flash when a stroke moves from live rendering to committed tiles.

Open validation work:

- compare live mask shader output and committed mask shader output using the
  same brush parameters;
- verify that premultiplied alpha and color-space choices are identical between
  live overlay composition and committed tile composition;
- keep the live layer visible until affected committed tiles have valid
  replacement contents.

### Mask Rendering Path Split

The Sandbox committed renderer can rasterize brush masks with Metal, but the
engine-level `EditingStack.Edit.LocalAdjustmentMask.makeCIImage(size:)` path
still uses a UIKit bitmap renderer and then wraps a `CGImage` as a `CIImage`.
That may be acceptable for export or compatibility, but it is not the desired
interactive transport for the shared tile canvas.

Before PixelEditor or PhotosCrop adopt this canvas, the mask path should be
split explicitly:

- interactive preview: Metal mask texture or cached CI/Metal-backed mask;
- engine/export compatibility: existing `CGImage` mask path until replaced;
- tests: prove both paths produce equivalent mask coverage.

### Crop Integration

The v1 Sandbox primarily validates un-cropped canvas behavior. The specification
requires masks to stay in original image coordinates while crop is applied only
at render time. This still needs direct tests that change crop after local masks
exist and verify that cropped output clips the adjustment without moving the
mask.

### Test Coverage

The current Maestro flow is useful as a smoke test, but it is not enough to
prove the tile canvas. Meaningful automation should cover:

- view mode versus draw mode;
- double-tap zoom and pan in view mode;
- drawing after zoom and pan;
- exposure changes while zoomed;
- blur radius changes with and without committed masks;
- reset after local adjustments;
- assertions based on logs or screenshots that tile renders happened at the
  expected pixel sizes.

## Acceptance Criteria

- Global filter-only updates apply in near real time without unbounded allocation.
- The 12000 x 12000 NASA benchmark image can zoom, pan, and update Exposure
  without routinely allocating full-resolution intermediates.
- `Blur = 0` produces the same visual output as no local adjustment.
- With `Blur > 0`, only the painted region changes.
- Live stroke position matches committed tile position at 1x and high zoom.
- Zooming and panning do not move existing local masks.
- Repeated zooming does not grow memory indefinitely.
- Tile jobs remain bounded during rapid zoom and slider changes.
- No interactive path repeatedly creates `CGImage` or `UIImage` outputs.
- The implementation can explain, through logs, why a given tile was rendered.

## Open Questions

- Whether `insertingTiledIntermediate()` should be applied to the global-filtered
  image unconditionally, or only once the visible tile count exceeds one.
- Whether the blurred local-adjustment source should be cached per blur radius
  for the full canvas, or rendered only for tiles that intersect local masks.
- Whether global filters should move to reusable `CIFilter` instances inside a
  canvas render graph after profiling confirms object churn is meaningful.
- How to share this canvas with PixelEditor and PhotosCrop without coupling those
  products to Sandbox-only debug controls.
