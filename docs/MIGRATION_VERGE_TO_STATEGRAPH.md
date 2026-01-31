# Migration Plan: Verge → swift-state-graph

## Overview

Migrate Brightroom's state management from Verge to [swift-state-graph](https://github.com/VergeGroup/swift-state-graph).

- **Files to migrate**: 29 files
- **Modules**: BrightroomEngine, BrightroomUI, BrightroomUIPhotosCrop
- **swift-state-graph version**: `0.17.0` (exact)

---

## API Mapping

| Verge | swift-state-graph | Notes |
|-------|-------------------|-------|
| `Store<State, Never>` | `@GraphStored` properties | No separate container needed |
| `UIStateStore<State, Never>` | `@MainActor` class + `@GraphStored` | For UI-bound state |
| `StoreDriverType` | Remove | Direct property access |
| `.commit { $0.prop = val }` | `object.prop = val` | Direct assignment |
| `.sinkState { }` | `withGraphTracking { }` | Basic observation |
| `.ifChanged(\.keyPath).do { }` | `withGraphTrackingMap { } onChange: { }` | Granular observation |
| `Changes<State>` | N/A | Use `withGraphTrackingMap` |
| `@Edge` | `@GraphStored` | Change-detection property |
| `VergeAnyCancellable` | `AnyCancellable` / Task | Cancellation management |

---

## Migration Pattern Examples

### Before (Verge)
```swift
open class EditingStack: StoreDriverType {
  public let store: Store<State, Never>

  public struct State: Equatable {
    public fileprivate(set) var hasStartedEditing = false
    public fileprivate(set) var loadedState: Loaded?
  }

  func doSomething() {
    store.commit { $0.hasStartedEditing = true }
  }
}

// Observation
editingStack.sinkState { state in
  state.ifChanged(\.loadedState).do { loaded in
    updateUI(loaded)
  }
}.store(in: &subscriptions)
```

### After (swift-state-graph)
```swift
open class EditingStack: Hashable {
  @GraphStored public var hasStartedEditing = false
  @GraphStored public var loadedState: Loaded?

  func doSomething() {
    hasStartedEditing = true  // Direct assignment
  }
}

// Observation
subscription = withGraphTracking {
  withGraphTrackingMap {
    editingStack.loadedState
  } onChange: { [weak self] loaded in
    self?.updateUI(loaded)
  }
}
```

---

## EditingStack Isolation Design

```swift
// Maintain current behavior: nonisolated nonsendable
open class EditingStack: Hashable {
  // Keep DispatchQueue-based concurrency
  private let backgroundQueue = DispatchQueue(...)

  @GraphStored public var hasStartedEditing = false
  @GraphStored public var loadedState: Loaded?
}
```

**Design decisions**:
- Keep `nonisolated nonsendable` (no change from current)
- No Actor isolation
- Continue using `DispatchQueue`-based concurrency patterns
- Remove `StoreDriverType` protocol conformance

---

## Migration Order

### Phase 1: BrightroomEngine (Foundation)

| Order | File | Complexity |
|-------|------|------------|
| 1.1 | `Sources/BrightroomEngine/DataSource/ImageSource.swift` | Low |
| 1.2 | `Sources/BrightroomEngine/DataSource/ImageProvider.swift` | High |
| 1.3 | `Sources/BrightroomEngine/Core/EditingStack.swift` | Very High |

**EditingStack is critical** - All UI components depend on it

### Phase 2: BrightroomUI Shared Components

| Order | File | Complexity |
|-------|------|------------|
| 2.1 | `Sources/BrightroomUI/Shared/Components/Crop/CropView.swift` | Very High |
| 2.2 | `Sources/BrightroomUI/Shared/Components/Crop/SwiftUICropView.swift` | Medium |
| 2.3 | `Sources/BrightroomUI/Shared/Components/ImageViews/ImagePreviewView.swift` | Medium |
| 2.4 | `Sources/BrightroomUI/Shared/Components/Drawing/CanvasView.swift` | Medium |
| 2.5 | `Sources/BrightroomUI/Shared/Components/Drawing/BlurryMaskingView.swift` | High |

### Phase 3: ClassicImageEdit

| Order | File | Complexity |
|-------|------|------------|
| 3.1 | `ClassicImageEditViewModel.swift` | High |
| 3.2 | `ClassicImageEditControlViewBase.swift` | Medium |
| 3.3 | `ClassicImageEditViewController.swift` | High |
| 3.4 | `ClassicImageEditPresetListControl.swift` | Medium |
| 3.5 | `ClassicImageEditEditMenuControlView.swift` | Medium |
| 3.6-3.16 | FilterControl files (11 files) | Low |

FilterControls: Exposure, Contrast, Saturation, Highlights, Shadows, Temperature, Fade, Clarity, Sharpen, Vignette, GaussianBlur

### Phase 4: PhotosCrop

| Order | File | Complexity |
|-------|------|------------|
| 4.1 | `PhotosCropAspectRatioControl.swift` | Medium |
| 4.2 | `PhotosCropViewController.swift` | High |

### Phase 5: BrightroomUIPhotosCrop

| Order | File | Complexity |
|-------|------|------------|
| 5.1 | `PhotosCropRotating.swift` | Medium |

