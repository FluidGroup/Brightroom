# Vision of Editing

## Status

Working vision.

This document describes the direction Brightroom should move toward as an
editing engine. It is not a description of the current implementation, and it
does not require every built-in UI to expose this model immediately.

The central goal is to bring an Onshape-like parametric editing concept to image
editing: each edit is an explicit Feature with parameters, later Features
receive the result of earlier Features, and the whole document remains
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

The important property is that downstream Features see the result of upstream
Features. A second crop can crop the already-cropped result. A mask can be drawn
on the current output of the previous steps. Another adjustment can then operate
only inside that mask.

## Parametric Stack

The engine should treat editing Features as data. A Feature should be
inspectable, reconstructible from its public parameters, reorderable when
valid, and re-renderable. Storing Features is the host application's
responsibility: Brightroom defines the values and their validation, not a file
format.

In Brightroom's parametric model, "Feature" is the name for each item in the
stack. Crop, Mask, Adjust, Filter, and Geometry Correction are all Features.
Renderer implementation may compile Features into Core Image operations or
transforms, but the document model should expose them as Features.

In Brightroom 6 an edit is a root feature: a static composition of Features.
The source image stays outside it, and `EditingDocument` pairs the two with
the edit's undo history. A root feature that crops, adjusts exposure inside a
mask, and crops again is:

```swift
import BrightroomParametric

struct PhotoFeature: Feature, Equatable {
  var crop: CropFeature
  var localExposure: LocalAdjustmentFeature<ExposureFeature>?
  var finalCrop: CropFeature

  var body: some Feature {
    crop
    localExposure
    finalCrop
  }
}
```

Each member receives the output of the one before it, so `localExposure` is
authored in the domain `crop` produces, and `finalCrop` clips the adjusted
result.

The engine can express any such order; the UI decides how much freedom a
document gives. `ImageEditorFeature` fixes one shape for a simple Photos-like
editor, and another editor can define a deeper sequence with the same
Features.

## Vocabulary

Brightroom names things with the words below. Each concept has one word, and
each word has one meaning; new API and documentation follow this list.

| Word | Meaning | In the API |
| --- | --- | --- |
| Source image | The image an edit is authored over, fixed for a document's lifetime. Its oriented pixel size is the domain the first Feature receives. "Source" means only this: the entry of the chain. | `SourceImage`, `EditingDocument.source`, `SourceImage.pixelSize` |
| Feature | One step of an edit: a value with parameters that turns an input image into an output image. | `Feature`; top-level library types end in `Feature` (`CropFeature`, `ExposureFeature`) |
| Root feature | The Feature a document holds: the whole edit, composed from other Features. | `EditingDocument.feature`, `ImageEditorFeature` |
| Input, output | The image a Feature receives and the image it returns. | `inputToOutputTransform` |
| Effect | A Feature that keeps the extent and domain of its input: an adjustment or a filter. | `ImageEffect` |
| Domain Feature | A Feature that changes the domain later Features work in, such as a crop. | `CropFeature` |
| Adjust, adjustment | An effect with parameters the user tunes, such as exposure. | `ExposureFeature`, `WhiteBalanceFeature` |
| Filter | A named, predefined look, applied as one effect. | `FilterFeature` |
| Mask | A grayscale field that says where a local adjustment applies. It is a parameter, not a Feature. | `Mask`, `BrushMask` |
| Local adjustment | Effects applied only where a mask allows. | `LocalAdjustmentFeature` |
| Document | The source image, the root feature, and the root feature's undo history. The word means only this; a root feature is not a document. | `EditingDocument`, `ImageEditorDocument` |
| Commit | Record the current root feature as an undo step. Only history commits. | `EditingDocument.commit()` |
| Editor | A complete UI that edits a document. | `ImageEditor` |
| Canvas | The view that shows the evaluated result and lets tools edit one Feature. | `ImageEditorCanvas` |
| Viewing point | What the canvas shows: the result of evaluating the Feature stack. | |
| Adjustment point | The Feature a tool edits, which can sit upstream of the viewing point. | `ImageEditorCanvas.editingTarget(_:)`, `ImageEditorCanvas.Target` |
| Display, viewport | The on-screen space of a canvas. Stored edits never use it. | |
| Chain-entry extent | The extent of the image as it entered the chain for one render pass. Proportional radii resolve against it. | `FeatureEvaluationContext.chainEntryExtent` |
| Apply | What a Feature implements: evaluate itself over an input. | `Feature.apply(to:context:)` |
| Make an image | Build a lazy `CIImage` recipe from a Feature. | `FeatureRenderer.makeImage(from:feature:)` |
| Render | Produce pixels, in memory or in a file. | `ExportRenderer.render(from:feature:)`, `EditingDocument.render(options:)` |

