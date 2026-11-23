# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Brightroom is a composable image editor library for iOS and macOS, powered by Metal for high-performance image processing. It provides both low-level image editing capabilities and high-level UI components (on macOS, BrightroomUI has the built-in editor, with filters, adjustments and a histogram, and the canvas as a viewer; crop and brush editing are iOS only).

## Build Commands

### Building via Xcode Project (Recommended)
```bash
# Build BrightroomUI (includes BrightroomEngine and BrightroomParametric)
cd Dev && xcodebuild -scheme BrightroomUI -destination 'generic/platform=iOS Simulator' -skipMacroValidation -skipPackagePluginValidation build

# Build BrightroomUI for macOS
xcodebuild -scheme BrightroomUI -destination 'platform=macOS' -skipMacroValidation -skipPackagePluginValidation build

# Build SwiftUI Demo app
cd Dev && xcodebuild -scheme SwiftUIDemo -destination 'generic/platform=iOS Simulator' -skipMacroValidation -skipPackagePluginValidation build

# Build ParametricMacDemo (macOS; without the team's signing certificate, add CODE_SIGNING_ALLOWED=NO)
xcodebuild -project Dev/Brightroom.xcodeproj -scheme ParametricMacDemo -destination 'platform=macOS' -skipMacroValidation -skipPackagePluginValidation build
```

Note: `swift build` does not work due to macOS version constraints. Always use `xcodebuild` with the Dev/Brightroom.xcodeproj.

### Running Demo Apps
```bash
# Open the development workspace
open Dev/Brightroom.xcodeproj
```

## Architecture

### Core Modules

1. **BrightroomParametric** - Dependency-free parametric editing vocabulary:
   no package dependencies and no SwiftUI (UIKit only for
   `RenderedImage.uiImage`, under `canImport(UIKit)`; on iOS, UIKit itself
   links SwiftUICore)
   - An edit is a root feature: a static composition of features, the way a
     SwiftUI view composes its body: `Feature`, `ImageEffect`,
     `FeatureBuilder` (`if`, `switch`, `for`, optional members, `#available`)
   - Built-in features (`ExposureFeature`, `GaussianBlurFeature`,
     `CropFeature`, `ToneCurveFeature`, `ColorMixerFeature`, ...),
     `FilterFeature`, `LocalAdjustmentFeature` with a `Mask`, and
     `AnyImageEffect` for content decided by data
   - `FeatureRenderer`, `ExportRenderer`, and `VideoRenderer` evaluate any
     `some Feature` into a Core Image graph
   - `FeatureTreeNode.nodes(for:)` describes a feature's body for
     debugging; BrightroomUI's `FeatureTreeOutline` shows the nodes
   - Crop value types live next to `CropFeature`: `AspectRatio` and
     `QuarterTurn` (the package `CropGeometry` does the fitting math behind
     `CropFeature.fitted(to:imageSize:)` and `pixelAligned(imageSize:)`)
   - Features are plain values compared by their parameters, never by an
     identifier: no `FeatureID`, no `isEnabled`. A filter or a LUT is the
     same when its contents are the same; because a LUT is binary data,
     `FilterFeature.id` and `ColorCubeFeature.id` name it so hosts and
     pickers can tell one from another. Equality still compares the whole
     value.
     The library owns no storage format: apps convert features to their own
     `Codable` models and rebuild them through public, validating initializers
     (`docs/parametric-persistence.md`)

2. **BrightroomEngine** - Source images and editing documents (depends on BrightroomParametric)
   - `Sources/BrightroomEngine/DataSource/` - `SourceImage`: the image a
     document is authored over (data, file, `UIImage`, `CGImage`, RAW, Photos
     asset), with its oriented `pixelSize`
   - `Sources/BrightroomEngine/Core/` - `EditingDocument<Content>` (the source
     image, the root feature, and its commit-style `History`;
     `render(options:)`), and the package `PreviewSourceLoader`. The document
     holds the edit and its history; the loader only prepares preview pixels
     for BrightroomUI's editors: `await load()` decodes the image once, off
     the main actor, into a `PreviewSource` (a thumbnail and the GPU-resident
     editing source) and publishes its `phase` (`.idle`, `.loading`,
     `.loaded`, `.failed`) on the main actor
   - `Sources/BrightroomEngine/Engine/` - internal image decoding
     (`ImageDecoding`) and the preview's GPU upload (`PreviewTextureUpload`)
   - Uses swift-state-graph for observable state (`PreviewSourceLoader.phase`)