### Phase 6: Tests

| Order | File |
|-------|------|
| 6.1 | `Dev/Tests/BrightroomEngineTests/LoadingTests.swift` |
| 6.2 | `Dev/Tests/BrightroomEngineTests/RendererTests.swift` |

---

## Package.swift Changes

```swift
// Before
.package(url: "https://github.com/VergeGroup/Verge", from: "14.0.0-beta.7"),

// After
.package(url: "https://github.com/VergeGroup/swift-state-graph", exact: "0.17.0"),

// Target dependencies
.target(name: "BrightroomEngine", dependencies: ["StateGraph"]),
.target(name: "BrightroomUI", dependencies: ["BrightroomEngine", "StateGraph", "TransitionPatch"]),
```

---

## Technical Challenges and Solutions

### 1. Multi-threaded State Management
**Challenge**: EditingStack uses backgroundQueue for image processing while UI observes on main thread

**Solution**:
- Keep DispatchQueue-based concurrency
- Use `withGraphTracking` callbacks dispatch appropriately
- Separate UI state updates from heavy processing if needed

### 2. Changes<State> Pattern
**Challenge**: `.ifChanged(\.keyPath).do { }` is heavily used throughout the codebase

**Solution**: Use `withGraphTrackingMap` for equivalent functionality
```swift
withGraphTrackingMap { editingStack.loadedState?.currentEdit.crop } onChange: { crop in
  // Called only when crop changes
}
```

### 3. Optional State Unwrapping
**Challenge**: `state.mapIfPresent(\.loadedState)` pattern is common

**Solution**: Use conditional observation or computed properties
```swift
withGraphTracking {
  guard let loaded = editingStack.loadedState else { return }
  // Work with loaded state
}
```

### 4. Nested State Structs
**Challenge**: Deep nesting like `EditingStack.State.Loaded`

**Solution**:
- Option 1: Flatten into `@GraphStored` properties
- Option 2: Keep `Loaded` as a struct wrapped in `@GraphStored`

---

## Verification

### Unit Tests
```bash
cd Dev && xcodebuild test -scheme BrightroomEngineTests -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Demo App Verification
```bash
open Dev/Brightroom.xcodeproj
# Run both UIKit Demo and SwiftUI Demo
```

### Verification Checklist
- [ ] Image loading (URL, Data, PHAsset, UIImage)
- [ ] Filter application (all 11 filters)
- [ ] Crop operations (rotate, aspect ratio, freeform)
- [ ] Undo/Redo
- [ ] Blur masking drawing
- [ ] Final image rendering
- [ ] No memory leaks

---

## Critical Files

1. **EditingStack.swift** - Core state container, all UI depends on it
2. **ImageProvider.swift** - Image loading state, uses `@Edge`
3. **CropView.swift** - Most complex UI component, uses `UIStateStore`
4. **ClassicImageEditViewModel.swift** - Uses `assign(to: assignee)` pattern
5. **ClassicImageEditControlViewBase.swift** - Base class for all FilterControls

---

## Migration Progress

### Completed
- [x] Package.swift - Updated dependency
- [x] ImageProvider.swift - Converted to @GraphStored
- [x] EditingStack.swift - Converted to @GraphStored, kept nonisolated nonsendable
- [x] ImageSource.swift - Removed Verge import
- [x] ImageTool.swift - Updated type references
- [x] CropView.swift - Converted UIStateStore to @GraphStored
- [x] SwiftUICropView.swift - Updated observation patterns
- [x] ImagePreviewView.swift - Converted to @GraphStored
- [x] CanvasView.swift - Converted to @GraphStored
- [x] BlurryMaskingView.swift - Converted to @GraphStored
- [x] ClassicImageEditViewModel.swift - Removed State struct, flattened to @GraphStored properties
- [x] ClassicImageEditControlViewBase.swift - Updated base class
- [x] ClassicImageEditViewController.swift - Updated observation
- [x] ClassicImageEditPresetListControl.swift - Converted
- [x] ClassicImageEditEditMenuControlView.swift - Converted
- [x] ClassicImageEditFilterControlBase.swift - Updated base class
- [x] ClassicImageEditExposureControl.swift - Converted
- [x] ClassicImageEditContrastControl.swift - Converted
- [x] ClassicImageEditSaturationControl.swift - Converted
- [x] ClassicImageEditHighlightsControl.swift - Converted
- [x] ClassicImageEditShadowsControl.swift - Converted
- [x] ClassicImageEditTemperatureControl.swift - Converted
- [x] ClassicImageEditFadeControl.swift - Converted
- [x] ClassicImageEditClarityControl.swift - Converted
- [x] ClassicImageEditSharpenControl.swift - Converted
- [x] ClassicImageEditVignetteControl.swift - Converted
- [x] ClassicImageEditGaussianBlurControl.swift - Converted
- [x] PhotosCropViewController.swift - Converted
- [x] PhotosCropAspectRatioControl.swift - Converted
- [x] PhotosCropRotating.swift - Converted

### Test Files
- [x] LoadingTests.swift - Updated observation pattern
- [x] RendererTests.swift - Updated import

### Pending
- [ ] Build verification (requires Xcode macro approval)
- [ ] Run unit tests
- [ ] Demo app testing
