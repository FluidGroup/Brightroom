# Migrating to Brightroom v4

This guide is for applications currently using Brightroom from `main` or the
3.x line and moving to v4.

v4 is a major release. It changes the public UI surface from UIKit-first editor
controllers to SwiftUI-first editor views, replaces Verge with
swift-state-graph, and raises the minimum platform to iOS 17.

## Overview

The most common migration path is:

1. Update package requirements and deployment target.
2. Replace Verge imports and store access with direct Brightroom state access.
3. Replace `ClassicImageEditViewController` with `SwiftUIPixelEditorView`.
4. Replace `PhotosCropViewController` or `BrightroomUIPhotosCrop` with
   `SwiftUIPhotosCropView` or `SwiftUICropView`.
5. Replace direct UIKit component usage with the public SwiftUI wrappers.
6. Re-run image loading, crop, mask, filter, undo, and final rendering flows.

## Package and Platform Changes

### Minimum iOS Version

v4 requires iOS 17 or later.

```swift
platforms: [
  .iOS(.v17)
]
```

### Dependencies

Verge is no longer a Brightroom dependency. v4 depends on
`swift-state-graph` instead.

Before:

```swift
.package(url: "https://github.com/VergeGroup/Verge", from: "14.0.0")
```

After:

```swift
.package(url: "https://github.com/VergeGroup/swift-state-graph", exact: "0.17.0")
```

If your app only used Verge because Brightroom exposed Verge state types, remove
your Brightroom-related Verge imports. If your app observes Brightroom state
outside SwiftUI, import `StateGraph` and `Combine`.

### Removed Product

`BrightroomUIPhotosCrop` is removed. Use `BrightroomUI` and the crop views in
that product.

Before:

```swift
.product(name: "BrightroomUIPhotosCrop", package: "Brightroom")
```

After:

```swift
.product(name: "BrightroomUI", package: "Brightroom")
```

`PrecisionLevelSlider` is no longer pulled in by Brightroom.

## EditingStack State

`EditingStack` no longer conforms to `StoreDriverType` and no longer exposes
`store`.

Before:

```swift
import Verge

editingStack.store.sinkState { changes in
  changes.ifChanged(\.loadedState).do { loadedState in
    // update UI
  }
}
.store(in: &subscriptions)

let loaded = editingStack.store.state.loadedState
```

After:

```swift
import Combine
import StateGraph

withGraphTracking {
  withGraphTrackingMap(
    from: editingStack,
    map: { $0.loadedState },
    onChange: { loadedState in
      // update UI
    }
  )
}
.store(in: &subscriptions)

let loaded = editingStack.loadedState
```

Important type renames:

| v3 / main | v4 |
| --- | --- |
| `EditingStack.State.Loaded` | `EditingStack.Loaded` |
| `editingStack.store.state.loadedState` | `editingStack.loadedState` |
| `editingStack.store.state.isLoading` | `editingStack.isLoading` |
| `editingStack.store.state.hasStartedEditing` | `editingStack.hasStartedEditing` |
| `editingStack.commit { ... }` | use public methods such as `set(filters:)`, `crop(_:)`, `takeSnapshot()`, `undoEdit()` |

The public editing operations remain the preferred way to mutate an editing
stack:

```swift
editingStack.set { filters in
  var exposure = FilterExposure()
  exposure.value = 0.3
  filters.exposure = exposure
}

editingStack.crop(crop)
editingStack.takeSnapshot()
editingStack.undoEdit()
let renderer = try editingStack.makeRenderer()
```

## ImageProvider State

`ImageProvider` also no longer exposes a Verge store.

Before:

```swift
let size = imageProvider.store.state.imageSize
let loaded = imageProvider.store.state.loadedImage

imageProvider.commit { state in
  state.editableImage = imageSource
  state.resolve(with: metadata)
}
```

After:

```swift
let size = imageProvider.imageSize
let loaded = imageProvider.loadedImage

imageProvider.editableImage = imageSource
imageProvider.resolve(with: metadata)
```

Important type renames:

