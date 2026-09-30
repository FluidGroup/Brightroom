import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import ImageIO
import MetalKit
import PhotosUI
import SwiftUI
import UIKit

struct RenderingDemoView: View {

  var body: some View {
    Form {
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
  @State private var documentStore = DemoDocumentStore(
    loading: {
      try SourceImage(
        rawContentsOf: DemoResource.url(forResource: "AppleRAW_1", ofType: "DNG")
      )
    }
  )
  @State private var status = "AppleRAW_1.DNG"

  var body: some View {
    Form {
      Section {
        Button("Load RAW") {
          loadRAW()
        }

        Button("Open ImageEditor") {
          fullScreenView = .init(showsDismissButton: false) {
            DemoImageEditor(store: documentStore)
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
  /// The LUTs imported on this screen, newest first. The editor opened here
  /// lists them before the demo filters.
  @State private var importedFilters: [FilterFeature] = []

  var body: some View {
    Form {
      Section {
        PhotosPicker("Import LUT", selection: $selectedItem)

        Button("Open ImageEditor") {
          var options = ImageEditor.Options()
          options.filters = importedFilters + DemoFilters.make() + DemoLUTs.bundled
          fullScreenView = .init(showsDismissButton: false) {
            DemoImageEditor(
              image: {
                SourceImage(image: Asset.l1000316.image)
              },
              options: options
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

        await MainActor.run {
          importLUT(data)
        }
      } catch {
        await MainActor.run {
          status = "Failed to load selected LUT: \(error)"
        }
      }
    }
  }

  private func importLUT(_ data: Data) {
    guard
      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
      status = "Selected data was not an image."
      return
    }

    let name = "Imported \(importedFilters.count + 1)"
    let cube: ColorCubeFeature
    do {
      // Each import gets its own id: filters and the render cache tell
      // lookup tables apart by id.
      cube = try ColorCubeFeature(
        cubeImage: cgImage,
        name: name,
        id: "imported.\(UUID().uuidString)",
        dimension: 64
      )
    } catch {
      status = "Invalid LUT: \(error.localizedDescription)"
      return
    }

    importedFilters.insert(
      FilterFeature(name: cube.name, id: cube.id, effects: [AnyImageEffect(cube)]),
      at: 0
    )
    status = "Imported \(name). Open ImageEditor to try it in Filters."
  }
}

#Preview {
  NavigationView {
    RenderingDemoView()
  }
}
