<h1 align="center">Brightroom</h1>
<p align="center"><i>A composable image editor powered by Core Image and Metal.</i></p>

Build a photo editor with the included editor UI, compose your own editing interface, or use the rendering engine on its own. Brightroom keeps edits as parameters, so you can change adjustments, revisit crops, and render again from the original image.

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

- **A ready-to-use image editor.** Crop, rotate, straighten, apply filters, adjust color, and paint a local blur with `ImageEditor`.
- **Composable editing.** Build a custom interface around `ImageEditorCanvas`, which edits the same document as the built-in editor.
- **Non-destructive documents.** An `EditingDocument` keeps the source image, the edit as a value composed from typed features, and its undo history. Undo, redo, and rendering are operations on that value.
- **Custom effects and LUTs.** Add your own Core Image transforms or color-cube LUTs. Edits are plain Swift values, so your app decides how to save them.
- **Metal-backed previews and export.** Work with wide-color images and export to memory or directly to JPEG, HEIF, and PNG files.
- **Many image sources.** Create a `SourceImage` from a `UIImage`, a `CGImage`, encoded data, a file, RAW data, or a Photos asset. Download remote images yourself and pass the data.
- **Rendering beyond the editor.** Use the parametric engine independently on iOS and macOS, including applying features to video frames through AVFoundation compositions.

## Packages and Requirements

Choose the product that matches what you want to build:

| Product | Purpose | Platforms |
| --- | --- | --- |
| `BrightroomUI` | The built-in image editor and a reusable editing canvas for SwiftUI | iOS 17+ |
| `BrightroomEngine` | Source images, editing documents with undo history, and rendering | iOS 17+ |
| `BrightroomParametric` | Typed features, masks, and Core Image rendering, with no third-party dependencies | iOS 17+, macOS 14+ |

The Swift package requires **Swift 6.3 or later** and uses Swift 6 language mode. Use an Xcode toolchain that includes Swift 6.3 or later. The built-in UI uses UIKit internally; UIKit apps can present it through `UIHostingController`.

## Installation

Add `https://github.com/FluidGroup/Brightroom.git` in Xcode's package dependencies, or declare it in your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/FluidGroup/Brightroom.git", from: "6.0.0")
]
```

For an image editor, add `BrightroomUI`, `BrightroomEngine`, and `BrightroomParametric` to your app target. In a Swift package target, use:

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "BrightroomUI", package: "Brightroom"),
    .product(name: "BrightroomEngine", package: "Brightroom"),
    .product(name: "BrightroomParametric", package: "Brightroom"),
  ]
)
```

For processing without the editor, add `BrightroomParametric` alone.

## Image Editor

`ImageEditor` edits an `ImageEditorDocument` that your app owns. The document holds the source image, the edit (an `ImageEditorFeature`), and the edit's undo history. Create it before showing the editor, and keep it in your own state:

```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import SwiftUI
import UIKit

/// Edits one image and delivers the exported image or a rendering error.
struct PhotoEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var document: ImageEditorDocument
  @State private var isExporting = false

  private let onComplete: (Result<UIImage, Error>) -> Void

  init(
    image: UIImage,
    onComplete: @escaping (Result<UIImage, Error>) -> Void
  ) {
    _document = State(initialValue: ImageEditorDocument(source: SourceImage(image: image)))
    self.onComplete = onComplete
  }

  var body: some View {
    ImageEditor(
      document: $document,
      onDone: export,
      onCancel: { dismiss() }
    )
    .disabled(isExporting)
    .overlay {
      if isExporting {
        ProgressView()
      }
    }
  }

  private func export() {
    guard !isExporting else { return }
    isExporting = true

    let document = document
    Task {
      defer { isExporting = false }
      do {
        let rendered = try await document.render()
        onComplete(.success(try rendered.uiImage))
      } catch {
        onComplete(.failure(error))
      }
    }
  }
}
```

The editor prepares the image itself. Each completed operation, such as a filter tap, a slider drag, a brush stroke, or an applied crop, is written to the binding once. On Cancel, the editor writes back the document it opened with and then calls `onCancel`; pass `nil` for `onCancel` to hide the Cancel button. The editor never registers anything with an `UndoManager`: undo and redo are `document.undo()` and `document.redo()`, so you can drive them from your own buttons.

For large images, prefer `SourceImage(contentsOf:)` or `SourceImage(data:)`, which decode only when the image is rendered or prepared. `SourceImage(asset:)` loads a Photos asset. To start from a crop that frames a face, create the document with `await ImageEditorDocument(source:initialCrop:)` and `.faceDetection(aspectRatio:)`; `.aspectRatio(_:)` starts from a centered crop of a ratio.

