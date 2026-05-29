# Vision of Editing

## Status

Working vision.

This document describes the direction Brightroom should move toward as an
editing engine. It is not a description of the current implementation, and it
does not require every built-in UI to expose this model immediately.

The central goal is to bring an Onshape-like parametric editing concept to image
editing: each edit is an explicit operation with parameters, later operations
receive the result of earlier operations, and the whole document remains
recomputable from source material and edit parameters.

## Core Idea

Brightroom should be able to represent an edit as a parametric stack:

```text
Source Image
  -> Crop
  -> Mask
  -> Adjust
  -> Crop
  -> Mask
  -> Adjust
  -> Output
```

Each step is non-destructive. A crop does not permanently cut pixels away; it
defines the image domain passed to the following steps. A mask does not bake an
adjustment into the base image; it defines where a later adjustment applies.
An adjustment does not mutate the previous image; it describes a transformation
from input image to output image.

The important property is that downstream operations see the result of upstream
operations. A second crop can crop the already-cropped result. A mask can be
drawn on the current output of the previous steps. Another adjustment can then
operate only inside that mask.

## Parametric Stack

The engine should treat editing operations as data. An operation should be
serializable, inspectable, reorderable when valid, and re-renderable.

Conceptually:

```swift
struct EditingDocument {
  var source: ImageSource
  var operations: [EditingOperation]
}

enum EditingOperation {
  case crop(CropParameters)
  case geometryCorrection(GeometryCorrectionParameters)
  case mask(MaskParameters)
  case adjustment(AdjustmentParameters)
  case filter(FilterParameters)
}
```

This shape is intentionally broader than the current UI. A UI may present a
simple Photos-like editor, but the engine should still be able to describe a
deeper sequence.

## Operation Semantics

### Crop

Crop is a domain operation. It defines the visible and renderable extent passed
to the next operation.

The ideal crop operation should include:

- crop extent
- rotation
- perspective or geometry parameters, if supported later
- output aspect ratio policy, if the crop is constrained

Cropping should be repeatable:

```text
Crop(original image)
  -> Mask(cropped result)
  -> Crop(masked adjusted result)
```

This means crop cannot be treated only as a final export option. It must also be
valid as a middle operation in the stack.

### Geometry Correction

Geometry correction is a domain-transforming operation. It includes perspective
or keystone correction, and it changes how later operations map onto the image.

The ideal geometry correction operation should include:

- source control points
- destination control points
- interpolation policy
- output extent policy
- transparent or clamped edge policy

Geometry correction is not only a visual filter. It changes the coordinate
meaning for every operation that appears after it. A mask painted before the
correction is warped by the correction. A mask painted after the correction is
authored in the corrected domain.

### Mask

Mask is a selection operation. It creates a grayscale or alpha field that later
operations can use as input.

The ideal mask operation should support:

- brush strokes
- erase strokes
- generated masks, such as subject, sky, depth, or luminance masks
- mask refinements, such as blur, feather, invert, add, subtract, and intersect

Mask coordinates need a clear contract. For early Brightroom work, masks are
often easiest to store in oriented original image coordinates. In a fully
parametric stack, a mask that appears after a crop may instead be authored in the
current operation domain. The engine should make this explicit rather than
letting UI coordinate systems leak into the document format.

### Adjust

Adjust is a transform operation. It takes an input image and produces an output
image.

The ideal adjustment operation should support:

- global adjustment
- local adjustment using a referenced mask
- compositing adjusted output over base using mask alpha
- adjustment groups, if the UI later needs grouped controls

An adjustment should not need to know whether its input came from the original
image, a crop, another adjustment, or a generated intermediate. It should only
need an input `CIImage`, parameters, and an optional mask.

## Core Image Graph

If this model is done well, the rendering language can mostly be a Core Image
graph.

Each operation can be compiled into a `CIImage -> CIImage` transform:

```text
CIImage source
  -> crop filter / affine transform / clamp policy
  -> mask generation or mask lookup
  -> adjustment filter chain
  -> crop filter / affine transform / clamp policy
  -> adjustment filter chain
  -> final CIImage
```

Core Image already represents lazy image recipes. Brightroom should lean into
that property instead of eagerly materializing full-size images between every
step. The engine can insert intermediates, caches, or tiled rendering where
needed, but those should be evaluation strategies for the same parametric graph,
not separate editing semantics.

Important implications:

- The document stores parameters, not baked pixels.
- Rendering compiles parameters into a `CIImage` chain.
- Export and preview can evaluate the same graph at different quality,
  resolution, and caching policies.