3. **BrightroomUI** - SwiftUI image editing components (UIKit internally on
   iOS, AppKit on macOS). On macOS, `ImageEditor` shows the macOS editor
   (its items in the window's toolbar, an inspector of switchable adjustment
   sections with a gray-point eyedropper for white balance, a grouped filter
   strip, a histogram with pointer readouts, Show Original, and zoom) over
   `ImageEditorCanvas`, a viewer that shows the document's evaluated output
   with zoom and pan; crop and brush editing are iOS only for now
   - One SwiftPM target, with three source directories under `Sources/BrightroomUI/`:
     - `Shared/`: public SwiftUI entry points and their availability,
       `ImageEditorFeature` and `ImageEditorDocument`, the editor core
       (`ImageEditorSession`, which decides what both editors write, and
       the macOS editor's `ImageEditorModel`, `ImageEditor.AdjustmentSection`,
       `OutputAnalysis` and `GrayPoint`), canvas geometry, navigation and
       rendering, and platform-neutral components
     - `iOS/`: the UIKit canvas and its SwiftUI bridge, crop and brush
       interactions, and the iOS editor's screen and controls
     - `macOS/`: the AppKit canvas and its SwiftUI bridge, including mouse
       and trackpad input, the macOS editor's views (`ImageEditorContent`,
       its toolbar, inspector, filter strip and histogram panel, and
       `HoldKeyMonitor`), the editor model's zoom commands, and
       `ImageEditorCommands`, the menu bar commands a host adds to its
       scene, which find the editor through a focused scene value
   - `ImageEditor` and `ImageEditorCanvas` edit an `ImageEditorDocument`
     through a binding

### Key Concepts

The vocabulary is defined in `docs/vision-of-editing.md` ("Vocabulary"). Use
one word per concept in names and docs.

- **Source image** (`SourceImage`, `EditingDocument.source`): the image an
  edit is authored over. It is fixed for a document's lifetime.
- **Feature**: one step of an edit. The **root feature** is the feature a
  document holds, such as `ImageEditorFeature`.
- **Document** (`EditingDocument`): the source image, the root feature, and
  its undo history. "Document" means only this type; do not call a root
  feature a document.
- **Editor** (`ImageEditor`) and **canvas** (`ImageEditorCanvas`): the UI that
  edits a document through a binding. The host owns the document; the UI
  decides when to `commit()` an undo step.
- **Adjustment point**: the feature a tool edits, chosen with
  `ImageEditorCanvas.editingTarget(_:)`, while the canvas shows the evaluated
  result (the viewing point).
- **Chain-entry extent**: the extent proportional radii resolve against.
- **PreviewSourceLoader** (package): per-image preview preparation owned by an
  editor view (`PreviewSourceReader`). It holds no edit and no history. Apps
  never create one.
- **Editor model** (`ImageEditorModel`, internal): the macOS editor's state
  and actions, kept apart from its views so tests drive it without a window
  on both platforms. Actions take the binding and act on its latest
  document; the model never keeps a binding (only the gray point's solve
  holds one, until its result is applied or dropped) and never writes a
  document of another image. One operation is live at a time: any other
  action first writes it as its own step, and Cancel, an outside change or
  the editor disappearing drops it.

### Editing Engine Vision

Read `docs/vision-of-editing.md` before making architectural changes to
BrightroomEngine, PreviewSourceLoader, crop/mask/adjustment semantics, or renderer
evaluation strategy. The target direction is an Onshape-like parametric editing
stack where Features such as Crop, Mask, and Adjust can repeat, pass their
results downstream, and compile into a Core Image graph.
`docs/parametric-runtime-design.md` describes the feature model itself.

### State Management

The project uses swift-state-graph for observable state. When modifying state-related code:
- Look for `@GraphStored` properties
- Documents flow from the host's binding (`Binding<ImageEditorDocument>`)
  into `EditingCanvasView`; each completed operation is written back to the
  binding once, never per gesture tick and never during a view update
- A document compares by value; writes that leave the feature equal are
  dropped, so they add no history checkpoint
- `ImageEditorModel` keeps its observable state in `@GraphStored`
  properties. A node notifies on every set, so assign display-rate values
  (zoom, pointer) only when they change
- Controls never keep a value across time: they end their operations at the
  mouse-up, the key-up (or when Command goes down, as AppKit then delivers
  no key-up) or each VoiceOver step, and a deferred end (a key step that
  focus or the window left) passes the operation's key, never its value.
  An operation the model ends first (another action writes it, or Cancel
  or an outside change drops it) previews and writes nothing more until
  its control ends it