Customize the aspect ratio policy and filters through `ImageEditor.Options`, and button labels through `ImageEditor.LocalizedStrings`. Filters default to an empty list; supply your own `FilterFeature` values through `options.filters`. The [sample filters](Dev/Sources/SwiftUIDemo/DemoFilters.swift) are included only in the demo app. For a custom layout and controls, start with [`ImageEditorCanvas`](Sources/BrightroomUI/Canvas/ImageEditorCanvas.swift), which edits the same document through a binding and leaves committing undo steps to you. See the [SwiftUI demo](Dev/Sources/SwiftUIDemo/ContentView.swift) for complete integrations.

### Saving and Resuming an Edit

A document is a value, so keeping it keeps the edit and its undo history. To resume after the app restarts, store a reference to the source image and the feature's values in your own format, then rebuild the document with `ImageEditorDocument(source:feature:history:)`. Saving the history is optional; see [Saving parametric edits](docs/parametric-persistence.md).

### Exporting Large Images

To export directly to disk, pass a file output to `render(options:)`. This avoids creating a full-resolution output bitmap in memory:

```swift
let rendered = try await document.render(
  options: .init(
    output: .file(url: outputURL, fileType: .heif(quality: 0.9))
  )
)
```

Choose a writable `outputURL` for the destination file. The result exposes `fileURL` and `thumbnail(maxPixelSize:)`. Requesting `cgImage` or `uiImage` from a file-backed result decodes the full image back into memory.

## Processing Without UI

`BrightroomParametric` describes an edit as a feature: a Swift value you compose from typed features, the way a SwiftUI view composes its body. Features evaluate in order, and each one receives the preceding feature's output. The source image stays separate from the feature.

```swift
import BrightroomParametric
import CoreImage

/// An exposure adjustment followed by an optional crop.
struct AdjustedCrop: Feature, Equatable {
  var exposure = ExposureFeature(ev: 0.5)
  var crop: CropFeature?

  var body: some Feature {
    exposure
    crop
  }
}

/// Builds an exposure-adjusted image recipe without modifying the source.
func makeAdjustedImage(from source: CIImage) throws -> CIImage {
  let feature = AdjustedCrop(
    crop: CropFeature(rect: CGRect(x: 0, y: 0, width: 800, height: 600))
  )

  return try FeatureRenderer().makeImage(from: source, feature: feature)
}
```

The returned `CIImage` is a lazy recipe. Use a `CIContext` to materialize it, or use `ExportRenderer` to render a feature to an image or file. With `BrightroomEngine`, `EditingDocument<AdjustedCrop>` keeps such a feature together with its `SourceImage` and undo history, and renders it with `render(options:)`.

- Conform to `ImageEffect` (and `Equatable`) to add a custom effect.
- Put effects in a `LocalAdjustmentFeature` with a `Mask` to apply them selectively.
- Use optional members and `if` to switch features on and off; a `nil` member contributes nothing.
- Use `AnyImageEffect` for lists of effects decided by data, such as a filter catalog.
- Brightroom does not define a storage format for edits. To save them, convert features to your own `Codable` model and rebuild them through the public initializers; see [Saving parametric edits](docs/parametric-persistence.md).
- Use `VideoRenderer` to create an `AVMutableVideoComposition` for playback or export through AVFoundation.

## Demo Apps

Clone the repository with its submodules and open the development project:

```sh
git clone --recurse-submodules https://github.com/FluidGroup/Brightroom.git
cd Brightroom
open Dev/Brightroom.xcodeproj
```

- **SwiftUIDemo** — the built-in image editor, custom canvas interfaces, image rendering, parametric features, and video processing on iOS.
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

- [Migrating to Brightroom 6](docs/MIGRATION_TO_V6.md) — moving from 5.x to editing documents and features, with rename tables.
- [Parametric runtime design](docs/parametric-runtime-design.md) — the feature model and custom effects.
- [Saving parametric edits](docs/parametric-persistence.md) — storing edits in your app's own format, and migrating documents written by `ParametricDocumentCodec`.
- [Editing engine vision](docs/vision-of-editing.md) — the longer-term direction for parametric editing, and the vocabulary Brightroom's names follow.

## Support the Project

Support Brightroom on [GitHub Sponsors](https://github.com/sponsors/muukii?frequency=one-time&sponsor=muukii) or [buy me a coffee](https://www.buymeacoffee.com/muukii).

## License

Brightroom is available under the [MIT license](LICENSE).