- Flattening or baking is an optimization, not the primary document model.

## UI Responsibilities

The engine should be able to express the full parametric stack. The UI does not
need to expose unlimited depth.

Performance will degrade as the stack grows. That is expected. The UI should
control this with product-level constraints:

- limit the number of visible layers or operations
- offer flattening when the stack becomes expensive
- warn before destructive simplification
- choose preview quality during interaction
- collapse advanced graph structure into simpler controls for specific editors

The engine should not avoid representing the parametric model just because a
particular UI cannot make every graph comfortable to edit.

## Rendering Responsibilities

The renderer should support different evaluation modes for the same document:

- viewport preview for interactive editing
- still preview for settled UI state
- high-quality export
- thumbnail rendering
- mask-only inspection
- debug rendering for individual operations

All of these modes should compile from the same operation stack. They may choose
different caching and resolution strategies, but they should not invent separate
meaning for crop, mask, or adjustment.

## Coordinate Direction

The hardest part of this vision is coordinate ownership.

The engine should define explicit domains:

- source image domain
- current operation domain
- mask authoring domain
- output domain
- viewport display domain

UI gestures live in viewport display coordinates. Stored edits should not.
Every gesture should be converted into the correct operation domain before it is
committed to the document.

This becomes especially important when operations repeat:

```text
Crop A
  -> Mask B
  -> Crop C
  -> Mask D
```

`Mask B` and `Mask D` may not share the same coordinate meaning. The document
model should make that obvious.

## Operation Order and Painting Semantics

Parametric editing makes operation order fully expressible. This matters for
painting tools such as blur masks because brush geometry is part of the edit,
not just a temporary input device event.

Consider perspective correction:

```text
Source
  -> Mask
  -> Geometry Correction
  -> Adjust
```

In this sequence, the user paints in the pre-correction domain. The correction
warps the painted mask along with the image. A round brush stroke may become
non-uniform after the perspective transform, and the apparent brush width may
change across the corrected output.

The reverse order has different semantics:

```text
Source
  -> Geometry Correction
  -> Mask
  -> Adjust
```

Here, the user paints in the corrected domain. The brush width is uniform in the
corrected image, and the stored stroke geometry belongs to the post-correction
operation domain. If the renderer needs to sample from source pixels, it uses
the inverse operation chain to map the corrected-domain mask back to the source
image.

Both are valid. They should be represented as different operation stacks, not as
ambiguous flags on a single mask. This is one of the main reasons the document
model needs explicit operation domains and a renderer that can compile the full
chain.

The same rule applies to crop-like tools. A UI may let the user adjust the crop
frame before opening a painting tool, but the engine still needs to define
whether that means:

```text
Source
  -> Crop
  -> Mask
  -> Adjust
```

or:

```text
Source
  -> Mask
  -> Adjust
  -> Crop
```

Those are different documents. In the first document, the mask is authored in
the cropped domain. In the second document, the mask is authored before the
final crop, and the crop clips the already-adjusted image.

## Near-Term Direction

PhotosCrop blur masking is a useful first pressure test because it already wants
the current Crop and Tool relationship to behave like:

```text
Source
  -> Tool Operations
  -> Final Crop
  -> Output
```

In other words, the current PhotosCrop UI may visually use the crop frame as the
editing window, but the engine semantics should treat Blur Masking, Filters, and
Adjustments as operations that happen before the final Crop. Crop is the final
framing/clipping operation for this UI path.

The next step is to make that shape feel natural rather than special-cased:

- Tool operations are authored in the pre-final-crop image domain.
- The crop frame acts as the UI viewport and final clipping boundary.
- The mask renderer should not draw crop-external pixels in this UI path because
  the preview is showing the final cropped output.
- Tool zoom and pan inspect the final-cropped result without mutating crop.
- Later filters and adjustments can attach to the same pre-final-crop tool
  operation model.

This should be treated as a small UI expression of the larger parametric engine,
not as a one-off PhotosCrop feature.

## Open Questions

- Should masks after a crop be stored in source image coordinates, current
  operation coordinates, or both with an explicit transform?
- Should mask strokes store brush width in the authoring operation domain, or
  should some tools opt into screen-space width that is reprojected at render
  time?
- How should operation references work when an adjustment depends on a mask
  generated by an earlier operation?
- What is the smallest public data model that can express repeated
  crop-mask-adjust sequences without overfitting to a layer UI?
- Where should Brightroom expose flattening: document operation, renderer cache,
  or UI-only workflow?
- How much of the current `EditingStack.Edit` shape can evolve into this model
  without a disruptive migration?