| v3 / main | v4 |
| --- | --- |
| `ImageProvider.State` | direct properties on `ImageProvider` |
| `ImageProvider.State.ImageMetadata` | `ImageProvider.ImageMetadata` |
| `ImageProvider.State.Image` | `ImageProvider.LoadedImage` |
| `VergeAnyCancellable` | `AnyCancellable` |

Custom providers should now initialize with direct values and a Combine
cancellable:

```swift
let provider = ImageProvider(
  imageSize: nil,
  orientation: nil,
  editableImage: nil
) { provider in
  // Load asynchronously, then assign direct properties.
  provider.editableImage = imageSource
  provider.resolve(with: metadata)

  return AnyCancellable {
    // cancel loading
  }
}
```

## Pixel Editor

`ClassicImageEditViewController`, `PixelEditViewController`,
`ClassicImageEditOptions`, `ClassicImageEditStyle`, and the
`ClassicImageEdit*` control classes are removed.

Use `SwiftUIPixelEditorView`.

Before:

```swift
let editor = ClassicImageEditViewController(
  imageProvider: imageProvider,
  options: ClassicImageEditOptions(croppingAspectRatio: .square),
  localizedStrings: ClassicImageEditViewController.LocalizedStrings()
)

editor.handlers.didEndEditing = { controller, editingStack in
  // finish
}

editor.handlers.didCancelEditing = { controller in
  // cancel
}
```

After:

```swift
let editingStack = EditingStack(imageProvider: imageProvider)

let editor = UIHostingController(
  rootView: SwiftUIPixelEditorView(
    editingStack: editingStack,
    options: PixelEditorOptions(croppingAspectRatio: .square),
    localizedStrings: PixelEditorLocalizedStrings(),
    onEndEditing: { editingStack in
      // finish
    },
    onCancelEditing: {
      // cancel
    }
  )
)
```

Options mapping:

| v3 / main | v4 |
| --- | --- |
| `ClassicImageEditOptions` | `PixelEditorOptions` |
| `ClassicImageEditOptions.current` | no global current options; pass options into the view |
| `ClassicImageEditOptions.classes` | removed; customize by composing SwiftUI views or using lower-level components |
| `ClassicImageEditEditMenu` | `PixelEditorEditMenu` |
| `ClassicImageEditViewController.LocalizedStrings` | `PixelEditorLocalizedStrings` |
| `handlers.didEndEditing` | `onEndEditing` |
| `handlers.didCancelEditing` | `onCancelEditing` |

The editor starts its `EditingStack` from the SwiftUI view task.

## Photos Crop

`PhotosCropViewController` is removed. Use `SwiftUIPhotosCropView`.

Before:

```swift
let cropController = PhotosCropViewController(
  imageProvider: imageProvider,
  options: .init(),
  localizedStrings: .init()
)

cropController.handlers.didFinish = { controller in
  controller.renderImage(options: .init()) { result in
    // handle rendered image
  }
}

cropController.handlers.didCancel = { controller in
  // cancel
}
```

After:

```swift
let editingStack = EditingStack(imageProvider: imageProvider)

let cropController = UIHostingController(
  rootView: SwiftUIPhotosCropView(
    editingStack: editingStack,
    options: .init(),
    localizedStrings: .init(),
    onDone: {
      Task {
        do {
          let rendered = try editingStack.makeRenderer().render(options: .init())
          // handle rendered image
        } catch {
          // handle render failure
        }
      }
    },
    onCancel: {
      // cancel
    }
  )
)
```

`SwiftUIPhotosCropView.Options` and `LocalizedStrings` keep the same shape as
the old Photos crop controller options and strings.

## Lower-Level Crop UI

`SwiftUICropView` is now a SwiftUI `View` wrapper instead of a public
`UIViewControllerRepresentable` entry point that exposes Verge state.

Before:

```swift
SwiftUICropView(
  editingStack: editingStack,
  stateHandler: { changes in
    changes.ifChanged(\.preferredAspectRatio).do { aspectRatio in
      // update UI
    }
  }
)
.rotation(rotation)
.adjustmentAngle(adjustmentAngle)
.croppingAspectRatio(aspectRatio)
.registerResetAction(resetAction)
```

