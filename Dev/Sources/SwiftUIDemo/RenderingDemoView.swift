import BrightroomEngine
import BrightroomUI
import MetalKit
import PhotosUI
import SwiftUI
import UIKit

struct RenderingDemoView: View {

  var body: some View {
    Form {
      Section("Preview") {
        NavigationLink("SwiftUIImagePreviewView") {
          ImagePreviewDemoView()
        }
      }

      Section("Rendering") {
        NavigationLink("Metal / CIImage Display") {
          MetalRenderingDemoView()
        }

        NavigationLink("RAW") {
          RawRenderingDemoView()
        }
      }

      Section("LUT") {
        NavigationLink("Import LUT") {
          LUTImportDemoView()
        }
      }
    }
    .navigationTitle("Rendering")
  }
}

private enum DemoResource {
  static func url(forResource name: String, ofType type: String) -> URL {
    Bundle.main.path(forResource: name, ofType: type).map {
      URL(fileURLWithPath: $0)
    }!
  }
}

private struct ImagePreviewDemoView: View {

  @ObjectEdge private var retainedStack = EditingStack(
    imageProvider: .init(image: Asset.leica.image),
    cropModifier: .init { _, crop, completion in
      var new = crop
      new.updateCropExtent(toFitAspectRatio: .square)
      completion(new)
    }
  )

  @State private var previewStack = EditingStack(imageProvider: .init(image: Asset.leica.image))
  @State private var selectedItem: PhotosPickerItem?
  @State private var status = "Example"

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          PhotosPicker("Pick Image", selection: $selectedItem)

          Button("Example") {
            previewStack = EditingStack(imageProvider: .init(image: Asset.leica.image))
            status = "Example"
          }

          Button("Example with keeping") {
            previewStack = retainedStack
            status = "Example with keeping"
          }

          Button("Oriented image") {
            previewStack = EditingStack(
              imageProvider: try! .init(
                fileURL: DemoResource.url(forResource: "orientation_right", ofType: "HEIC")
              )
            )
            status = "Oriented image"
          }

          Button("Remote image") {
            previewStack = EditingStack(
              imageProvider: .init(
                editableRemoteURL: URL(
                  string:
                    "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
                )!
              )
            )
            status = "Remote image"
          }
        } footer: {
          Text(status)
        }
      }
      .frame(maxHeight: 340)

      SwiftUIImagePreviewView(editingStack: previewStack)
        .id(ObjectIdentifier(previewStack))
        .background(Color.black)
    }
    .navigationTitle("SwiftUIImagePreviewView")
    .onChange(of: selectedItem, perform: loadPickedImage)
  }

  private func loadPickedImage(_ item: PhotosPickerItem?) {
    guard let item else { return }

    Task {
      do {
        guard let data = try await item.loadTransferable(type: Data.self) else {
          await MainActor.run {
            status = "Failed to load selected image."
          }
          return
        }

        let stack = EditingStack(imageProvider: try .init(data: data))
        await MainActor.run {
          previewStack = stack
          status = "Picked image"
        }
      } catch {
        await MainActor.run {
          status = "Failed to load selected image: \(error)"
        }
      }
    }
  }
}

private struct MetalRenderingDemoView: View {

  @State private var sourceKind: MetalRenderingSourceKind = .cgImage
  @State private var displayKind: MetalRenderingDisplayKind = .metal
  @State private var blurRadius: Double = 0
  @State private var image: UIImage = Asset.horizontalRect.image
  @State private var selectedItem: PhotosPickerItem?
  @State private var status = "horizontal-rect"

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          Picker("Source", selection: $sourceKind) {
            ForEach(MetalRenderingSourceKind.allCases) { kind in
              Text(kind.title).tag(kind)
            }
          }

          Picker("Display", selection: $displayKind) {
            ForEach(MetalRenderingDisplayKind.allCases) { kind in
              Text(kind.title).tag(kind)
            }
          }

          Slider(value: $blurRadius, in: 0...200) {
            Text("Blur")
          }

