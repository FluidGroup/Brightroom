<h1 align="center">Brightroom</h1>
<p align="center"><i>A composable image editor powered by Core Image and Metal.</i></p>

Build a photo editor with the included Photos-style UI, compose your own editing interface, or use the rendering engine on its own. Brightroom keeps edits as parameters, so you can change adjustments, revisit crops, and render again from the original image.

![Image 1][image-1]
![Image 2][image-2]
![Image 4][image-4]
![Image 3][image-3]
![Image 5][image-5]

[image-1]: https://github.com/user-attachments/assets/50309ba2-e44d-425c-b243-2d8552097049
[image-2]: https://github.com/user-attachments/assets/82bf8e6c-eed9-47f9-b934-ca3cd9285da6
[image-3]: https://github.com/user-attachments/assets/c6295d7c-c17e-40d5-a426-2894a7729897
[image-4]: https://github.com/user-attachments/assets/3cc8106e-b3cd-4de6-97e5-74cd239e54ed
[image-5]: https://github.com/user-attachments/assets/0bde0caa-d460-4060-af31-b2749c3b8505

## Features

- **A ready-to-use photo editor.** Crop, rotate, straighten, apply filter presets, adjust color, and paint blur masks with `ImageEditor`.
- **Composable editing.** Use `ImageEditorCanvas` for a custom interface, with your own document and history, and `EditingStack` loading and rendering the image.
- **Non-destructive processing.** Combine crops, effects, and masked local adjustments in a document you compose from typed features.
- **Custom effects and LUTs.** Add your own Core Image transforms or color-cube LUTs. Edits are plain Swift values, so your app decides how to save them.
- **Metal-backed previews and export.** Work with wide-color images and export to memory or directly to JPEG, HEIF, and PNG files.
- **Local and remote images.** Load images from `UIImage`, data, file URLs, or remote URLs through `ImageProvider`.
- **Rendering beyond the editor.** Use the parametric engine independently on iOS and macOS, including applying documents to video frames through AVFoundation compositions.

## Packages and Requirements

Choose the product that matches what you want to build:

| Product | Purpose | Platforms |
| --- | --- | --- |
| `BrightroomUI` | Photos-style editor and reusable SwiftUI editing components | iOS 17+ |
| `BrightroomEngine` | Image loading and preparation, and asynchronous rendering | iOS 17+ |
| `BrightroomParametric` | Typed features, masks, and Core Image rendering, with no third-party dependencies | iOS 17+, macOS 14+ |

The Swift package requires **Swift 6.3 or later** and uses Swift 6 language mode. Use an Xcode toolchain that includes Swift 6.3 or later. The built-in UI uses UIKit internally; UIKit apps can present it through `UIHostingController`.

## Installation

Add `https://github.com/FluidGroup/Brightroom.git` in Xcode's package dependencies, or declare it in your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/FluidGroup/Brightroom.git", from: "6.0.0")
]
```

For a photo editor, add `BrightroomUI` and `BrightroomEngine` to your app target. In a Swift package target, use:

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "BrightroomUI", package: "Brightroom"),
    .product(name: "BrightroomEngine", package: "Brightroom"),
  ]
)
```

For processing without the editor, add `BrightroomParametric` instead.

## Photos-Style Editor

`EditingStack` loads the image. `PhotosCropEditingModel` owns the document being edited and its undo history, and connects them to the built-in editor's crop, filter, adjustment, and blur controls. Keep the model alive for the lifetime of the editor; it keeps its stack as `editingStack`.

```swift
import BrightroomEngine
import BrightroomUI
import SwiftUI
import UIKit

/// Edits one image and delivers the exported image or a rendering error.
@MainActor
struct PhotoEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var editingModel: PhotosCropEditingModel
  @State private var isExporting = false

  private let onComplete: (Result<UIImage, Error>) -> Void

  init(
    image: UIImage,
    onComplete: @escaping (Result<UIImage, Error>) -> Void
  ) {
    let stack = EditingStack(imageProvider: .init(image: image))
    _editingModel = State(initialValue: PhotosCropEditingModel(editingStack: stack))
    self.onComplete = onComplete
  }

  var body: some View {
    ImageEditor(
      editingModel: editingModel,
      onDone: { document in
        guard !isExporting else { return }
        isExporting = true

        Task {
          defer { isExporting = false }
          do {
            let rendered = try await editingModel.editingStack
              .makeRenderer(document: document)
              .render()
            onComplete(.success(try rendered.uiImage))
          } catch {
            onComplete(.failure(error))
          }
        }
      },
      onCancel: { dismiss() }
    )
    .disabled(isExporting)
    .overlay {
      if isExporting {
        ProgressView()
      }
    }
  }
}
```