After:

```swift
@State private var rotation: EditingCrop.Rotation?
@State private var adjustmentAngle: EditingCrop.AdjustmentAngle?
@State private var aspectRatio: PixelAspectRatio?
@State private var resetAction = SwiftUICropView.ResetAction()
@State private var rotateAction = SwiftUICropView.RotateAction()
@State private var applyAction = SwiftUICropView.ApplyAction()

SwiftUICropView(
  editingStack: editingStack,
  stateHandler: { snapshot in
    aspectRatio = snapshot.preferredAspectRatio
  }
)
.rotation($rotation)
.adjustmentAngle($adjustmentAngle)
.croppingAspectRatio($aspectRatio)
.registerResetAction(resetAction)
.registerRotateAction(rotateAction)
.registerApplyAction(applyAction)
```

Changes to note:

- `stateHandler` now receives `SwiftUICropView.StateSnapshot`, not
  `Verge.Changes<CropView.State>`.
- `rotation`, `adjustmentAngle`, and `croppingAspectRatio` accept bindings for
  two-way SwiftUI state synchronization.
- `RotateAction` and `ApplyAction` are new action handles.
- `SwiftUICropView` starts the editing stack and displays a loading state until
  `editingStack.loadedState` is available.

## UIKit Component Visibility

Several previously public UIKit implementation views are now internal. Use the
SwiftUI wrappers instead.

| v3 / main | v4 |
| --- | --- |
| `CropView` | `SwiftUICropView` |
| `ImagePreviewView` | `SwiftUIImagePreviewView` |
| `MetalImageView` | `SwiftUIMetalImageView` |

The legacy `BlurryMaskingView` component and its SwiftUI wrapper were removed.
Use PixelEditor masking for blur-mask editing flows.

If your app subclasses or directly configures these UIKit views, migrate that
code to SwiftUI composition. If you need a missing customization hook, treat it
as a v4 API request rather than relying on internal views.

## LUT and Presets

`EditingStack` no longer accepts `colorCubeStorage` in its initializer. Use
`PresetStorage` for filter presets.

Before:

```swift
let stack = EditingStack(
  imageProvider: imageProvider,
  colorCubeStorage: colorCubeStorage,
  presetStorage: presetStorage
)
```

After:

```swift
let presetStorage = PresetStorage(presets: customPresets)
try presetStorage.loadLUTs(fromBundle: lutBundle)

let stack = EditingStack(
  imageProvider: imageProvider,
  presetStorage: presetStorage
)
```

v4 can load both image-backed LUTs named like `LUT_<Dimension>_<name>.png` and
`.cube` LUT files from the preset bundle.

## Rendering Changes

Crop rendering is canonicalized through pixel-aligned render crop geometry.
Equivalent crops that render to the same pixel output are treated as equivalent
for dirty-state checks.

If your app compares raw crop rectangles directly, prefer Brightroom's public
editing state and renderer output as the source of truth.

## Migration Checklist

- [ ] Raise the app deployment target to iOS 17 or later.
- [ ] Remove Brightroom-related `import Verge` usage.
- [ ] Add `import StateGraph` only where you observe Brightroom state outside
      SwiftUI.
- [ ] Replace `editingStack.store` and `imageProvider.store` reads with direct
      properties.
- [ ] Replace `ClassicImageEditViewController` with `SwiftUIPixelEditorView`.
- [ ] Replace `PhotosCropViewController` with `SwiftUIPhotosCropView`.
- [ ] Remove `BrightroomUIPhotosCrop` from package dependencies.
- [ ] Replace direct UIKit component usage with SwiftUI wrappers.
- [ ] Move any `colorCubeStorage` setup to `PresetStorage`.
- [ ] Re-test image loading from every source your app supports.
- [ ] Re-test crop, rotation, mask drawing, filter adjustment, undo, and final
      rendering.

## Verification Used for This PR

The v4 branch has been validated through focused development builds and tests
while the branch was assembled. Before shipping v4, run the consuming app
against this guide and verify the full editor flows visually because this PR
changes both API shape and interaction surfaces.