          PhotosPicker("Pick Image", selection: $selectedItem)
        } footer: {
          Text(status)
        }
      }
      .frame(maxHeight: 320)

      Group {
        if let sourceImage = makeSourceImage() {
          switch displayKind {
          case .metal:
            SwiftUIMetalImageView(
              image: sourceImage,
              contentMode: .scaleAspectFit,
              postProcessing: blurredImage
            )
          case .uiImageView:
            UIImageCIImageDisplayRepresentable(
              image: sourceImage,
              blurRadius: blurRadius
            )
          }
        } else {
          Text("Unable to create CIImage.")
            .foregroundStyle(.secondary)
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .background(Color.black)
      .padding()
    }
    .navigationTitle("Metal / CIImage")
    .onChange(of: selectedItem, perform: loadPickedImage)
  }

  private func makeSourceImage() -> CIImage? {
    guard let cgImage = image.cgImage else {
      return nil
    }

    switch sourceKind {
    case .cgImage:
      return CIImage(cgImage: cgImage)
    case .mtlTexture:
      guard let device = MTLCreateSystemDefaultDevice() else {
        return nil
      }
      let loader = MTKTextureLoader(device: device)
      guard let texture = try? loader.newTexture(cgImage: cgImage, options: [:]) else {
        return nil
      }
      return CIImage(mtlTexture: texture, options: [:])
    }
  }

  private func blurredImage(_ image: CIImage) -> CIImage {
    image
      .clampedToExtent()
      .applyingGaussianBlur(sigma: blurRadius)
      .cropped(to: image.extent)
  }

  private func loadPickedImage(_ item: PhotosPickerItem?) {
    guard let item else { return }

    Task {
      do {
        guard let data = try await item.loadTransferable(type: Data.self) else {
          await MainActor.run {
            status = "Failed to load selected image."
          }
          return
        }

        guard let pickedImage = UIImage(data: data) else {
          await MainActor.run {
            status = "Selected data was not a UIImage."
          }
          return
        }

        await MainActor.run {
          image = pickedImage
          status = "Picked image"
        }
      } catch {
        await MainActor.run {
          status = "Failed to load selected image: \(error)"
        }
      }
    }
  }
}

private enum MetalRenderingSourceKind: CaseIterable, Identifiable {
  case cgImage
  case mtlTexture

  var id: Self { self }

  var title: String {
    switch self {
    case .cgImage:
      "CIImage <- CGImage"
    case .mtlTexture:
      "CIImage <- MTLTexture <- CGImage"
    }
  }
}

private enum MetalRenderingDisplayKind: CaseIterable, Identifiable {
  case metal
  case uiImageView

  var id: Self { self }

  var title: String {
    switch self {
    case .metal:
      "MTKView"
    case .uiImageView:
      "UIImageView"
    }
  }
}

private struct UIImageCIImageDisplayRepresentable: UIViewRepresentable {

  let image: CIImage
  let blurRadius: Double

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> UIImageView {
    let view = UIImageView()
    view.contentMode = .scaleAspectFit
    view.backgroundColor = .clear
    return view
  }

  func updateUIView(_ uiView: UIImageView, context: Context) {
    let processed = image
      .clampedToExtent()
      .applyingGaussianBlur(sigma: blurRadius)
      .cropped(to: image.extent)
      .removingExtentOffset()

    guard let cgImage = context.coordinator.context.createCGImage(
      processed,
      from: processed.extent
    ) else {
      uiView.image = nil
      return
    }

    uiView.image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
  }

  final class Coordinator {
    let context = CIContext()
  }
}

private struct RawRenderingDemoView: View {

  @State private var resultImage: ResultImage?
  @State private var fullScreenView: FullscreenIdentifiableView?
  @State private var photosCropStack = EditingStack(
    imageProvider: .init(
      rawDataURL: DemoResource.url(forResource: "AppleRAW_1", ofType: "DNG")
    )
  )
  @State private var status = "AppleRAW_1.DNG"