- On macOS each completed operation is a history step of its own
  (`ImageEditorSession.HistoryStep.operation`); on iOS a step is the work of
  one tool visit (`.toolVisit`)

## Development Guidelines

### Adding New Effects
1. Add a value type in `Sources/BrightroomParametric/` conforming to
   `ImageEffect` and `Equatable`. A primitive effect implements
   `apply(to:context:)` and returns an image cropped to the input extent
   (see `BuiltInFeatureRecipes.swift`). A composite effect declares `body`
   instead.
2. Take a radius as `EffectRadius` and resolve it with
   `radius.pixels(in: context, for: image)`, so proportional radii resolve
   against the chain entry and absolute radii (full-resolution pixels) scale
   with the context's package `renderScale`, which the canvas sets for its
   downsampled preview.
3. Keep every authored parameter reconstructible through public API; add a
   validating initializer when a plain initializer clamps or repairs values.
   Do not add `Codable` conformances or storage formats to the library
4. Do not add an identity `id` or `isEnabled`: enablement is structural (an optional
   member, `if`, or leaving a node out). An exact neutral bypass (returning
   the input image itself) belongs inside `apply(to:context:)`.
5. To surface it in ImageEditor, add an optional member to
   `ImageEditorFeature.Effects` (its `body` order is the evaluation order),
   an `ImageEditor.Adjustment` case, and, in `ImageEditor.AdjustmentSection`
   (the macOS inspector), a row in its section's `content` and the member in
   that section's `copyMembers(from:to:)`; list the case in
   `Adjustment.adjustModeCases` to show it in iOS's Adjust strip. A member
   evaluated before `whiteBalance` also joins
   `GrayPoint.effectsBeforeWhiteBalance(_:)`, which a test checks against the
   body. An effect the output frame decides (one that reads its input
   extent, like the vignette) is instead a top-level optional member of
   `ImageEditorFeature` after `crop`, which the canvas draws with its
   post-crop pass (`docs/vision-of-editing.md`, "Decided Semantics"). A
   host's own effect gets no member: it goes in
   `ImageEditorFeature.Effects.custom`, evaluated after the built-in members,
   which the editor never edits and Reset keeps.
6. Test it against an explicit Core Image recipe in
   `Tests/BrightroomParametricTests`.

### Naming
- A top-level library type that conforms to `Feature` ends in `Feature`
  (`ExposureFeature`, `LocalAdjustmentFeature`, `ImageEditorFeature`). A
  type nested inside a feature as one of its parts may omit it
  (`ImageEditorFeature.Effects`). Keep the suffix on top-level types; do not
  introduce bare nouns such as `Crop` or `Exposure`, which hosts often
  declare themselves. Type-erased wrappers are `Any` plus the protocol name
  (`AnyImageEffect`).
- A value that is not a feature has no suffix (`Mask`, `BrushMask`,
  `QuarterTurn`, `AspectRatio`).
- A parameter type used by only one feature is nested in it
  (`ToneCurveFeature.Curves`, `HighlightShadowTintFeature.Color`). A
  parameter type several features share is top-level (`EffectRadius`).
- Name parameters by their unit or meaning (`ev`, `intensity`,
  `temperature`) rather than `value` when one exists.
- "Renderer" is reserved for the public types that evaluate features
  (`FeatureRenderer`, `ExportRenderer`, `VideoRenderer`); `makeImage` returns
  a lazy `CIImage` recipe and `render` produces pixels.
- Code that only Brightroom's own modules or tests call is `package`, not
  `public` (`FeatureEvaluationContext.init`, `ExportRenderer.Device`,
  `BrightroomMetalLibrary`, `PreviewSourceLoader`). Public API is what a
  host needs.
- Do not give new types module or history prefixes (`Parametric`,
  `PhotosCrop`, `PixelEditor`) or leading underscores.
- "Display" is reserved for the viewport; image-space conversions say what
  they convert (`topLeftRect`). "Source" is the chain entry; a feature's own
  input is its "input" (`inputToOutputTransform`).

### Working with Metal
- Metal shaders are in `Sources/BrightroomParametric/` (brush masks and mask
  combinators) and `Sources/BrightroomColorAdjustmentKernels/` (tone curve and
  color mixer)