## Feature Semantics

### Crop

Crop is a domain Feature. It defines the visible and renderable extent passed to
the next Feature.

The ideal crop Feature should include:

- crop extent
- straightening rotation
- output orientation (quarter turn)
- perspective or geometry parameters, if supported later
- output aspect ratio policy, if the crop is constrained

Cropping should be repeatable:

```text
Crop(original image)
  -> Mask(cropped result)
  -> Crop(masked adjusted result)
```

This means crop cannot be treated only as a final export option. It must also be
valid as a middle Feature in the stack.

### Geometry Correction

Geometry correction is a domain-transforming Feature. It includes perspective or
keystone correction, and it changes how later Features map onto the image.

The ideal geometry correction Feature should include:

- source control points
- destination control points
- interpolation policy
- output extent policy
- transparent or clamped edge policy

Geometry correction is not only a visual filter. It changes the coordinate
meaning for every Feature that appears after it. A mask painted before the
correction is warped by the correction. A mask painted after the correction is
authored in the corrected domain.

### Mask

Mask is a selection Feature. It creates a grayscale or alpha field that later
Features can use as input.

The ideal mask Feature should support:

- brush strokes
- erase strokes
- generated masks, such as subject, sky, depth, or luminance masks
- mask refinements, such as blur, feather, invert, add, subtract, and intersect