The editor starts image preparation automatically. `onDone` receives the edited `ImageEditorFeature`, a plain value that describes the edit. Handle the result and dismiss the editor from `onComplete` when appropriate. Create a new model and stack when selecting a different source image.

Customize aspect ratios and filter presets through `ImageEditor.Options`, and button labels through `LocalizedStrings`. Filter presets default to an empty list; supply your own through `options.filterPresets`. The [sample presets](Dev/Sources/SwiftUIDemo/DemoFilters.swift) are included only in the demo app. For a custom layout and controls, start with [`ImageEditorCanvas`](Sources/BrightroomUI/Shared/Components/Crop/SwiftUICropView.swift), which edits an `ImageEditorFeature` through a binding. See the [SwiftUI demo](Dev/Sources/SwiftUIDemo/ContentView.swift) for complete integrations.

### Saving and Resuming an Edit

To reopen an editor with its undo history, keep the same `PhotosCropEditingModel`. To resume later, store the document's values in your own format and pass the rebuilt document to `PhotosCropEditingModel(editingStack:resuming:)`; see [Saving parametric edits](docs/parametric-persistence.md).

### Exporting Large Images

To export directly to disk, pass a file output to the renderer. This avoids creating a full-resolution output bitmap in memory:

```swift
let rendered = try await editingModel.editingStack
  .makeRenderer(document: document)
  .render(
    options: .init(
      output: .file(url: outputURL, fileType: .heif(quality: 0.9))
    )
  )
```

`document` is the value `onDone` receives. Choose a writable `outputURL` for the destination file. The result exposes `fileURL` and `thumbnail(maxPixelSize:)`. Requesting `cgImage` or `uiImage` from a file-backed result decodes the full image back into memory.

## Processing Without UI

`BrightroomParametric` describes an edit as a document: a Swift value you compose from typed features, the way a SwiftUI view composes its body. Features evaluate in order, and each one receives the preceding feature's output. The source image stays separate from the document.

```swift
import BrightroomParametric
import CoreImage

/// An exposure adjustment followed by an optional crop.
struct AdjustedCrop: Feature, Equatable {
  var exposure = ExposureFeature(value: 0.5)
  var crop: CropFeature?

  var body: some Feature {
    exposure
    crop
  }
}

/// Builds an exposure-adjusted image recipe without modifying the source.
func makeAdjustedImage(from source: CIImage) throws -> CIImage {
  let document = AdjustedCrop(
    crop: CropFeature(cropRect: CGRect(x: 0, y: 0, width: 800, height: 600))
  )

  return try ParametricImageRenderer().makeImage(
    from: source,
    document: document
  )
}
```

The returned `CIImage` is a lazy recipe. Use a `CIContext` to materialize it, or use `ParametricExportRenderer` to render a document to an image or file.

- Conform to `ImageEffect` (and `Equatable`) to add a custom effect.
- Put effects in a `LocalAdjustment` with a `MaskTree` to apply them selectively.
- Use optional members and `if` to switch features on and off; a `nil` member contributes nothing.
- Use `AnyImageEffect` for lists of effects decided by data, such as a preset catalog.
- Brightroom does not define a storage format for edits. To save them, convert features to your own `Codable` model and rebuild them through the public initializers; see [Saving parametric edits](docs/parametric-persistence.md).
- Use `ParametricVideoRenderer` to create an `AVMutableVideoComposition` for playback or export through AVFoundation.

## Demo Apps

Clone the repository with its submodules and open the development project:

```sh
git clone --recurse-submodules https://github.com/FluidGroup/Brightroom.git
cd Brightroom
open Dev/Brightroom.xcodeproj
```

- **SwiftUIDemo** — the Photos-style editor, custom crop interfaces, image rendering, parametric features, and video processing on iOS.
- **ParametricMacDemo** — the standalone parametric engine on macOS.

Select a scheme and a matching run destination in Xcode. To build the iOS demo from the command line:

```sh
xcodebuild \
  -project Dev/Brightroom.xcodeproj \
  -scheme SwiftUIDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Further Reading

- [Migrating to Brightroom 6](docs/MIGRATION_TO_V6.md) — moving from 5.x to documents composed from features.
- [Parametric runtime design](docs/parametric-runtime-design.md) — the feature model and custom effects.
- [Saving parametric edits](docs/parametric-persistence.md) — storing edits in your app's own format, and migrating documents written by `ParametricDocumentCodec`.
- [Editing engine vision](docs/vision-of-editing.md) — the longer-term direction for parametric editing.

## Support the Project

Support Brightroom on [GitHub Sponsors](https://github.com/sponsors/muukii?frequency=one-time&sponsor=muukii) or [buy me a coffee](https://www.buymeacoffee.com/muukii).

## License

Brightroom is available under the [MIT license](LICENSE).