  var body: some View {
    Form {
      Section {
        Button("Load RAW") {
          loadRAW()
        }

        Button("Open PhotosCrop") {
          fullScreenView = .init(showsDismissButton: false) {
            DemoPhotosCropView(stack: photosCropStack)
          }
        }

        Button("Write JPEG") {
          writeJPEG()
        }
      } footer: {
        Text(status)
      }
    }
    .navigationTitle("RAW")
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
    .fullScreenCover(
      item: $fullScreenView,
      onDismiss: {},
      content: {
        $0
      }
    )
  }

  private func loadRAW() {
    let url = DemoResource.url(forResource: "AppleRAW_1", ofType: "DNG")

    guard
      let filter = CIFilter(imageURL: url, options: [:]),
      let outputImage = filter.outputImage
    else {
      status = "Failed to load RAW."
      return
    }

    let context = CIContext()
    guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
      status = "Failed to create CGImage from RAW."
      return
    }

    resultImage = .init(cgImage: cgImage)
    status = "Loaded RAW: \(Int(outputImage.extent.width)) x \(Int(outputImage.extent.height))"
  }

  private func writeJPEG() {
    let url = DemoResource.url(forResource: "AppleRAW_1", ofType: "DNG")

    guard
      let filter = CIFilter(imageURL: url, options: [:]),
      let outputImage = filter.outputImage
    else {
      status = "Failed to load RAW."
      return
    }

    let targetURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("brightroom-raw-image.jpeg")

    do {
      try CIContext().writeJPEGRepresentation(
        of: outputImage,
        to: targetURL,
        colorSpace: outputImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        options: [:]
      )
      status = "Wrote \(targetURL.lastPathComponent)"
    } catch {
      status = "Failed to write JPEG: \(error)"
    }
  }
}

private struct LUTImportDemoView: View {

  @State private var selectedItem: PhotosPickerItem?
  @State private var fullScreenView: FullscreenIdentifiableView?
  @State private var status = "Select a 512 x 512 LUT image."

  var body: some View {
    Form {
      Section {
        PhotosPicker("Import LUT", selection: $selectedItem)

        Button("Open PixelEditor") {
          fullScreenView = .init {
            DemoPixelEditor(
              editingStack: {
                EditingStack(imageProvider: .init(image: Asset.l1000316.image))
              },
              options: .init(croppingAspectRatio: nil)
            )
          }
        }
      } footer: {
        Text(status)
      }
    }
    .navigationTitle("Import LUT")
    .onChange(of: selectedItem, perform: loadPickedLUT)
    .fullScreenCover(
      item: $fullScreenView,
      onDismiss: {},
      content: {
        $0
      }
    )
  }

  private func loadPickedLUT(_ item: PhotosPickerItem?) {
    guard let item else { return }

    Task {
      do {
        guard let data = try await item.loadTransferable(type: Data.self) else {
          await MainActor.run {
            status = "Failed to load selected LUT."
          }
          return
        }

        guard let image = UIImage(data: data) else {
          await MainActor.run {
            status = "Selected data was not a UIImage."
          }
          return
        }

        await MainActor.run {
          importLUT(image)
        }
      } catch {
        await MainActor.run {
          status = "Failed to load selected LUT: \(error)"
        }
      }
    }
  }

  private func importLUT(_ image: UIImage) {
    guard image.scale == 1 else {
      status = "Invalid LUT: image scale is \(image.scale)."
      return
    }

    guard image.size == CGSize(width: 512, height: 512) else {
      status = "Invalid LUT: image size is \(image.size)."
      return
    }

    let identifier = "Imported_\(Int(Date().timeIntervalSince1970))"
    let filter = FilterColorCube(
      name: identifier,
      identifier: identifier,
      lutImage: .init(image: image),
      dimension: 64
    )
    let preset = FilterPreset(
      name: filter.name,
      identifier: filter.identifier,
      filters: [filter.asAny()],
      userInfo: [:]
    )
    PresetStorage.default.presets.insert(preset, at: 0)

    status = "Imported \(identifier)"
  }
}

#Preview {
  NavigationView {
    RenderingDemoView()
  }
}