- Core Image hands a custom kernel the context's working-space values. The
  tone curve and color mixer kernels compute in extended-linear Display-P3, so
  their recipes match into that space around the kernel
  (`ColorAdjustmentKernelSpace`) and render the same in any context; a new
  kernel that assumes a color space does the same
- Performance-critical operations use Metal instead of Core Image
- The editing canvas (`EditingCanvasView`) draws through `EditingCanvasMTKView`
  and `EditingCanvasRenderer` (`Sources/BrightroomUI/Shared/Canvas/`). The pieces
  both platforms share are platform-neutral: `CanvasMetalSurface` (the Metal
  half of a canvas surface, used by the UIKit crop and tool surfaces and by
  the AppKit canvas), `CanvasNavigation` (zoom and pan as a value, which the
  AppKit canvas drives), and `ViewportDisplayLink`
- `CanvasNavigation` reads no clock and owns no view: a host passes input
  with its time and reads a `CanvasViewport`. Its motions (the bounce at a
  limit, the deceleration after a gesture, the way back from a rubber band,
  a zoom that settles) are closed forms of that time, and SwiftUI's `Spring`
  computes the springs. The UIKit tool surface zooms and pans with a
  `UIScrollView` (`CropScrollView`)
- In BrightroomUI, keep UIKit-only files in `iOS/`, wrapped in `#if os(iOS)`,
  and AppKit-only files in `macOS/`, wrapped in `#if os(macOS)`. A shared file
  branches with `#if os(iOS) ... #elseif os(macOS) ... #endif`: AppKit code
  never sits in a bare `#else`, and `canImport` is not used. Mac Catalyst is
  `os(iOS)` and uses the UIKit canvas
- Brush stamps have one rasterizer, the package `BrushStampPipeline`
  (BrightroomParametric): the canvas draws live strokes with it into its mask
  texture, and `MaskRasterizer` draws a brush mask with it into Core Image tiles
  through one `BrushMaskImageProcessor` node, whatever the stamp count
- The SwiftUI demo shows a `CIImage` through its own `SwiftUIMetalImageView`
  (`Dev/Sources/SwiftUIDemo/MetalImageView.swift`), not a library type

### Testing
- Engine and UI tests are in `Dev/Tests/BrightroomEngineTests/`
- Parametric tests are in `Tests/BrightroomParametricTests/`
- Document tests (`EditingDocument`, its history, `SourceImage`, and the
  ImageEditor document flows) are in `Tests/BrightroomEngineDocumentTests/`
- Editor tests are in `Tests/BrightroomEngineDocumentTests/` too: the
  editor model (without a window, on both platforms), the effects' order,
  the adjustment mapping and sections, the options, the filter swatches, the
  output analysis and the gray point, and, on macOS only, the editor's
  window, inspector, slider, filter strip, histogram panel and key monitor.
  Window tests mount `ImageEditorContent` with their own `ImageEditorModel`;
  their `Mounted` conforms to `WindowFixture`, which makes a window that
  never shows on a screen, waits for its layout and sends it keys and
  clicks in-process
- Canvas tests (`CanvasNavigation`, the canvas's shared render path, and on
  macOS the AppKit canvas) are in `Tests/BrightroomCanvasTests/`
- Focus on testing image processing logic, not UI
- Use provided test images in Resources for consistency
- Test files marked "Public API only" play a host app: evaluate through
  `FeatureRenderer`, never `apply(to:context:)` with a context you build.
  Package tests can see `package` symbols, so the compiler does not catch
  this

```bash
# Engine and UI tests
xcodebuild -project Dev/Brightroom.xcodeproj -scheme BrightroomEngineTests test \
  -destination 'platform=iOS Simulator,name=<simulator>' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -skipMacroValidation -skipPackagePluginValidation

# Package tests: BrightroomParametricTests, BrightroomEngineDocumentTests and
# BrightroomCanvasTests
# (CI runs this command; add -only-testing:<target> to run one target)
xcodebuild -scheme Brightroom-Package test \
  -destination 'platform=iOS Simulator,name=<simulator>' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -skipMacroValidation -skipPackagePluginValidation

# Package tests on macOS (CI runs this command). BrightroomParametricTests is
# left out: three of its tests fail on macOS with tolerance differences
xcodebuild -scheme Brightroom-Package test -destination 'platform=macOS' \
  -only-testing:BrightroomCanvasTests \
  -only-testing:BrightroomEngineDocumentTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -skipMacroValidation -skipPackagePluginValidation
```