In the static model a mask is not a Feature of its own: it is the `Mask`
parameter of the `LocalAdjustmentFeature` that uses it. A stand-alone mask Feature
that later adjustments reference is still an open question (see "Feature
references" below).

Mask coordinates need a clear contract. For early Brightroom work, masks are
often easiest to store in oriented original image coordinates. In a fully
parametric stack, a mask that appears after a crop may instead be authored in the
current Feature domain. The engine should make this explicit rather than
letting UI coordinate systems leak into the document format.

### Adjust

Adjust is a transform Feature. It takes an input image and produces an output
image.

The ideal adjustment Feature should support:

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

Each Feature can be compiled into a `CIImage -> CIImage` transform:

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

- limit the number of visible layers or Features
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
- debug rendering for individual Features

All of these modes should compile from the same Feature stack. They may choose
different caching and resolution strategies, but they should not invent
separate meaning for crop, mask, or adjustment.

## Viewing Point and Adjustment Point

Parametric editing separates the point being viewed from the point being
adjusted.

The renderer may evaluate the full Feature stack and show the user the final
result, while the active tool edits only one Feature in the middle of that
stack. The UI should not assume that the displayed image domain and the edited
Feature domain are the same.

For example, an editor may have this stack:

```text
Source
  -> Tool Features
  -> Crop
  -> View
```

Both Tool mode and Crop mode can show the same evaluated `View`, where Tool
Features and Crop have both been applied. What changes is the adjustment
point:

- Tool mode adjusts `Tool Features`.
- Crop mode adjusts `Crop`.

This is not a contradiction. It is the expected behavior of a parametric editor.
The user should be able to edit an upstream Feature while seeing the
downstream result that will actually be exported.

This distinction is especially important for the canvas (`ImageEditorCanvas`). The current UI should
not be interpreted as "Tool edits happen after Crop" merely because the user
paints through the crop frame. The crop frame can be the viewing window for the
fully evaluated result while Tool Features remain authored before the final
Crop.

## Coordinate Direction

The hardest part of this vision is coordinate ownership.

The engine should define explicit domains:

- source image domain
- current Feature domain
- mask authoring domain
- output domain
- viewport display domain

UI gestures live in viewport display coordinates. Stored edits should not.
Every gesture should be converted into the correct Feature domain before it is
committed to the document.

This becomes especially important when Features repeat:

```text
Crop A
  -> Mask B
  -> Crop C
  -> Mask D
```

`Mask B` and `Mask D` may not share the same coordinate meaning. The document
model should make that obvious.

## Feature Order and Painting Semantics

Parametric editing makes Feature order fully expressible. This matters for
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
Feature domain. If the renderer needs to sample from source pixels, it uses
the inverse Feature chain to map the corrected-domain mask back to the source
image.

Both are valid. They should be represented as different Feature stacks, not as
ambiguous flags on a single mask. This is one of the main reasons the document
model needs explicit Feature domains and a renderer that can compile the full
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

ImageEditor blur masking is a useful first pressure test because it already wants
the current Crop and Tool relationship to behave like:

```text
Source
  -> Tool Features
  -> Final Crop
  -> Vignette
  -> Output
```

In other words, the current ImageEditor UI may visually use the crop frame as the
editing window, but the engine semantics should treat Blur Masking, Filters, and
Adjustments as Features that happen before the final Crop. Crop is the final
framing/clipping Feature for this UI path. The vignette is the exception: the
output frame decides it, so it follows the final Crop (see "Decided
Semantics"), and the canvas draws it over the crop frame, including the crop
guide while it moves.

The next step is to make that shape feel natural rather than special-cased:

- Tool Features are authored in the pre-final-crop image domain.
- The crop frame acts as the UI viewport and final clipping boundary.
- The mask renderer should not draw crop-external pixels in this UI path because
  the preview is showing the final cropped output.
- Tool zoom and pan inspect the final-cropped result without mutating crop.
- Crop mode adjusts the final crop while still viewing the result of Tool
  Features plus Crop.
- Later filters and adjustments can attach to the same pre-final-crop tool
  Feature model.

This should be treated as a small UI expression of the larger parametric engine,
not as a one-off ImageEditor feature.

## Decided Semantics

Decisions made ahead of repeatable crops (2026-08), so that behavior that
currently holds by feature order becomes declared rather than incidental:

- **Mask coordinates are current-Feature-domain.** A mask is authored in, and
  evaluated against, the input domain of its owning Feature at that point in
  the stack. Masks are frame-anchored, not content-anchored: when an upstream
  crop changes, the content under the mask shifts accordingly, and no
  restoration to the original pixels is attempted. This is the parametric
  reading — each Feature is a function of its input — and it means that
  `LocalAdjustmentFeature` rasterizing its mask into its input extent is the
  correct implementation, not a limitation.
- **Proportional (value-form) radii resolve against the render pass's
  chain-entry extent.** A value like
  `GaussianBlurFeature(radius: .proportional(40))` means a fixed fraction of
  the image as it entered the parametric chain for the current render,
  regardless of where crops sit in the feature list. Editing or moving a crop
  can therefore never retroactively change the strength of a committed
  effect. The basis is per-render-pass (the downsampled preview and
  the full-resolution export each resolve against their own entry scale), so
  preview and export stay visually consistent. Render paths that evaluate on
  an intermediate that is not the chain entry (for example a zoomed viewport
  slice) must pass the entry extent explicitly.
- **Crop output orientation is separate from its selection** (decided 2026-09,
  #330). A crop evaluates straighten → crop → exact quarter turn. `rect` is
  the selection after straightening and before the quarter turn, in the crop's
  input domain; the quarter turn changes only the output orientation, never
  the selected pixels. The renderer and the tool surfaces map coordinates
  through the same `CropFeature.OutputGeometry`.
- **Effects decided by the output frame go after the final crop** (decided
  2026-10). An effect whose geometry comes from its input extent, such as a
  vignette centred on its input, belongs to the framed picture, so a root
  feature evaluates it after its final crop (`ImageEditorFeature.vignette`).
  Colour and per-pixel effects, and neighbourhood effects whose radii resolve
  against the chain entry (blur, sharpen), stay before the crop: a crop does
  not change them. An effect inside a filter (`FilterFeature`) is part of
  that look and stays where the filter is.

## Open Questions

- Should mask strokes store brush width in the authoring Feature domain, or
  should some tools opt into screen-space width that is reprojected at render
  time?
- How should Feature references work when an adjustment depends on a mask
  generated by an earlier Feature? Features have no identity in Brightroom
  6, so a reference would be structural (a member of the root feature)
  rather than an identifier.
- What is the smallest public data model that can express repeated
  crop-mask-adjust sequences without overfitting to a layer UI?
- Where should Brightroom expose flattening: a Feature in the edit, a
  renderer cache, or a UI-only workflow?