### Demo App
- **SwiftUI Demo**: `Dev/Sources/SwiftUIDemo/` - SwiftUI examples and UIKit-based checks wrapped with representables
- **ParametricMacDemo**: `Dev/ParametricMacDemo/` - the parametric engine on
  macOS, `ImageEditorCanvas` as a viewer, and the built-in editor in a
  navigation stack, with each write registered with the window's
  `UndoManager` (`-startScreen canvas` or `-startScreen editor` opens that
  screen at launch)

## Common Tasks

### Presenting the Built-in Editor
On iOS:

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import SwiftUI
import UIKit

struct EditorScreen: View {
  // 1. The host owns the document: the image, the edit, and its history
  @State var document: ImageEditorDocument
  var didExport: (Result<UIImage, Error>) -> Void

  var body: some View {
    // 2. The built-in editor edits it through a binding
    ImageEditor(
      document: $document,
      onDone: {
        // 3. Render the edited document
        let document = document
        Task {
          do {
            let rendered = try await document.render()
            didExport(.success(try rendered.uiImage))
          } catch {
            didExport(.failure(error))
          }
        }
      }
    )
  }
}

// Create the document before showing the editor, for example:
func makeEditorScreen(fileURL: URL) throws -> EditorScreen {
  EditorScreen(
    document: ImageEditorDocument(source: try SourceImage(contentsOf: fileURL)),
    didExport: { _ in }
  )
}
```

On macOS, show the editor as a window's content, a `NavigationStack`
destination or a split view's detail. It adds its items to the window's
toolbar, around the title and subtitle the host sets:

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import SwiftUI

struct EditorWindowContent: View {
  // 1. The host owns the document, as on iOS
  @State var document: ImageEditorDocument
  var name: String
  var didExport: (Result<CGImage, Error>) -> Void

  var body: some View {
    // 2. The editor's toolbar items surround the host's title and subtitle
    NavigationStack {
      ImageEditor(
        document: $document,
        onDone: {
          // 3. Render the edited document
          let document = document
          Task {
            do {
              let rendered = try await document.render()
              didExport(.success(try rendered.cgImage))
            } catch {
              didExport(.failure(error))
            }
          }
        }
      )
      .navigationTitle(name)
      .navigationSubtitle(pixelSize)
    }
  }

  private var pixelSize: String {
    let size = document.source.pixelSize
    return "\(Int(size.width)) × \(Int(size.height))"
  }
}

@main
struct EditorApp: App {
  var body: some Scene {
    WindowGroup {
      // The app's own view, which shows EditorWindowContent
      ContentView()
    }
    // 4. Put the editor's commands in the menu bar: zoom, Show Original,
    //    Show Histogram and Show Filters in View, and an Image menu.
    //    InspectorCommands adds Show Inspector, for the adjustments
    .commands {
      InspectorCommands()
      ImageEditorCommands()
    }
  }
}
```

- `ImageEditorCommands` takes the editor's `ImageEditor.LocalizedStrings`
  for its titles. Its items act on the editor in the key window and are
  enabled when the editor's own controls are. Without it the editor's
  shortcuts still work; with it the window takes each key before the menu
  bar, so a key runs once
- Edit > Undo is the host's: the editor registers nothing with an
  `UndoManager`. A `FileDocument` host gets a step per write; a host that
  keeps the document in its own state registers each write with the
  environment's `undoManager` in its binding's setter, as
  `Dev/ParametricMacDemo/EditorDemoView.swift` does
- Sheets are not supported: a sheet has no window toolbar, so most of the
  editor's controls would not show. To edit in a window of its own, open one
  with `openWindow` and make the editor its content

### Adding Custom UI Component
1. Create component in `Sources/BrightroomUI/`
2. Accept a `Binding<ImageEditorDocument>` (or another `EditingDocument`);
   prepare the image for display through `PreviewSourceReader`, keyed by the
   document's `SourceImage`, and start it with `.task { await loader.load() }`
3. Write each completed change to the binding's latest document once; leave
   `commit()` to the editor that owns the undo granularity
4. Do not store edits in `PreviewSourceLoader`; it only prepares the preview

## Platform Requirements
- iOS 17.0+ and macOS 14.0+ (BrightroomParametric, BrightroomEngine,
  BrightroomUI; `SourceImage(image:)` takes a `UIImage` and exists only where
  UIKit does; on macOS, BrightroomUI has the built-in editor without crop and
  brush editing, and the canvas as a viewer)
- Swift 6.3+ (Swift 6 language mode)
- Supports iPhone, iPad, and Mac
